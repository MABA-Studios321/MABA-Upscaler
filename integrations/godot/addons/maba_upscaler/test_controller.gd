# Headless self-test for the GDScript controller port.
# Run: godot --headless --script res://addons/maba_upscaler/test_controller.gd
# Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
extends SceneTree

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


func _init() -> void:
	# Anchors
	check(absf(MabaController.rung_scale(0) - 0.50) < 1e-6, "rung 0 scale")
	check(absf(MabaController.rung_scale(9) - 0.59) < 1e-6, "rung 9 scale")
	check(MabaController.rung_quality(9) == false, "rung 9 fast")
	check(absf(MabaController.rung_scale(10) - 0.59) < 1e-6, "rung 10 scale")
	check(MabaController.rung_quality(10) == true, "rung 10 quality")
	check(absf(MabaController.rung_scale(18) - 0.67) < 1e-6, "rung 18 scale")
	check(absf(MabaController.rung_scale(28) - 0.77) < 1e-6, "rung 28 scale")

	# Step down to floor
	var c := MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	check(c.rung == 10, "start rung")
	feed(c, 25.0, 1000)
	check(c.rung == 0, "step down to floor")

	# Step up to ceiling
	var n := feed_until(c, 10.0, 1, 1000)
	check(n >= MabaController.UP_FRAMES and n <= MabaController.UP_FRAMES + 30, "step-up window")
	feed(c, 10.0, 20000)
	check(c.rung == 28, "step up to ceiling")

	# Backoff
	c = MabaController.new(MabaController.MODE_DYNAMIC, 60.0)
	feed(c, 25.0, 1000)
	feed_until(c, 10.0, 1, 1000)
	check(c.probing, "probing after step up")
	feed(c, 25.0, 200)
	check(c.rung == 0 and c.up_wait == MabaController.UP_FRAMES * 2, "backoff doubles")
	n = feed_until(c, 10.0, 1, 2000)
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
	check(c.rung == 0, "target change keeps rung")
	feed(c, 25.0, 20000)
	check(c.rung == 28, "climbs under relaxed budget")

	if failures == 0:
		print("ALL GODOT CONTROLLER TESTS PASSED")
	else:
		print("%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)