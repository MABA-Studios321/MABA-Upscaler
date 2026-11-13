# MABA Upscaler demo - spins a high-detail striped torus so the upscale is easy to judge.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0

extends Node3D

@export var spin_speed: float = 0.6

@onready var _knot: MeshInstance3D = $Knot


func _ready() -> void:
	_knot.rotation = Vector3(1.0, 0.0, 0.0)


func _process(delta: float) -> void:
	_knot.rotate_y(delta * spin_speed)
	_knot.rotate_x(delta * spin_speed * 0.35)