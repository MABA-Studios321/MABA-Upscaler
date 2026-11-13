# MABA Upscaler - full-screen TextureRect that upscales a SubViewport rendered at reduced
# scale. Put your 3D scene inside the SubViewport; this rect displays it with MABA.
# UI lives in a CanvasLayer above this rect, at native resolution.
# Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
class_name MabaUpscalerRect
extends TextureRect

enum Mode { DYNAMIC, ULTRA_QUALITY, QUALITY, BALANCED, PERFORMANCE }

@export var mode: Mode = Mode.DYNAMIC
@export_range(0.0, 1.0) var sharpness: float = 0.5
@export var target_fps: float = 60.0
## The SubViewport that renders your 3D scene at reduced scale.
@export var scene_viewport: SubViewport

var controller: MabaController
var _mat: ShaderMaterial
var _last_size: Vector2i
var _applied_target_fps: float = 0.0
var _bound_viewport: SubViewport
var _last_ticks_usec: int = 0


func _ready() -> void:
	controller = MabaController.new(int(mode), target_fps)
	_applied_target_fps = target_fps
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://addons/maba_upscaler/shaders/maba_canvas.gdshader")
	material = _mat
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_bind_viewport()
	_last_ticks_usec = Time.get_ticks_usec()


# Wire the SubViewport's texture into the material; also picks up a viewport assigned later.
func _bind_viewport() -> void:
	if scene_viewport == _bound_viewport:
		return
	_bound_viewport = scene_viewport
	var tex: Texture2D = scene_viewport.get_texture() if scene_viewport else null
	texture = tex
	_mat.set_shader_parameter("src_linear", tex)
	_mat.set_shader_parameter("src_nearest", tex)


func _process(_delta: float) -> void:
	# Real wall-clock frame time: _process's delta is scaled by Engine.time_scale, which would
	# make slow motion look like GPU headroom (and a pause like an overload).
	var now := Time.get_ticks_usec()
	var frame_ms := float(now - _last_ticks_usec) / 1000.0
	_last_ticks_usec = now
	_bind_viewport()
	if scene_viewport == null:
		return
	var out := get_viewport_rect().size
	if out.x < 4 or out.y < 4:
		return
	# Present-to-present timing; Godot exposes no portable GPU timer to scripts.
	# set_target_fps / set_mode reset the controller's counters: only call them on a real
	# change, or Dynamic mode never accumulates enough frames to step.
	if target_fps != _applied_target_fps:
		_applied_target_fps = target_fps
		controller.set_target_fps(target_fps)
	if controller.mode != int(mode):
		controller.set_mode(int(mode))
	controller.begin_frame(frame_ms)
	var s := controller.scale()
	var rw := maxi(2, int(round(out.x * s)))
	var rh := maxi(2, int(round(out.y * s)))
	var want := Vector2i(rw, rh)
	if want != _last_size:
		_last_size = want
		scene_viewport.size = want
	_mat.set_shader_parameter("input_size", Vector4(rw, rh, 1.0 / rw, 1.0 / rh))
	_mat.set_shader_parameter("params", Vector4(sharpness, 0, 0, 0))
	_mat.set_shader_parameter("quality", 1 if controller.quality_shader() else 0)