# MABA Upscaler - GDScript port of the dynamic controller in maba_upscaler.h.
# Kept line-for-line in sync; desk-checked against the C header (no Godot on the build machine).
# Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
class_name MabaController
extends RefCounted

const RUNG_COUNT := 29
const RUNG_MIN := 0
const RUNG_MAX := RUNG_COUNT - 1

const MODE_DYNAMIC := 0
const MODE_ULTRA_QUALITY := 1
const MODE_QUALITY := 2
const MODE_BALANCED := 3
const MODE_PERFORMANCE := 4

const START_RUNG := 10
const OVER_RATIO := 1.02
const DOWN_FRAMES := 20
const UP_FRAMES := 180
const UP_FRAMES_MAX := 3600
const PROVEN_FRAMES := 300

var mode: int
var target_ms: float
var rung: int
var avg_ms: float
var over_frames: int
var good_frames: int
var up_wait: int
var probing: bool


func _init(p_mode: int = MODE_DYNAMIC, target_fps: float = 60.0) -> void:
	target_ms = 1000.0 / (target_fps if target_fps > 1.0 else 60.0)
	set_mode(p_mode)


static func rung_scale(r: int) -> float:
	return (50 + r) * 0.01 if r <= 9 else (49 + r) * 0.01


static func rung_quality(r: int) -> bool:
	return r >= 10


static func mode_rung(m: int) -> int:
	match m:
		MODE_ULTRA_QUALITY: return 28
		MODE_QUALITY: return 18
		MODE_BALANCED: return 10
		MODE_PERFORMANCE: return 0
		_: return START_RUNG


func scale() -> float:
	return rung_scale(rung)


func quality_shader() -> bool:
	return rung_quality(rung)


func set_mode(m: int) -> void:
	mode = m
	rung = mode_rung(m)
	avg_ms = 0.0
	over_frames = 0
	good_frames = 0
	up_wait = UP_FRAMES
	probing = false


func set_target_fps(fps: float) -> void:
	target_ms = 1000.0 / (fps if fps > 1.0 else 60.0)
	avg_ms = 0.0
	over_frames = 0
	good_frames = 0
	probing = false


func seed_rung(r: int) -> void:
	rung = clampi(r, RUNG_MIN, RUNG_MAX)
	avg_ms = 0.0
	over_frames = 0
	good_frames = 0
	probing = false


func update_dynamic(frame_ms: float) -> void:
	if frame_ms <= 0.0 or frame_ms > 1000.0:
		return
	avg_ms = frame_ms if avg_ms <= 0.0 else avg_ms + (frame_ms - avg_ms) * 0.1
	if avg_ms > target_ms * OVER_RATIO:
		good_frames = 0
		over_frames += 1
		if over_frames >= DOWN_FRAMES and rung > RUNG_MIN:
			rung -= 1
			over_frames = 0
			avg_ms = target_ms
			if probing:
				up_wait = mini(up_wait * 2, UP_FRAMES_MAX)
				probing = false
	else:
		over_frames = 0
		good_frames += 1
		if probing and good_frames >= PROVEN_FRAMES:
			probing = false
			up_wait = maxi(UP_FRAMES, up_wait / 2)
		if not probing and good_frames >= up_wait and rung < RUNG_MAX:
			rung += 1
			good_frames = 0
			probing = true


func begin_frame(last_frame_ms: float) -> int:
	if mode == MODE_DYNAMIC:
		update_dynamic(last_frame_ms)
	return rung