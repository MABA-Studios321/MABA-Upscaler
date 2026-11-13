# MABA Upscaler - scene node that drives viewport render scale from the dynamic controller
# and installs the MABA compositor effect.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
#
# Add this node to a scene that has a Camera3D. It sets the viewport's scaling_3d_scale each
# frame and attaches a MabaCompositorEffect to the viewport's compositor.
#
# TIMING SOURCE (honest): Godot 4.3/4.4 does not expose GPU timer queries to GDScript, so this
# node feeds the controller present-to-present frame time (the interval between frames),
# equivalent to MabaBeginFrame in the C header, NOT the GPU-only MabaBeginFrameGpu. With vsync
# on, present-to-present time cannot see GPU headroom, so Dynamic mode may settle a rung lower
# than the GPU could actually hold. (On the Mali-G52 target, even native timer queries are
# frame-granular, so GPU-only timing would not help there anyway.) If you obtain GPU time by
# other means, call submit_gpu_time(ms) to feed it instead.

class_name MabaUpscaler
extends Node

# MabaController and MabaCompositorEffect are global classes (class_name); re-declaring them
# here as preload constants would be a "same name as a global class" parse error.

enum Mode { DYNAMIC, ULTRA_QUALITY, QUALITY, BALANCED, PERFORMANCE }

@export var mode: Mode = Mode.DYNAMIC
@export_range(0.0, 1.0, 0.01) var sharpness: float = 0.5
@export var target_fps: float = 60.0
@export var convert_color_space: bool = true

var _controller: MabaController
var _effect: MabaCompositorEffect
var _viewport: Viewport
var _last_ticks_usec: int = 0
var _applied_target_fps: float = 0.0
var _saved_scaling_mode: Viewport.Scaling3DMode = Viewport.SCALING_3D_MODE_BILINEAR
var _saved_scaling_scale: float = 1.0
var _gpu_ms: float = -1.0
var _warned_renderer := false


func _ready() -> void:
	_controller = MabaController.new(int(mode), target_fps)
	_applied_target_fps = target_fps
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
	_install_effect()
	_last_ticks_usec = Time.get_ticks_usec()
	set_process(true)


func _install_effect() -> void:
	if _viewport.compositor == null:
		_viewport.compositor = Compositor.new()
	var comp := _viewport.compositor
	var kept: Array[CompositorEffect] = []
	for e in comp.compositor_effects:
		if not (e is MabaCompositorEffect):
			kept.append(e)
	_effect = MabaCompositorEffect.new()
	_effect.sharpness = sharpness
	_effect.convert_color_space = convert_color_space
	kept.append(_effect)
	comp.compositor_effects = kept


func _exit_tree() -> void:
	if _viewport == null or _effect == null:
		return   # never installed (no viewport, or unsupported renderer): nothing to undo
	if _viewport.compositor != null:
		var kept: Array[CompositorEffect] = []
		for e in _viewport.compositor.compositor_effects:
			if e != _effect:
				kept.append(e)
		_viewport.compositor.compositor_effects = kept
	_viewport.scaling_3d_mode = _saved_scaling_mode
	_viewport.scaling_3d_scale = _saved_scaling_scale
	_effect = null
	# _ready runs only once per node; ask for it again so re-adding this node to a tree
	# reinstalls the effect instead of silently leaving plain bilinear scaling.
	request_ready()


# Feed a GPU-only frame time (ms) from your own timer query, if you have one. Used for the
# next frame instead of present-to-present time, then cleared.
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


func _process(_delta: float) -> void:
	if _controller == null or _viewport == null or _warned_renderer:
		return

	# Microsecond clock: whole-millisecond ticks (16 or 17) are too coarse for a 2% budget test.
	var now := Time.get_ticks_usec()
	var frame_ms := float(now - _last_ticks_usec) / 1000.0
	_last_ticks_usec = now

	# Pick up Inspector / property changes. Both calls reset the controller's counters, so
	# they must only run when the value actually changed.
	if _controller.mode != int(mode):
		_controller.set_mode(int(mode))
	if target_fps != _applied_target_fps:
		_applied_target_fps = target_fps
		_controller.set_target_fps(target_fps)

	var out := _viewport.get_visible_rect().size
	if out.x < 2.0 or out.y < 2.0:
		return

	# begin_frame updates the ladder in Dynamic mode and is a no-op for fixed modes. GPU-only
	# time, if submitted, is fed in place of present-to-present time (same controller maths).
	var ms := frame_ms
	if _gpu_ms >= 0.0:
		ms = _gpu_ms
		_gpu_ms = -1.0
	_controller.begin_frame(ms)

	_viewport.scaling_3d_scale = _controller.scale()
	if _effect != null:
		_effect.quality = _controller.quality_shader()
		_effect.sharpness = sharpness
		_effect.convert_color_space = convert_color_space