# MABA Upscaler demo - spins a high-detail striped torus so the upscale is easy to judge, and shows
# how to drive the node from code.
#
#   1 .. 5   Dynamic / Ultra Quality / Quality / Balanced / Performance
#   T        temporal tier on / off          R   reset the temporal history
#   S        cycle sharpness 0.25 / 0.5 / 0.75 / 1.0
#   C        camera orbit on / off (the temporal tier shows its worth when things move)
#   H        stats label on / off
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0

extends Node3D

@export var spin_speed: float = 0.6

@onready var _knot: MeshInstance3D = $Knot
@onready var _camera: Camera3D = $Camera3D
@onready var _maba: MabaUpscaler = $MabaUpscaler

var _orbit := false
var _orbit_angle := 0.0
var _sharpness_steps := [0.25, 0.5, 0.75, 1.0]
var _sharpness_index := 1


func _ready() -> void:
	_knot.rotation = Vector3(1.0, 0.0, 0.0)
	_maba.show_stats = true
	print("MABA demo: 1-5 mode, T temporal, R reset history, S sharpness, C camera orbit, H stats")


func _process(delta: float) -> void:
	_knot.rotate_y(delta * spin_speed)
	_knot.rotate_x(delta * spin_speed * 0.35)
	if _orbit:
		_orbit_angle += delta * 0.5
		_camera.position = Vector3(sin(_orbit_angle) * 4.5, 0.6 * sin(_orbit_angle * 0.7), cos(_orbit_angle) * 4.5)
		_camera.look_at(Vector3.ZERO)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_1: _maba.set_mode(MabaUpscaler.Mode.DYNAMIC)
		KEY_2: _maba.set_mode(MabaUpscaler.Mode.ULTRA_QUALITY)
		KEY_3: _maba.set_mode(MabaUpscaler.Mode.QUALITY)
		KEY_4: _maba.set_mode(MabaUpscaler.Mode.BALANCED)
		KEY_5: _maba.set_mode(MabaUpscaler.Mode.PERFORMANCE)
		KEY_T: _maba.set_temporal(not _maba.temporal)
		KEY_R: _maba.reset_history()
		KEY_H: _maba.show_stats = not _maba.show_stats
		KEY_C:
			_orbit = not _orbit
			_maba.reset_history()   # a camera cut: drop the history
		KEY_S:
			_sharpness_index = (_sharpness_index + 1) % _sharpness_steps.size()
			_maba.set_sharpness(_sharpness_steps[_sharpness_index])
