# MABA Upscaler - scene node that drives viewport render scale from the dynamic controller
# and installs the MABA compositor effect.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
#
# Add this node to a scene that has a Camera3D. It sets the viewport's scaling_3d_scale each
# frame and attaches a MabaCompositorEffect to the viewport's compositor. With `temporal` on it
# also jitters the camera's projection by a sub-texel amount each frame (Camera3D frustum mode)
# and the effect resolves the history before it upscales.
#
# TIMING SOURCE (honest): Godot 4.3/4.4 does not expose GPU timer queries to GDScript, so this
# node feeds the controller present-to-present frame time (the interval between frames),
# equivalent to MabaBeginFrame in the C header, NOT the GPU-only MabaBeginFrameGpu. With vsync
# on, present-to-present time cannot see GPU headroom, so Dynamic mode may settle a rung lower
# than the GPU could actually hold. (On the Mali-G52 target, even native timer queries are
# frame-granular, so GPU-only timing would not help there anyway.) If you obtain GPU time by
# other means, call submit_gpu_time(ms) to feed it instead.

@tool
@icon("res://addons/maba_upscaler/icon.svg")
class_name MabaUpscaler
extends Node

# MabaController and MabaCompositorEffect are global classes (class_name); re-declaring them
# here as preload constants would be a "same name as a global class" parse error.

enum Mode { DYNAMIC, ULTRA_QUALITY, QUALITY, BALANCED, PERFORMANCE }

## Emitted when the render scale (viewport scaling_3d_scale) changes. Handy for a settings UI.
signal scale_changed(scale: float)

@export_group("Upscaler")
## DYNAMIC holds `target_fps` by moving the render scale in 1% steps; the others are fixed scales
## (Ultra Quality 0.77, Quality 0.67, Balanced 0.59, Performance 0.50).
@export var mode: Mode = Mode.DYNAMIC
## Sharpening strength. 0.5 is the measured sweet spot.
@export_range(0.0, 1.0, 0.01) var sharpness: float = 0.5
## Convert linear <-> gamma 2.2 around the MABA maths (the engine's buffer is linear). Leave on.
@export var convert_color_space: bool = true

@export_group("Dynamic mode")
## The frame rate Dynamic mode holds.
@export_range(15.0, 240.0, 1.0, "suffix:fps") var target_fps: float = 60.0
## Dynamic mode never renders below / above this fraction of the output resolution (1.0 = native).
## The fixed presets ignore the range.
@export_range(0.35, 1.0, 0.01) var min_scale: float = 0.35
@export_range(0.35, 1.0, 0.01) var max_scale: float = 1.0

@export_group("Temporal (MABA-Upscaler 2)")
## Jittered accumulation with depth reprojection: adds anti-aliasing and detail for about a millisecond.
## Takes over the Camera3D's projection (frustum mode) while it is on.
@export var temporal: bool = false:
	set(v):
		temporal = v
		if is_inside_tree():
			_on_temporal_changed()
## How much of the previous frame is kept, 0.80 - 0.95. Higher is steadier and ghosts more.
@export_range(0.5, 0.98, 0.01) var history_weight: float = 0.9
## Width of the colour clamp that rejects ghosts, 1.0 - 1.5. Lower rejects ghosts harder.
@export_range(0.5, 3.0, 0.05) var clip_gamma: float = 1.25
## How fast history is distrusted as a pixel moves: weight / (1 + K * motion in texels).
@export_range(0.0, 16.0, 0.1) var motion_k: float = 4.0
## Relative depth difference that rejects history (disocclusion), 0.005 - 0.02.
@export_range(0.001, 0.1, 0.001) var depth_tolerance: float = 0.01

@export_group("Debug")
## Show mode, render scale, fps and temporal state in a corner label.
@export var show_stats: bool = false:
	set(v):
		show_stats = v
		if is_inside_tree() and not Engine.is_editor_hint():
			_update_stats_label(true)

var _controller: MabaController
var _effect: MabaCompositorEffect
var _viewport: Viewport
var _temporal := MabaTemporal.new()
var _last_ticks_usec: int = 0
var _applied_target_fps: float = 0.0
var _applied_min_scale: float = -1.0
var _applied_max_scale: float = -1.0
var _saved_scaling_mode: Viewport.Scaling3DMode = Viewport.SCALING_3D_MODE_BILINEAR
var _saved_scaling_scale: float = 1.0
var _gpu_ms: float = -1.0
var _warned_renderer := false
var _last_scale := -1.0
var _smoothed_ms := 16.7
var _stats_layer: CanvasLayer
var _stats_label: Label

# The camera whose Compositor carries the MABA effect (Godot has no per-viewport compositor), and
# whether this node had to create that Compositor.
var _effect_camera: Camera3D
var _created_compositor := false

# Camera whose projection the temporal tier has taken over, and what to put back.
var _jitter_camera: Camera3D
var _saved_cam := {}

# Sign of the frustum offset that moves the image content by +jitter texels, per axis (fixed by
# calibration against a supersampled reference, see test/render_test.gd).
var jitter_node_sign := Vector2(-1.0, 1.0)
# Frames spent waiting for the effect to confirm it is running the resolve. The camera is only
# jittered while the resolve runs (or during this short probe): jitter without a resolve would
# just look like a shaking, low-quality image.
var _temporal_probe := 0
const TEMPORAL_PROBE_FRAMES := 6


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return   # the effect only runs in the game, never inside the editor
	_controller = MabaController.new(int(mode), target_fps)
	_applied_target_fps = target_fps
	_apply_scale_range()
	_viewport = get_viewport()
	if _viewport == null:
		push_error("MABA: no viewport found.")
		return
	if RenderingServer.get_rendering_device() == null:
		push_warning("MABA: needs the Vulkan (Forward+ or Mobile) renderer; the Compatibility renderer is not supported.")
		_warned_renderer = true
		return

	_saved_scaling_mode = _viewport.scaling_3d_mode
	_saved_scaling_scale = _viewport.scaling_3d_scale
	_viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	_effect = MabaCompositorEffect.new()
	_push_settings_to_effect()
	_last_ticks_usec = Time.get_ticks_usec()
	set_process(true)
	_update_stats_label(true)


# Godot keeps the Compositor on a Camera3D (or a WorldEnvironment), not on the viewport: the effect
# is attached to the viewport's current camera and follows it if the current camera changes.
func _attach_effect(cam: Camera3D) -> void:
	_detach_effect()
	if cam == null or _effect == null:
		return
	if cam.compositor == null:
		cam.compositor = Compositor.new()
		_created_compositor = true
	var kept: Array[CompositorEffect] = []
	for e in cam.compositor.compositor_effects:
		if not (e is MabaCompositorEffect):
			kept.append(e)
	kept.append(_effect)
	cam.compositor.compositor_effects = kept
	_effect_camera = cam


func _detach_effect() -> void:
	if _effect_camera != null and is_instance_valid(_effect_camera) and _effect_camera.compositor != null:
		var kept: Array[CompositorEffect] = []
		for e in _effect_camera.compositor.compositor_effects:
			if e != _effect:
				kept.append(e)
		_effect_camera.compositor.compositor_effects = kept
		if _created_compositor and kept.is_empty():
			_effect_camera.compositor = null
	_effect_camera = null
	_created_compositor = false


func _push_settings_to_effect() -> void:
	if _effect == null:
		return
	_effect.sharpness = sharpness
	_effect.convert_color_space = convert_color_space
	_effect.temporal = temporal
	_effect.history_weight = history_weight
	_effect.clip_gamma = clip_gamma
	_effect.motion_k = motion_k
	_effect.depth_tolerance = depth_tolerance


func _exit_tree() -> void:
	_restore_camera()
	if _stats_layer != null:
		_stats_layer.queue_free()
		_stats_layer = null
		_stats_label = null
	if _viewport == null or _effect == null:
		return   # never installed (no viewport, or unsupported renderer): nothing to undo
	_detach_effect()
	_effect.release()
	_viewport.scaling_3d_mode = _saved_scaling_mode
	_viewport.scaling_3d_scale = _saved_scaling_scale
	_effect = null
	# _ready runs only once per node; ask for it again so re-adding this node to a tree
	# reinstalls the effect instead of silently leaving plain bilinear scaling.
	request_ready()


# ---- Public API -------------------------------------------------------------------------------

## Feed a GPU-only frame time (ms) from your own timer query, if you have one. Used for the
## next frame instead of present-to-present time, then cleared.
func submit_gpu_time(gpu_ms: float) -> void:
	_gpu_ms = gpu_ms


func set_mode(p_mode: Mode) -> void:
	mode = p_mode
	if _controller != null:
		_controller.set_mode(int(p_mode))


func set_target_fps(fps: float) -> void:
	target_fps = fps
	_applied_target_fps = fps
	if _controller != null:
		_controller.set_target_fps(fps)


func set_scale_range(p_min_scale: float, p_max_scale: float) -> void:
	min_scale = p_min_scale
	max_scale = p_max_scale
	_apply_scale_range()


func set_sharpness(value: float) -> void:
	sharpness = clampf(value, 0.0, 1.0)


## Turn the temporal tier on or off at run time.
func set_temporal(enabled: bool) -> void:
	temporal = enabled


## Drop the temporal history on a camera cut, a teleport or a scene change.
func reset_history() -> void:
	_temporal.reset()
	if _effect != null:
		_effect.reset_history()


## A snapshot of what MABA is doing: {mode, scale, rung, quality_kernel, fps, frame_ms,
## temporal_requested, temporal_running, native}.
func get_status() -> Dictionary:
	var ctrl_active := _controller != null
	return {
		"mode": int(mode),
		"scale": _controller.scale() if ctrl_active else 1.0,
		"rung": _controller.rung if ctrl_active else 0,
		"quality_kernel": _controller.quality_shader() if ctrl_active else false,
		"native": _controller.is_native() if ctrl_active else true,
		"frame_ms": _smoothed_ms,
		"fps": 1000.0 / maxf(_smoothed_ms, 0.1),
		"temporal_requested": temporal,
		"temporal_running": _effect != null and _effect.temporal_ran,
	}


# Warning triangle in the scene tree: renderer, missing camera, tonemap (see maba_setup.gd).
func _get_configuration_warnings() -> PackedStringArray:
	return MabaSetup.configuration_warnings(self)


# ---- Internals --------------------------------------------------------------------------------

# Applies min_scale / max_scale to the controller. set_scale_range resets the controller's
# counters, so this only does anything when the range actually changed.
func _apply_scale_range() -> void:
	if _controller == null:
		return
	if min_scale == _applied_min_scale and max_scale == _applied_max_scale:
		return
	_applied_min_scale = min_scale
	_applied_max_scale = max_scale
	_controller.set_scale_range(min_scale, max_scale)


func _on_temporal_changed() -> void:
	_temporal.reset()
	_temporal_probe = 0
	if _effect != null:
		_effect.temporal = temporal
		_effect.reset_history()
	if not temporal:
		_restore_camera()


# Moves the camera's projection by `jitter` render texels (content moves BY +jitter) using
# Camera3D frustum mode: a perspective projection with an off-centre frustum.
func _apply_camera_jitter(jitter: Vector2, render_size: Vector2) -> void:
	var cam := _viewport.get_camera_3d()
	if cam == null:
		_restore_camera()
		return
	if cam != _jitter_camera:
		_restore_camera()
		_jitter_camera = cam
		_saved_cam = {
			"projection": cam.projection, "size": cam.size, "frustum_offset": cam.frustum_offset,
			"h_offset": cam.h_offset, "v_offset": cam.v_offset,
		}
	var aspect := render_size.x / render_size.y
	if _saved_cam["projection"] != Camera3D.PROJECTION_PERSPECTIVE:
		# Orthographic and project-owned frustum cameras are left alone: the temporal tier then only
		# stabilises the image (no sub-pixel detail is added).
		return
	# Near-plane extent along the kept axis: 2 * near * tan(fov / 2).
	var extent := 2.0 * cam.near * tan(deg_to_rad(cam.fov) * 0.5)
	var width := extent if cam.keep_aspect == Camera3D.KEEP_WIDTH else extent * aspect
	var height := extent / aspect if cam.keep_aspect == Camera3D.KEEP_WIDTH else extent
	var offset := Vector2(jitter_node_sign.x * jitter.x * width / render_size.x,
			jitter_node_sign.y * jitter.y * height / render_size.y)
	cam.set_frustum(extent, offset, cam.near, cam.far)


func _restore_camera() -> void:
	if _jitter_camera != null and is_instance_valid(_jitter_camera) and not _saved_cam.is_empty():
		if _saved_cam["projection"] == Camera3D.PROJECTION_PERSPECTIVE:
			_jitter_camera.set_perspective(_jitter_camera.fov, _jitter_camera.near, _jitter_camera.far)
		_jitter_camera.frustum_offset = _saved_cam["frustum_offset"]
		_jitter_camera.h_offset = _saved_cam["h_offset"]
		_jitter_camera.v_offset = _saved_cam["v_offset"]
	_jitter_camera = null
	_saved_cam = {}


func _update_stats_label(force: bool = false) -> void:
	if not show_stats:
		if _stats_layer != null:
			_stats_layer.queue_free()
			_stats_layer = null
			_stats_label = null
		return
	if _stats_layer == null:
		_stats_layer = CanvasLayer.new()
		_stats_layer.layer = 128
		_stats_label = Label.new()
		_stats_label.position = Vector2(8, 8)
		_stats_label.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0))
		_stats_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_stats_label.add_theme_constant_override("outline_size", 4)
		_stats_layer.add_child(_stats_label)
		add_child(_stats_layer)
	if force or Engine.get_frames_drawn() % 15 == 0:
		var s := get_status()
		var names := ["Dynamic", "Ultra Quality", "Quality", "Balanced", "Performance"]
		var temporal_text := "off"
		if s["temporal_requested"]:
			temporal_text = "on" if s["temporal_running"] else "requested, not running"
		_stats_label.text = "MABA %s | render %d%% %s | %d fps (%.1f ms) | temporal %s" % [
			names[s["mode"]], roundi(s["scale"] * 100.0),
			"native" if s["native"] else ("quality" if s["quality_kernel"] else "fast"),
			roundi(s["fps"]), s["frame_ms"], temporal_text]


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or _controller == null or _viewport == null or _warned_renderer:
		return

	# Microsecond clock: whole-millisecond ticks (16 or 17) are too coarse for a 2% budget test.
	var now := Time.get_ticks_usec()
	var frame_ms := float(now - _last_ticks_usec) / 1000.0
	_last_ticks_usec = now
	_smoothed_ms += (frame_ms - _smoothed_ms) * 0.05

	# Pick up Inspector / property changes. Both calls reset the controller's counters, so
	# they must only run when the value actually changed.
	if _controller.mode != int(mode):
		_controller.set_mode(int(mode))
	if target_fps != _applied_target_fps:
		_applied_target_fps = target_fps
		_controller.set_target_fps(target_fps)
	_apply_scale_range()

	var out := _viewport.get_visible_rect().size
	if out.x < 2.0 or out.y < 2.0:
		return

	# The effect rides on the current camera's Compositor.
	var current_camera := _viewport.get_camera_3d()
	if current_camera != _effect_camera and _effect != null:
		_attach_effect(current_camera)

	# begin_frame updates the ladder in Dynamic mode and is a no-op for fixed modes. GPU-only
	# time, if submitted, is fed in place of present-to-present time (same controller maths).
	var ms := frame_ms
	if _gpu_ms >= 0.0:
		ms = _gpu_ms
		_gpu_ms = -1.0
	_controller.begin_frame(ms)

	var scale := _controller.scale()
	_viewport.scaling_3d_scale = scale
	if scale != _last_scale:
		if _last_scale >= 0.0:
			_temporal.reset()   # the internal buffers are recreated: no history to keep
		_last_scale = scale
		scale_changed.emit(scale)
	if _effect != null:
		_push_settings_to_effect()
		_effect.quality = _controller.quality_shader()

	# Temporal tier: jitter the projection for this frame's render, but only while the resolve is
	# really running (the effect reports it one frame later; the first frames are a probe).
	var resolve_ok := _effect != null and (_effect.temporal_ran or _temporal_probe < TEMPORAL_PROBE_FRAMES)
	if temporal and _effect != null and not _effect.temporal_ran:
		_temporal_probe += 1
	if temporal and resolve_ok:
		var render_size := Vector2(maxf(2.0, roundf(out.x * scale)), maxf(2.0, roundf(out.y * scale)))
		_apply_camera_jitter(_temporal.begin_frame(), render_size)
	elif _jitter_camera != null:
		_restore_camera()
		if temporal and _temporal_probe == TEMPORAL_PROBE_FRAMES:
			push_warning("MABA temporal: the resolve is not running (" + _effect.temporal_fail_reason + "); camera jitter is off, spatial only.")

	_update_stats_label()
