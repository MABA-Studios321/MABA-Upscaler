# Headless self-test for the GDScript controller port (mirrors test/native/test_controller.c).
# Run: godot --headless --script res://addons/maba_upscaler/test_controller.gd
# Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
extends SceneTree

# A frame time just inside the 60 fps budget (16.67 ms, over-budget threshold 17.0 ms): good, but
# with no headroom, so a step up climbs exactly one rung.
const BARELY_GOOD_MS := 16.0

var failures := 0


func check(cond: bool, what: String) -> void:
	if not cond:
		failures += 1
		print("FAIL: " + what)


func feed(c: MabaController, ms: float, frames: int) -> void:
	for i in frames:
		c.begin_frame(ms)


func feed_until(c: MabaController, ms: float, target: int, max_frames: int) -> int:
	for i in max_frames:
		c.begin_frame(ms)
		if c.rung == target:
			return i + 1
	return max_frames


# Feeds frames until the rung changes at all (a headroom jump skips past any exact target).
func feed_until_change(c: MabaController, ms: float, max_frames: int) -> int:
	var start := c.rung
	for i in max_frames:
		c.begin_frame(ms)
		if c.rung != start:
			return i + 1
	return max_frames


func _init() -> void:
	# Temporal jitter sequence: Halton(2, 3) over 16 phases, the same as maba_temporal.h
	check(absf(MabaTemporal.halton(1, 2) - 0.5) < 1e-6, "halton(1,2)")
	check(absf(MabaTemporal.halton(2, 2) - 0.25) < 1e-6, "halton(2,2)")
	check(absf(MabaTemporal.halton(3, 2) - 0.75) < 1e-6, "halton(3,2)")
	check(absf(MabaTemporal.halton(1, 3) - 1.0 / 3.0) < 1e-6, "halton(1,3)")
	check(absf(MabaTemporal.halton(2, 3) - 2.0 / 3.0) < 1e-6, "halton(2,3)")
	check(absf(MabaTemporal.halton(4, 3) - 4.0 / 9.0) < 1e-6, "halton(4,3)")
	check(MabaTemporal.halton(5, 1) == 0.0, "halton base < 2 does not loop")
	var jt := MabaTemporal.new()
	check(jt.needs_reset(), "a new jitter state asks for a reset")
	var first := jt.begin_frame()
	check(not jt.needs_reset(), "begin_frame clears the reset flag")
	check(absf(first.x) < 1e-6 and absf(first.y - (1.0 / 3.0 - 0.5)) < 1e-6, "first jitter is (0, -1/6)")
	var in_range := true
	var seen := {}
	for i in MabaTemporal.PHASES - 1:
		var j := jt.begin_frame()
		if absf(j.x) > 0.5 or absf(j.y) > 0.5:
			in_range = false
		seen[j] = true
	check(in_range, "jitter stays inside [-0.5, 0.5] texels")
	check(seen.size() == MabaTemporal.PHASES - 1, "16 distinct phases")
	check(jt.phase == 0, "the phase wraps after 16 frames")
	jt.begin_frame()
	jt.reset()
	check(jt.needs_reset() and jt.phase == 0, "reset restarts the sequence")
	# Anchors and the ends of the whole ladder
	check(absf(MabaController.rung_scale(0) - 0.50) < 1e-6, "rung 0 scale")
	check(absf(MabaController.rung_scale(9) - 0.59) < 1e-6, "rung 9 scale")
	check(MabaController.rung_quality(9) == false, "rung 9 fast")
	check(absf(MabaController.rung_scale(10) - 0.59) < 1e-6, "rung 10 scale")
	check(MabaController.rung_quality(10) == true, "rung 10 quality")
	check(absf(MabaController.rung_scale(18) - 0.67) < 1e-6, "rung 18 scale")
	check(absf(MabaController.rung_scale(28) - 0.77) < 1e-6, "rung 28 scale")
	check(absf(MabaController.rung_scale(MabaController.RUNG_FLOOR) - 0.35) < 1e-6, "floor scale")
	check(absf(MabaController.rung_scale(MabaController.RUNG_CEIL) - 1.00) < 1e-6, "ceiling is native")
	check(MabaController.rung_native(MabaController.RUNG_CEIL), "ceiling flagged native")
	check(not MabaController.rung_native(MabaController.RUNG_CEIL - 1), "rung below ceiling not native")
	for r in range(MabaController.RUNG_FLOOR, MabaController.RUNG_CEIL + 1):
		var expect := 10 if r == 9 else r
		check(MabaController.scale_to_rung(MabaController.rung_scale(r)) == expect, "scale_to_rung round trip %d" % r)

	# Step down to the floor of the whole ladder
	var c := MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	check(c.rung == 10, "start rung")
	feed(c, 25.0, 1000)
	check(c.rung == MabaController.RUNG_FLOOR, "step down to floor")

	# Step up: one rung when there is no headroom, then on to native
	var n := feed_until(c, BARELY_GOOD_MS, MabaController.RUNG_FLOOR + 1, 1000)
	check(n >= MabaController.UP_FRAMES and n <= MabaController.UP_FRAMES + 30, "step-up window")
	feed(c, BARELY_GOOD_MS, 30000)
	check(c.rung == MabaController.RUNG_CEIL, "step up to native")

	# Backoff
	c = MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	feed(c, 25.0, 1000)
	feed_until(c, BARELY_GOOD_MS, MabaController.RUNG_FLOOR + 1, 1000)
	check(c.probing, "probing after step up")
	feed(c, 25.0, 200)
	check(c.rung == MabaController.RUNG_FLOOR and c.up_wait == MabaController.UP_FRAMES * 2, "backoff doubles")
	n = feed_until(c, BARELY_GOOD_MS, MabaController.RUNG_FLOOR + 1, 2000)
	check(n >= MabaController.UP_FRAMES * 2, "doubled wait respected")

	# Pauses ignored
	c = MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	feed(c, 16.0, 50)
	var avg := c.avg_ms
	var good := c.good_frames
	feed(c, 2000.0, 10)
	feed(c, -5.0, 10)
	check(c.avg_ms == avg and c.good_frames == good, "pauses ignored")

	# Target change keeps rung
	c = MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	feed(c, 25.0, 1000)
	c.set_target_fps(30.0)
	check(c.rung == MabaController.RUNG_FLOOR, "target change keeps rung")
	feed(c, 25.0, 30000)
	check(c.rung == MabaController.RUNG_CEIL, "climbs under relaxed budget")

	# Seeding clamps to the range
	c = MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	c.seed_rung(999)
	check(c.rung == MabaController.RUNG_CEIL, "seed clamps to the ceiling")
	c.seed_rung(-5)
	check(c.rung == -5, "below the classic floor is valid")
	c.seed_rung(-999)
	check(c.rung == MabaController.RUNG_FLOOR, "seed clamps to the floor")

	# Range: the classic range reproduces the old behaviour; a floor holds; presets ignore it
	c = MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	c.set_scale_range(0.50, 0.77)
	check(c.rung_lo == 0 and c.rung_hi == 28, "classic range rungs")
	feed(c, 25.0, 1000)
	check(c.rung == 0, "classic floor")
	feed(c, BARELY_GOOD_MS, 30000)
	check(c.rung == 28, "classic ceiling")
	c = MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	c.set_scale_range(0.67, 1.00)
	check(c.rung == 18, "start rung raised to the floor")
	feed(c, 40.0, 2000)
	check(c.rung == 18, "quality floor holds under load")
	c = MabaController.new(MabaController.MODE_PERFORMANCE, 60.0)
	c.set_scale_range(0.67, 1.00)
	check(c.rung == 0, "preset ignores the range")
	c.set_mode(MabaController.MODE_DYNAMIC)
	check(c.rung == 18, "dynamic enters the range")

	# Headroom: several rungs at once, never past what the frame time predicts
	c = MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	feed(c, 25.0, 1000)
	var from := c.rung
	n = feed_until_change(c, 5.0, 600)
	check(n < 600 and c.rung > from + 1 and c.rung - from <= MabaController.MAX_JUMP, "headroom jump")
	check(c.probing and c.probe_from == from, "jump is being proven")
	# From 0.67 at 12 ms: the highest rung with 12 * (pct / 67)^2 <= 15.0 is pct 74, rung 25.
	c = MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	c.seed_rung(18)
	n = feed_until_change(c, 12.0, 600)
	check(n < 600 and c.rung == 25, "jump stops where the prediction stops fitting")

	# A failed jump returns to where it started in one step
	c = MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	feed(c, 25.0, 1000)
	from = c.rung
	feed_until_change(c, 5.0, 600)
	var jumped := c.rung
	var frames := 0
	while frames < 400 and c.rung == jumped:
		c.begin_frame(25.0)
		frames += 1
	check(c.rung == from and frames < 2 * MabaController.DOWN_FRAMES + 40, "failed jump returns in one window")

	# A fast GPU ends at native and leaves it when frames run over
	c = MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	feed(c, 5.0, 20000)
	check(c.rung == MabaController.RUNG_CEIL and c.is_native(), "fast GPU reaches native")
	feed(c, 25.0, 200)
	check(c.rung < MabaController.RUNG_CEIL and not c.is_native(), "leaves native under load")

	# Setup checks (editor menu and inspector warnings)
	var root := Node3D.new()
	var maba := MabaUpscaler.new()
	root.add_child(maba)
	maba.owner = root
	var report_empty := MabaSetup.check_scene(root)
	var has_camera_warning := false
	for item in report_empty:
		if "Camera3D" in item["text"]:
			has_camera_warning = true
	check(has_camera_warning, "a scene without a camera is reported")
	check(MabaSetup.configuration_warnings(maba).size() >= 1, "the node shows a warning triangle without a camera")
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.owner = root
	var env := Environment.new()
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	we.owner = root
	var tonemap_warned := false
	for item in MabaSetup.check_scene(root):
		if "tonemap" in item["text"]:
			tonemap_warned = true
	check(tonemap_warned, "a non-Linear tonemap is reported")
	check(MabaSetup.apply_recommended(root) == 1, "apply_recommended changes one environment")
	check(env.tonemap_mode == Environment.TONE_MAPPER_LINEAR and is_equal_approx(env.tonemap_exposure, 1.0), "tonemap is now Linear at exposure 1")
	check(MabaSetup.apply_recommended(root) == 0, "apply_recommended is idempotent")
	check(MabaSetup.configuration_warnings(maba).is_empty(), "a correct scene has no warnings")
	check(not MabaSetup.has_errors(MabaSetup.check_project()), "the test project's renderer is supported")
	root.free()

	if failures == 0:
		print("ALL GODOT CONTROLLER TESTS PASSED")
	else:
		print("%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)
