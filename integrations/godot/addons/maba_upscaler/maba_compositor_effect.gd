# MABA Upscaler - CompositorEffect that upscales the viewport's internal (scaled) 3D colour
# to the output resolution with the MABA shader, via RenderingDevice.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
#
# GODOT VERSIONS: 4.3 and 4.4 (Forward+ and Mobile renderers, Vulkan only).
#
# HOW THIS FITS GODOT'S PIPELINE (verified against the 4.3/4.4 engine source):
#   The last compositor callback is POST_TRANSPARENT. At that point get_color_texture() is
#   the INTERNAL colour buffer, at the scaled resolution, in LINEAR space (before tonemap).
#   After this callback the engine's tonemap pass runs and performs the final internal ->
#   output resample (a bilinear stretch when scaling_3d_mode is BILINEAR). There is no
#   post-tonemap compositor hook in 4.3/4.4, so a compositor effect cannot be the literal
#   last pass to the screen.
#
#   Therefore this effect: (1) renders the MABA upscale from the internal colour into its
#   own OUTPUT-sized texture, then (2) blits that result back over the internal colour
#   buffer. The engine's tonemap then stretches it to the output. The MABA edge
#   reconstruction survives this; the extra down/up resample costs some sharpening crispness
#   versus a native single-pass MABA. This is an engine limitation, documented in README.md.
#
#   The colour-space conversion (linear <-> gamma 2.2) in the shader keeps the MABA maths in
#   the perceptual space it expects. For a faithful round-trip set the viewport tonemap mode
#   to Linear and exposure to 1; other tonemap modes re-curve the image after MABA.

class_name MabaCompositorEffect
extends CompositorEffect

@export_range(0.0, 1.0, 0.01) var sharpness: float = 0.5
@export var quality: bool = false
@export var convert_color_space: bool = true

var _rd: RenderingDevice
var _initialised := false
var _failed := false
var _shader_fast: RID
var _shader_quality: RID
var _shader_blit: RID
var _sampler: RID

# Pipelines are tied to a framebuffer FORMAT. The effect's own output texture and the
# engine's colour buffer have different usage flags, hence different formats, so the
# upscale pipelines and the blit pipeline are built (and rebuilt) separately.
var _pipeline_fast: RID
var _pipeline_quality: RID
var _upscale_fb_format: int = -1
var _pipeline_blit: RID
var _blit_fb_format: int = -1

var _color_rid: RID
var _color_fb: RID
var _input_set: RID
var _output_tex: RID
var _output_fb: RID
var _blit_set: RID
var _output_size := Vector2i.ZERO
var _output_format: int = -1


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_normal_roughness = false
	needs_motion_vectors = false
	access_resolved_color = false
	access_resolved_depth = false


func _shader_dir() -> String:
	return (get_script() as Script).resource_path.get_base_dir() + "/shaders"


func _split_sections(text: String) -> Dictionary:
	var vi := text.find("#[vertex]")
	var fi := text.find("#[fragment]")
	if vi < 0 or fi < 0:
		return {}
	return {
		"vertex": text.substr(vi + 9, fi - (vi + 9)).strip_edges(),
		"fragment": text.substr(fi + 11).strip_edges(),
	}


func _compile(shader_path: String, quality_variant: int) -> RID:
	var text := FileAccess.get_file_as_string(shader_path)
	var sec := _split_sections(text)
	if sec.is_empty():
		push_error("MABA: missing or malformed shader file " + shader_path)
		return RID()
	var frag: String = sec["fragment"]
	if quality_variant >= 0:
		frag = frag.replace("#version 450", "#version 450\n#define MABA_QUALITY %d" % quality_variant)
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_vertex = sec["vertex"]
	src.source_fragment = frag
	var spirv: RDShaderSPIRV = _rd.shader_compile_spirv_from_source(src)
	var err_v: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_VERTEX)
	var err_f: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_FRAGMENT)
	if err_v != "" or err_f != "":
		push_error("MABA shader compile error (%s): %s %s" % [shader_path, err_v, err_f])
		return RID()
	return _rd.shader_create_from_spirv(spirv)


func _make_pipeline(shader: RID, fb_format: int) -> RID:
	var raster := RDPipelineRasterizationState.new()
	raster.cull_mode = RenderingDevice.CULL_MODE_DISABLED
	var ms := RDPipelineMultisampleState.new()
	ms.sample_count = RenderingDevice.TEXTURE_SAMPLES_1
	var ds := RDPipelineDepthStencilState.new()
	ds.enable_depth_test = false
	ds.enable_depth_write = false
	var blend_att := RDPipelineColorBlendStateAttachment.new()
	blend_att.enable_blend = false
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [blend_att]
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
	_shader_fast = _compile(_shader_dir() + "/maba_upscaler.glsl", 0)
	_shader_quality = _compile(_shader_dir() + "/maba_upscaler.glsl", 1)
	_shader_blit = _compile(_shader_dir() + "/maba_blit.glsl", -1)
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


func _make_set(shader: RID, texture: RID) -> RID:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = 0
	u.add_id(_sampler)
	u.add_id(texture)
	return _rd.uniform_set_create([u], shader, 0)


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


func _render_callback(p_effect_callback_type: int, render_data: RenderData) -> void:
	if p_effect_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
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
	if internal_size.x < 2 or internal_size.y < 2 or target_size.x < 2 or target_size.y < 2:
		return
	# Nothing to do at native resolution.
	if internal_size.x >= target_size.x and internal_size.y >= target_size.y:
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
	if _output_size != target_size or _output_format != color_format or not _output_tex.is_valid():
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
	if not (_output_fb.is_valid() and _color_fb.is_valid()
			and _input_set.is_valid() and _blit_set.is_valid()):
		return

	# Pipelines for the two framebuffer formats.
	var upscale_format: int = _rd.framebuffer_get_format(_output_fb)
	if upscale_format != _upscale_fb_format or not _rd.render_pipeline_is_valid(_pipeline_fast):
		_free_pipeline(_pipeline_fast)
		_free_pipeline(_pipeline_quality)
		_upscale_fb_format = upscale_format
		_pipeline_fast = _make_pipeline(_shader_fast, upscale_format)
		_pipeline_quality = _make_pipeline(_shader_quality, upscale_format)
	var blit_format: int = _rd.framebuffer_get_format(_color_fb)
	if blit_format != _blit_fb_format or not _rd.render_pipeline_is_valid(_pipeline_blit):
		_free_pipeline(_pipeline_blit)
		_blit_fb_format = blit_format
		_pipeline_blit = _make_pipeline(_shader_blit, blit_format)
	if not (_pipeline_fast.is_valid() and _pipeline_quality.is_valid() and _pipeline_blit.is_valid()):
		return

	var iw := float(internal_size.x)
	var ih := float(internal_size.y)
	# The image fills the whole internal texture (Godot has no sub-region render like the
	# core's dynamic-resolution model), so region size == texture size == internal size.
	var input_size := Vector4(iw, ih, 1.0 / iw, 1.0 / ih)
	var params := Vector4(sharpness, 1.0 if convert_color_space else 0.0, 0.0, 0.0)
	var push := _push_bytes(input_size, params)

	# Pass 1: MABA upscale, internal colour -> output-sized texture.
	var dl := _begin_pass(_output_fb)
	_rd.draw_list_bind_render_pipeline(dl, _pipeline_quality if quality else _pipeline_fast)
	_rd.draw_list_bind_uniform_set(dl, _input_set, 0)
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


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _rd == null:
			return
		# Dependents first, then what they depend on; each free is validity-checked because
		# freeing a texture or shader already frees its framebuffers / sets / pipelines.
		_free_set(_input_set)
		_free_set(_blit_set)
		_free_fb(_color_fb)
		_free_fb(_output_fb)
		_free_pipeline(_pipeline_fast)
		_free_pipeline(_pipeline_quality)
		_free_pipeline(_pipeline_blit)
		_free_texture(_output_tex)
		for rid in [_shader_fast, _shader_quality, _shader_blit, _sampler]:
			if rid.is_valid():
				_rd.free_rid(rid)
