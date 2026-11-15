# MABA Upscaler (Godot) - render test. Needs a GPU and a window (Vulkan, Forward+).
# Renders a static scene with fine detail (checker ground, stripes, thin poles) and scores each
# configuration against a 2x-supersampled reference, in PSNR (dB, higher is better).
#
# Run (see test/run_godot_tests.ps1, which sets up a scratch project):
#   godot --path <project> --rendering-driver vulkan --resolution 800x450 res://render_test.tscn
#   append  -- --moving to also run the moving-camera check
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
extends Node3D

const SCALE := 0.59
var cam: Camera3D
var maba: MabaUpscaler
var failures := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_build_scene()
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	await _frames(6)

	# Reference: 2x supersampled (the viewport downsamples it to the window size).
	vp.scaling_3d_scale = 2.0
	await _frames(6)
	var ref := await _capture()
	print("RENDER reference captured ", ref.get_size())

	# Plain bilinear at the render scale: the floor MABA has to beat.
	vp.scaling_3d_scale = SCALE
	await _frames(6)
	var bil := await _capture()
	print("RENDER bilinear        PSNR ", "%.2f" % _psnr(ref, bil))

	# MABA spatial only.
	maba = MabaUpscaler.new()
	maba.mode = MabaUpscaler.Mode.BALANCED
	maba.sharpness = 0.5
	add_child(maba)
	await _frames(12)
	var spatial := await _capture()
	var psnr_spatial := _psnr(ref, spatial)
	print("RENDER maba spatial    PSNR ", "%.2f" % psnr_spatial, "  scale ", maba.get_status()["scale"])

	# MABA temporal with the current (default) conventions.
	maba.temporal = true
	maba._effect.debug_log = args.has("--debug")
	for k in 4:
		await _frames(10)
		print("RENDER   progress callbacks ", maba._effect.callbacks, " resolves ", maba._effect.resolves, " cam.compositor ", cam.compositor != null, " effects ", (cam.compositor.compositor_effects.size() if cam.compositor != null else -1), " attached ", maba._effect_camera == cam, " reason '", maba._effect.temporal_fail_reason, "'")
	var st := maba.get_status()
	print("RENDER temporal running: ", st["temporal_running"], "  ", maba._effect.temporal_fail_reason, "  callbacks ", maba._effect.callbacks, " resolves ", maba._effect.resolves, " scale ", st["scale"], " native ", st["native"])
	var temporal_img := await _capture()
	var psnr_temporal := _psnr(ref, temporal_img)
	if args.has("--save"):
		ref.save_png("user://ref.png")
		bil.save_png("user://bilinear.png")
		spatial.save_png("user://spatial.png")
		temporal_img.save_png("user://temporal.png")
		print("RENDER images saved to ", OS.get_user_data_dir())
	print("RENDER maba temporal   PSNR ", "%.2f" % psnr_temporal, "  (", "%+.2f" % (psnr_temporal - psnr_spatial), " dB vs spatial)")

	for shift in [1.0, 0.0]:
		maba._effect.jitter_shift_read = shift
		maba.reset_history()
		await _frames(30)
		var img_s := await _capture()
		print("RENDER temporal, read at +jitter = ", shift, "  PSNR ", "%.2f" % _psnr(ref, img_s))

	if args.has("--tune"):
		await _tune(ref)

	if args.has("--moving"):
		await _moving(ref)

	print("RENDER done")
	get_tree().quit(failures)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _capture() -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


func _psnr(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size():
		return -1.0
	var da := a.get_data()
	var db := b.get_data()
	var sum := 0.0
	var n := da.size()
	for i in n:
		var d := float(da[i]) - float(db[i])
		sum += d * d
	var mse := sum / float(n)
	if mse < 1e-9:
		return 99.0
	return 10.0 * log(255.0 * 255.0 / mse) / log(10.0)


func _build_scene() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.35, 0.45, 0.6)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.9, 0.6, 0.0)
	light.light_energy = 0.9
	add_child(light)

	cam = Camera3D.new()
	cam.fov = 60.0
	cam.position = Vector3(0.0, 1.4, 4.2)
	add_child(cam)
	cam.rotation = Vector3(-0.22, 0.0, 0.0)
	cam.current = true

	# Fine detail everywhere: a checker ground, striped boxes, thin poles, a fence of bars.
	var checker := _texture(func(x: int, y: int) -> Color:
		return Color.WHITE if ((x / 16) + (y / 16)) % 2 == 0 else Color(0.12, 0.12, 0.14))
	var stripes := _texture(func(x: int, y: int) -> Color:
		return Color(0.95, 0.35, 0.2) if (x / 8) % 2 == 0 else Color(0.05, 0.1, 0.35))
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(30.0, 30.0)
	ground.mesh = plane
	ground.material_override = _mat(checker, Vector3(5.0, 5.0, 1.0))
	add_child(ground)
	for i in 5:
		var box := MeshInstance3D.new()
		box.mesh = BoxMesh.new()
		box.material_override = _mat(stripes, Vector3(1.0, 1.0, 1.0))
		box.position = Vector3(-3.0 + i * 1.5, 0.5, 0.5 - i * 0.7)
		box.rotation = Vector3(0.0, 0.5 * i, 0.0)
		add_child(box)
	for i in 14:
		var pole := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.025
		cyl.bottom_radius = 0.025
		cyl.height = 2.2
		pole.mesh = cyl
		pole.position = Vector3(-4.5 + i * 0.7, 1.1, -2.5)
		add_child(pole)
	var sphere := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.8
	sm.height = 1.6
	sphere.mesh = sm
	sphere.material_override = _mat(stripes, Vector3(2.0, 2.0, 1.0))
	sphere.position = Vector3(0.0, 0.9, 1.2)
	add_child(sphere)


func _texture(fn: Callable) -> ImageTexture:
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			img.set_pixel(x, y, fn.call(x, y))
	return ImageTexture.create_from_image(img)


func _mat(tex: Texture2D, uv_scale: Vector3) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.uv1_scale = uv_scale
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m


# The camera slides sideways; compares the settled image with a reference rendered at the end pose,
# for the spatial tier alone and for the temporal tier on top of it.
func _moving(_ref_static: Image) -> void:
	var vp := get_viewport()
	var start := cam.position
	var step := Vector3(0.01, 0.0, 0.0)
	var frames := 30

	# Reference at the end pose, supersampled.
	maba.temporal = false
	maba.set_process(false)
	vp.scaling_3d_scale = 2.0
	cam.position = start + step * frames
	await _frames(8)
	var ref_end := await _capture()
	maba.set_process(true)

	for variant in ["spatial", "temporal K=4", "temporal K=8", "temporal K=16"]:
		cam.position = start
		maba.temporal = variant != "spatial"
		if variant.ends_with("K=8"):
			maba.motion_k = 8.0
		elif variant.ends_with("K=16"):
			maba.motion_k = 16.0
		else:
			maba.motion_k = 4.0
		maba.reset_history()
		await _frames(6)
		for i in frames:
			cam.position += step
			await get_tree().process_frame
		await _frames(1)
		var img := await _capture()
		print("RENDER moving ", variant.rpad(14), " PSNR ", "%.2f" % _psnr(ref_end, img))
	maba.motion_k = 4.0
	cam.position = start

# Small sweep of the temporal settings on the static scene (PSNR vs the supersampled reference).
func _tune(ref: Image) -> void:
	var eff: MabaCompositorEffect = maba._effect
	maba.temporal = true
	for w in [0.8, 0.9, 0.95]:
		for g in [1.0, 1.25, 2.0]:
			maba.history_weight = w
			maba.clip_gamma = g
			maba.reset_history()
			await _frames(40)
			var img := await _capture()
			print("RENDER tune weight ", w, " gamma ", g, "  PSNR ", "%.2f" % _psnr(ref, img))
	maba.history_weight = 0.9
	maba.clip_gamma = 1.25
	for sh in [0.3, 0.5, 0.8, 1.0]:
		maba.sharpness = sh
		maba.reset_history()
		await _frames(40)
		var img2 := await _capture()
		print("RENDER tune sharpness ", sh, "  PSNR ", "%.2f" % _psnr(ref, img2))
	maba.sharpness = 0.5
	maba.temporal = false
	for sh in [0.3, 0.5, 0.8, 1.0]:
		maba.sharpness = sh
		await _frames(10)
		var img3 := await _capture()
		print("RENDER tune spatial sharpness ", sh, "  PSNR ", "%.2f" % _psnr(ref, img3))
	maba.sharpness = 0.5
	maba.temporal = true
