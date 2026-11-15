# MABA Upscaler - CompositorEffect that upscales the viewport's internal (scaled) 3D colour
# to the output resolution with the MABA shader, via RenderingDevice. Optionally runs the
# MABA-Upscaler 2 (Temporal) resolve first.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
#
# GODOT VERSIONS: tested on 4.7 (Forward+, Vulkan). Written against the 4.3 / 4.4 API too, but
# only 4.7 has been run (see README). Forward+ and Mobile renderers, Vulkan only.
#
# HOW THIS FITS GODOT'S PIPELINE:
#   The last compositor callback is POST_TRANSPARENT. At that point get_color_texture() is
#   the INTERNAL colour buffer, at the scaled resolution, in LINEAR space (before tonemap).
#   After this callback the engine's tonemap pass runs and performs the final internal ->
#   output resample (a bilinear stretch when scaling_3d_mode is BILINEAR). There is no
#   post-tonemap compositor hook in 4.3/4.4, so a compositor effect cannot be the literal
#   last pass to the screen.
#
#   Therefore this effect: (0, optional) resolves the temporal history at internal resolution,
#   (1) renders the MABA upscale from the (resolved) internal colour into its own OUTPUT-sized
#   texture, then (2) blits that result back over the internal colour buffer. The engine's
#   tonemap then stretches it to the output. The MABA edge reconstruction survives this; the
#   extra down/up resample costs some sharpening crispness versus a native single-pass MABA.
#   This is an engine limitation, documented in README.md.
#
#   The colour-space conversion (linear <-> gamma 2.2) in the shader keeps the MABA maths in
#   the perceptual space it expects. For a faithful round-trip set the viewport tonemap mode
#   to Linear and exposure to 1; other tonemap modes re-curve the image after MABA.
#
# TEMPORAL TIER:
#   MabaUpscaler (the node) jitters the camera's projection by a sub-texel amount each frame
#   (Camera3D frustum mode). This effect reads the jitter back from the frame's own projection
#   matrix, so there is no thread race between the node and the renderer, reprojects the history
#   with the scene depth and the renderer's camera matrices (the same method as the Unity and
#   Unreal integrations), clamps it to the current frame's neighbourhood in YCoCg and blends.
#   History (colour and depth) lives in textures owned by this effect, at internal resolution.

class_name MabaCompositorEffect
extends CompositorEffect

@export_range(0.0, 1.0, 0.01) var sharpness: float = 0.5
@export var quality: bool = false
@export var convert_color_space: bool = true

## MABA-Upscaler 2 (Temporal). Needs a node that jitters the camera (MabaUpscaler does that);
## without jitter it only stabilises and adds no detail.
@export var temporal: bool = false
## How much of the previous frame is kept, 0.80 - 0.95. Higher is steadier and ghosts more.
@export_range(0.5, 0.98, 0.01) var history_weight: float = 0.9
## Width of the colour clamp that rejects ghosts, 1.0 - 1.5.
@export_range(0.5, 3.0, 0.05) var clip_gamma: float = 1.25
## How fast history is distrusted as a pixel moves: weight / (1 + K * motion in texels).
@export_range(0.0, 16.0, 0.1) var motion_k: float = 4.0
## Relative depth difference that rejects history, 0.005 - 0.02.
@export_range(0.001, 0.1, 0.001) var depth_tolerance: float = 0.01

# Sign convention between the projection's off-centre terms and the shader's texel space; fixed by
# calibration against a supersampled reference (see test/render_test.gd), exposed so the test can
# scan it.
var jitter_read_sign := Vector2(1.0, 1.0) # projection offset -> jitter in texels
var jitter_shift_read := 0.0               # 1: read each frame at +jitter (bilinear); 0: accumulate point samples
var debug_log := false                    # print what the resolve sees (test / diagnostics)

# Filled every frame, read by the node (statistics / diagnostics).
var temporal_ran := false
var temporal_fail_reason := ""   # why the resolve did not run on the last frame (diagnostics)
var callbacks := 0                  # diagnostics: callbacks seen / resolves run
var resolves := 0
var last_internal_size := Vector2i.ZERO

var _rd: RenderingDevice
var _initialised := false
var _failed := false
var _shader_fast: RID
var _shader_quality: RID
var _shader_blit: RID
var _shader_temporal: RID
var _temporal_failed := false
var _sampler: RID

# Pipelines are tied to a framebuffer FORMAT. The effect's own output texture and the
# engine's colour buffer have different usage flags, hence different formats, so the
# upscale pipelines and the blit pipeline are built (and rebuilt) separately.
var _pipeline_fast: RID
var _pipeline_quality: RID
var _upscale_fb_format: int = -1
var _pipeline_blit: RID
var _blit_fb_format: int = -1
var _pipeline_temporal: RID
var _temporal_fb_format: int = -1

var _color_rid: RID
var _color_fb: RID
var _input_set: RID
var _output_tex: RID
var _output_fb: RID
var _blit_set: RID
var _output_size := Vector2i.ZERO
var _output_format: int = -1

# Temporal state: two history textures that swap roles every frame.
var _hist_tex: Array[RID] = [RID(), RID()]
var _hist_depth: Array[RID] = [RID(), RID()]        # last frame's scene depth (R32F), written by the resolve
var _hist_fb: Array[RID] = [RID(), RID()]
var _hist_input_set: Array[RID] = [RID(), RID()]   # spatial-upscale input sets over the history
var _hist_blit_set: Array[RID] = [RID(), RID()]    # blit sets over the history (native-size output)
var _temporal_set: Array[RID] = [RID(), RID()]     # resolve inputs: current, history, depth, previous depth
var _temporal_set_key: Array = [null, null]
var _hist_size := Vector2i.ZERO
var _hist_format: int = -1
var _hist_out := 0                  # index of the history texture written this frame
var _have_history := false
var _prev_view_proj := Projection.IDENTITY   # last frame's UNJITTERED view-projection
var _last_frame := -100
var _reset_requested := true
var _warned_depth := false


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_normal_roughness = false
	needs_motion_vectors = false
	access_resolved_color = false
	access_resolved_depth = false


## Drop the temporal history (camera cut, teleport, scene change). The next frame starts fresh.
func reset_history() -> void:
	_reset_requested = true


func _shader_dir() -> String:
	return (get_script() as Script).resource_path.get_base_dir() + "/shaders"


# The .glsl files are imported by Godot as RDShaderFile resources: compiled to SPIR-V at import time
# and exported with the game (reading the source text with FileAccess does NOT work in an exported
# game). `version` selects a build declared in the file's #[versions] block (&"" = the only build).
func _load_shader(shader_path: String, version: StringName) -> RID:
	var shader_file := load(shader_path) as RDShaderFile
	if shader_file == null:
		push_error("MABA: cannot load shader " + shader_path + " (is the addon folder complete? the .glsl files must be imported)")
		return RID()
	var spirv: RDShaderSPIRV = shader_file.get_spirv(version)
	if spirv == null:
		push_error("MABA: shader %s has no build named '%s'" % [shader_path, version])
		return RID()
	var err_v: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_VERTEX)
	var err_f: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_FRAGMENT)
	if err_v != "" or err_f != "":
		push_error("MABA shader compile error (%s): %s %s" % [shader_path, err_v, err_f])
		return RID()
	return _rd.shader_create_from_spirv(spirv)

func _make_pipeline(shader: RID, fb_format: int, attachments: int = 1) -> RID:
	var raster := RDPipelineRasterizationState.new()
	raster.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var ms := RDPipelineMultisampleState.new()
	ms.sample_count = RenderingDevice.TEXTURE_SAMPLES_1
	var ds := RDPipelineDepthStencilState.new()
	ds.enable_depth_test = false
	ds.enable_depth_write = false
	var blend := RDPipelineColorBlendState.new()
	var blend_atts: Array[RDPipelineColorBlendStateAttachment] = []
	for i in attachments:
		var blend_att := RDPipelineColorBlendStateAttachment.new()
		blend_att.enable_blend = false
		blend_atts.append(blend_att)
	blend.attachments = blend_atts
	# No vertex buffers: the full-screen triangle comes from gl_VertexIndex.
	return _rd.render_pipeline_create(shader, fb_format, RenderingDevice.INVALID_ID,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster, ms, ds, blend)


func _ensure_ready() -> bool:
	if _initialised:
		return true
	if _failed:
		return false
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_failed = true
		return false
	_shader_fast = _load_shader(_shader_dir() + "/maba_upscaler.glsl", &"fast")
	_shader_quality = _load_shader(_shader_dir() + "/maba_upscaler.glsl", &"quality")
	_shader_blit = _load_shader(_shader_dir() + "/maba_blit.glsl", &"")
	if not (_shader_fast.is_valid() and _shader_quality.is_valid() and _shader_blit.is_valid()):
		_failed = true   # do not recompile (and re-report) every frame
		return false

	var ss := RDSamplerState.new()
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)
	_initialised = true
	return true


# The temporal shader is only compiled the first time the tier is used.
func _ensure_temporal() -> bool:
	if _shader_temporal.is_valid():
		return true
	if _temporal_failed:
		return false
	_shader_temporal = _load_shader(_shader_dir() + "/maba_temporal.glsl", &"")
	if not _shader_temporal.is_valid():
		_temporal_failed = true
		return false
	return true


func _make_set(shader: RID, texture: RID) -> RID:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = 0
	u.add_id(_sampler)
	u.add_id(texture)
	return _rd.uniform_set_create([u], shader, 0)


func _make_temporal_set(cur: RID, hist: RID, depth: RID, prev_depth: RID) -> RID:
	var uniforms: Array[RDUniform] = []
	var binding := 0
	for tex in [cur, hist, depth, prev_depth]:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u.binding = binding
		u.add_id(_sampler)
		u.add_id(tex)
		uniforms.append(u)
		binding += 1
	return _rd.uniform_set_create(uniforms, _shader_temporal, 0)

# Framebuffers, uniform sets and pipelines are freed by the RenderingDevice automatically
# when something they depend on is freed (for example the engine recreating its colour
# buffer on resize), so check real validity before freeing to avoid invalid-RID errors.
func _free_fb(fb: RID) -> void:
	if fb.is_valid() and _rd.framebuffer_is_valid(fb):
		_rd.free_rid(fb)


func _free_set(uniform_set: RID) -> void:
	if uniform_set.is_valid() and _rd.uniform_set_is_valid(uniform_set):
		_rd.free_rid(uniform_set)


func _free_pipeline(pipeline: RID) -> void:
	if pipeline.is_valid() and _rd.render_pipeline_is_valid(pipeline):
		_rd.free_rid(pipeline)


func _free_texture(texture: RID) -> void:
	if texture.is_valid() and _rd.texture_is_valid(texture):
		_rd.free_rid(texture)


func _free_history() -> void:
	for i in 2:
		_free_set(_temporal_set[i])
		_free_set(_hist_input_set[i])
		_free_set(_hist_blit_set[i])
		_free_fb(_hist_fb[i])
		_free_texture(_hist_tex[i])
		_free_texture(_hist_depth[i])
		_temporal_set[i] = RID()
		_hist_input_set[i] = RID()
		_hist_blit_set[i] = RID()
		_hist_fb[i] = RID()
		_hist_tex[i] = RID()
		_hist_depth[i] = RID()
		_temporal_set_key[i] = null
	_have_history = false

# draw_list_begin changed its argument list between Godot 4.3 (initial/final actions) and
# 4.4 (draw flags). Calling it through callv keeps this script loadable on both.
func _begin_pass(fb: RID) -> int:
	if Engine.get_version_info().hex >= 0x040400:
		return _rd.callv("draw_list_begin", [fb])
	# 4.3: INITIAL_ACTION_LOAD (0) / FINAL_ACTION_STORE (0) for colour and depth.
	return _rd.callv("draw_list_begin", [fb, 0, 0, 0, 0])


func _push_bytes(input_size: Vector4, params: Vector4) -> PackedByteArray:
	return PackedFloat32Array([
		input_size.x, input_size.y, input_size.z, input_size.w,
		params.x, params.y, params.z, params.w,
	]).to_byte_array()


# 112 bytes (inside Vulkan's guaranteed 128-byte push-constant block): mat4 + 3 vec4.
func _push_temporal(size: Vector2i, jitter: Vector2, cur_to_prev: Projection, reset: bool) -> PackedByteArray:
	var m := cur_to_prev
	return PackedFloat32Array([
		m.x.x, m.x.y, m.x.z, m.x.w, m.y.x, m.y.y, m.y.z, m.y.w,
		m.z.x, m.z.y, m.z.z, m.z.w, m.w.x, m.w.y, m.w.z, m.w.w,
		size.x, size.y, 1.0 / size.x, 1.0 / size.y,
		jitter.x, jitter.y, depth_tolerance, jitter_shift_read,
		history_weight, 1.0 if reset else 0.0, clip_gamma, motion_k,
	]).to_byte_array()


func _new_target_texture(size: Vector2i, format: int) -> RID:
	var tfmt := RDTextureFormat.new()
	tfmt.format = format
	tfmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tfmt.width = size.x
	tfmt.height = size.y
	tfmt.depth = 1
	tfmt.array_layers = 1
	tfmt.mipmaps = 1
	tfmt.samples = RenderingDevice.TEXTURE_SAMPLES_1
	tfmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT
	return _rd.texture_create(tfmt, RDTextureView.new())


# (Re)creates the history textures (colour + depth, two of each) for this internal size / colour format.
func _ensure_history(size: Vector2i, color_format: int) -> bool:
	if size == _hist_size and color_format == _hist_format and _hist_tex[0].is_valid() \
			and _hist_tex[1].is_valid() and _rd.texture_is_valid(_hist_tex[0]):
		return true
	_free_history()
	_hist_size = size
	_hist_format = color_format
	for i in 2:
		_hist_tex[i] = _new_target_texture(size, color_format)
		_hist_depth[i] = _new_target_texture(size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
		if not (_hist_tex[i].is_valid() and _hist_depth[i].is_valid()):
			_free_history()
			return false
		_hist_fb[i] = _rd.framebuffer_create([_hist_tex[i], _hist_depth[i]])
		_hist_input_set[i] = _make_set(_shader_fast, _hist_tex[i])
		_hist_blit_set[i] = _make_set(_shader_blit, _hist_tex[i])
	var fmt := _rd.framebuffer_get_format(_hist_fb[0])
	if fmt != _temporal_fb_format or not _rd.render_pipeline_is_valid(_pipeline_temporal):
		_free_pipeline(_pipeline_temporal)
		_temporal_fb_format = fmt
		_pipeline_temporal = _make_pipeline(_shader_temporal, fmt, 2)
	return _pipeline_temporal.is_valid()


# The renderer's own camera: view-projection with the jitter taken out. Godot's projection is
# symmetric (our frustum only moves it off-centre by the jitter), so the jitter lives entirely in the
# z column's x / y terms.
func _unjittered_view_proj(render_data: RenderData) -> Projection:
	var scene_data := render_data.get_render_scene_data()
	var proj: Projection = scene_data.get_cam_projection()
	proj.z = Vector4(0.0, 0.0, proj.z.z, proj.z.w)
	var view := Projection(scene_data.get_cam_transform().affine_inverse())
	return proj * view


# Runs the resolve: current colour + history + depth -> the other history texture (colour and depth).
# Returns false (and leaves everything as it was) when the tier cannot run this frame.
func _run_temporal(render_data: RenderData, buffers: RenderSceneBuffersRD, color: RID,
		size: Vector2i, color_format: int) -> bool:
	if not _ensure_temporal():
		temporal_fail_reason = "temporal shader failed to compile"
		return false
	var depth: RID = buffers.get_depth_layer(0)
	if not depth.is_valid():
		if not _warned_depth:
			_warned_depth = true
			push_warning("MABA temporal: no depth buffer available; running spatial only.")
		temporal_fail_reason = "no depth buffer"
		return false
	if not _ensure_history(size, color_format):
		temporal_fail_reason = "history textures could not be created"
		return false

	# Jitter of this frame, read back from the projection the renderer actually used.
	var proj: Projection = render_data.get_render_scene_data().get_cam_projection()
	var jitter := Vector2(proj.z.x * jitter_read_sign.x * 0.5 * size.x,
			proj.z.y * jitter_read_sign.y * 0.5 * size.y)

	var frame := Engine.get_frames_drawn()
	var reset := _reset_requested or not _have_history or (frame - _last_frame) > 2
	_reset_requested = false

	# One matrix from this frame's clip space to last frame's: the large world offsets cancel
	# before anything reaches the GPU.
	var view_proj := _unjittered_view_proj(render_data)
	var cur_to_prev := _prev_view_proj * view_proj.inverse()

	# The two history sets swap roles every frame: _hist_out is written now, the other one holds
	# last frame's resolve and depth.
	_hist_out = 1 - _hist_out
	var write_idx := _hist_out
	var read_idx := 1 - write_idx

	var key := [color, _hist_tex[read_idx], depth, _hist_depth[read_idx]]
	if _temporal_set_key[write_idx] != key or not _rd.uniform_set_is_valid(_temporal_set[write_idx]):
		_free_set(_temporal_set[write_idx])
		_temporal_set[write_idx] = _make_temporal_set(color, _hist_tex[read_idx], depth, _hist_depth[read_idx])
		_temporal_set_key[write_idx] = key
	if not _temporal_set[write_idx].is_valid():
		temporal_fail_reason = "resolve uniform set could not be created (depth texture not sampleable?)"
		return false

	if debug_log and frame % 10 == 0:
		print("MABADBG frame ", frame, " size ", size, " proj.z ", proj.z, " jitter px ", jitter, " reset ", reset,
			" c2p diag ", cur_to_prev.x.x, " ", cur_to_prev.y.y, " ", cur_to_prev.z.z, " c2p w ", cur_to_prev.w)
	var push := _push_temporal(size, jitter, cur_to_prev, reset)
	var dl := _begin_pass(_hist_fb[write_idx])
	_rd.draw_list_bind_render_pipeline(dl, _pipeline_temporal)
	_rd.draw_list_bind_uniform_set(dl, _temporal_set[write_idx], 0)
	_rd.draw_list_set_push_constant(dl, push, push.size())
	_rd.draw_list_draw(dl, false, 1, 3)
	_rd.draw_list_end()

	_prev_view_proj = view_proj
	_last_frame = frame
	_have_history = true
	temporal_fail_reason = ""
	return true

func _render_callback(p_effect_callback_type: int, render_data: RenderData) -> void:
	if p_effect_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	callbacks += 1
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	if not _ensure_ready():
		return

	# Single-view only; XR / multiview is not handled by this integration.
	if buffers.get_view_count() != 1:
		return

	var internal_size: Vector2i = buffers.get_internal_size()
	var target_size: Vector2i = buffers.get_target_size()
	last_internal_size = internal_size
	if internal_size.x < 2 or internal_size.y < 2 or target_size.x < 2 or target_size.y < 2:
		return
	var native := internal_size.x >= target_size.x and internal_size.y >= target_size.y
	# Nothing to do at native resolution, unless the temporal tier supplies the anti-aliasing.
	if native and not temporal:
		temporal_ran = false
		return

	# View 0 as a 2D slice: the full colour texture can be a texture array, which a sampler2D
	# cannot read.
	var color: RID = buffers.get_color_layer(0)
	if not color.is_valid():
		return

	# Match the engine's internal colour format so the blit-back is a straight copy.
	var color_format: int = _rd.texture_get_format(color).format

	# Output-sized intermediate, owned by this effect and recreated only on resize or when
	# the colour format changes. We use rd.texture_create rather than
	# RenderSceneBuffers.create_texture because that binding's argument list differs between
	# Godot 4.3 and 4.4.
	if not native and (_output_size != target_size or _output_format != color_format or not _output_tex.is_valid()):
		_free_set(_blit_set)
		_free_fb(_output_fb)
		_free_texture(_output_tex)
		_blit_set = RID()
		_output_fb = RID()
		_output_tex = RID()
		_output_size = target_size
		_output_format = color_format
		var tfmt := RDTextureFormat.new()
		tfmt.format = color_format
		tfmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		tfmt.width = target_size.x
		tfmt.height = target_size.y
		tfmt.depth = 1
		tfmt.array_layers = 1
		tfmt.mipmaps = 1
		tfmt.samples = RenderingDevice.TEXTURE_SAMPLES_1
		tfmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT
		_output_tex = _rd.texture_create(tfmt, RDTextureView.new())
		if not _output_tex.is_valid():
			return
		_output_fb = _rd.framebuffer_create([_output_tex])
		_blit_set = _make_set(_shader_blit, _output_tex)

	# (Re)build the input framebuffer and uniform set when the colour texture changes, or
	# when the engine freed the old one underneath us.
	if color != _color_rid or not _rd.framebuffer_is_valid(_color_fb) \
			or not _rd.uniform_set_is_valid(_input_set):
		_free_fb(_color_fb)
		_free_set(_input_set)
		_color_rid = color
		_color_fb = _rd.framebuffer_create([color])
		_input_set = _make_set(_shader_fast, color)
	if not (_color_fb.is_valid() and _input_set.is_valid()):
		return
	if not native and not (_output_fb.is_valid() and _blit_set.is_valid()):
		return

	# Pipelines for the framebuffer formats.
	var blit_format: int = _rd.framebuffer_get_format(_color_fb)
	if blit_format != _blit_fb_format or not _rd.render_pipeline_is_valid(_pipeline_blit):
		_free_pipeline(_pipeline_blit)
		_blit_fb_format = blit_format
		_pipeline_blit = _make_pipeline(_shader_blit, blit_format)
	if not _pipeline_blit.is_valid():
		return
	if not native:
		var upscale_format: int = _rd.framebuffer_get_format(_output_fb)
		if upscale_format != _upscale_fb_format or not _rd.render_pipeline_is_valid(_pipeline_fast):
			_free_pipeline(_pipeline_fast)
			_free_pipeline(_pipeline_quality)
			_upscale_fb_format = upscale_format
			_pipeline_fast = _make_pipeline(_shader_fast, upscale_format)
			_pipeline_quality = _make_pipeline(_shader_quality, upscale_format)
		if not (_pipeline_fast.is_valid() and _pipeline_quality.is_valid()):
			return

	# Pass 0 (optional): temporal resolve at internal resolution.
	var source_set: RID = _input_set
	var ran_temporal := false
	if temporal:
		ran_temporal = _run_temporal(render_data, buffers, color, internal_size, color_format)
		if ran_temporal:
			source_set = _hist_input_set[_hist_out]
	temporal_ran = ran_temporal
	if ran_temporal:
		resolves += 1
	elif temporal and temporal_fail_reason == "":
		temporal_fail_reason = "resolve skipped"
	if not temporal and _have_history:
		_free_history()
		_reset_requested = true

	if native:
		# Native size: the resolved image goes straight back over the colour buffer.
		if ran_temporal:
			var dl0 := _begin_pass(_color_fb)
			_rd.draw_list_bind_render_pipeline(dl0, _pipeline_blit)
			_rd.draw_list_bind_uniform_set(dl0, _hist_blit_set[_hist_out], 0)
			_rd.draw_list_draw(dl0, false, 1, 3)
			_rd.draw_list_end()
		return

	var iw := float(internal_size.x)
	var ih := float(internal_size.y)
	# The image fills the whole internal texture (Godot has no sub-region render like the
	# core's dynamic-resolution model), so region size == texture size == internal size.
	var input_size := Vector4(iw, ih, 1.0 / iw, 1.0 / ih)
	var params := Vector4(sharpness, 1.0 if convert_color_space else 0.0, 0.0, 0.0)
	var push := _push_bytes(input_size, params)

	# Pass 1: MABA upscale, internal colour (or the resolve) -> output-sized texture.
	var dl := _begin_pass(_output_fb)
	_rd.draw_list_bind_render_pipeline(dl, _pipeline_quality if quality else _pipeline_fast)
	_rd.draw_list_bind_uniform_set(dl, source_set, 0)
	_rd.draw_list_set_push_constant(dl, push, push.size())
	_rd.draw_list_draw(dl, false, 1, 3)
	_rd.draw_list_end()

	# Pass 2: blit the upscaled result back over the internal colour buffer. The engine's
	# tonemap pass then resamples it to the output resolution.
	dl = _begin_pass(_color_fb)
	_rd.draw_list_bind_render_pipeline(dl, _pipeline_blit)
	_rd.draw_list_bind_uniform_set(dl, _blit_set, 0)
	_rd.draw_list_draw(dl, false, 1, 3)
	_rd.draw_list_end()


## Frees every GPU object this effect created. MabaUpscaler calls it when it removes the effect; it
## is also safe to call yourself before dropping the last reference. (It cannot run from the
## destructor: GDScript methods are no longer callable by then.)
func release() -> void:
	if _rd == null:
		return
	# Dependents first, then what they depend on; each free is validity-checked because
	# freeing a texture or shader already frees its framebuffers / sets / pipelines.
	_free_set(_input_set)
	_free_set(_blit_set)
	_free_history()
	_free_fb(_color_fb)
	_free_fb(_output_fb)
	_free_pipeline(_pipeline_fast)
	_free_pipeline(_pipeline_quality)
	_free_pipeline(_pipeline_blit)
	_free_pipeline(_pipeline_temporal)
	_free_texture(_output_tex)
	for rid in [_shader_fast, _shader_quality, _shader_blit, _shader_temporal, _sampler]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_input_set = RID()
	_blit_set = RID()
	_color_fb = RID()
	_output_fb = RID()
	_pipeline_fast = RID()
	_pipeline_quality = RID()
	_pipeline_blit = RID()
	_pipeline_temporal = RID()
	_output_tex = RID()
	_shader_fast = RID()
	_shader_quality = RID()
	_shader_blit = RID()
	_shader_temporal = RID()
	_sampler = RID()
	_color_rid = RID()
	_initialised = false
	_failed = false
	_temporal_failed = false
	_output_size = Vector2i.ZERO
	_output_format = -1
	_upscale_fb_format = -1
	_blit_fb_format = -1
	_temporal_fb_format = -1
	_hist_size = Vector2i.ZERO
	_hist_format = -1
