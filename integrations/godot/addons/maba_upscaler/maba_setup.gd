# MABA Upscaler - project / scene checks shared by the editor menu and the node's inspector
# warnings. Pure functions, no state, so they run (and are tested) without the editor.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
@tool
class_name MabaSetup
extends RefCounted

const ERROR := "error"
const WARNING := "warning"
const INFO := "info"


static func _item(level: String, text: String) -> Dictionary:
	return {"level": level, "text": text}


## Checks that depend only on the project settings. Returns [{level, text}].
static func check_project() -> Array:
	var items: Array = []
	var desktop := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus"))
	var mobile := str(ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", "mobile"))
	if desktop == "gl_compatibility":
		items.append(_item(ERROR, "The desktop renderer is Compatibility (OpenGL). MABA needs Forward+ or Mobile (Vulkan / D3D12 / Metal): compositor effects do not exist on Compatibility. Change Project Settings > Rendering > Renderer."))
	if mobile == "gl_compatibility":
		items.append(_item(WARNING, "The mobile renderer override is Compatibility (OpenGL), so MABA will not run on mobile exports. Set rendering_method.mobile to \"mobile\" or \"forward_plus\"."))
	if items.is_empty():
		items.append(_item(INFO, "Renderer: %s (desktop), %s (mobile) - supported." % [desktop, mobile]))
	return items


## Checks of a scene tree below `root` (the edited scene root in the editor).
static func check_scene(root: Node) -> Array:
	var items: Array = []
	if root == null:
		return [_item(ERROR, "No scene is open.")]
	var maba_nodes := root.find_children("*", "MabaUpscaler", true, false)
	if root is MabaUpscaler:
		maba_nodes.append(root)
	var cameras := root.find_children("*", "Camera3D", true, false)
	if root is Camera3D:
		cameras.append(root)
	if maba_nodes.is_empty():
		items.append(_item(WARNING, "The scene has no MabaUpscaler node (menu: Project > Tools > MABA Upscaler: add to open scene)."))
	elif maba_nodes.size() > 1:
		items.append(_item(WARNING, "The scene has %d MabaUpscaler nodes; use one per viewport." % maba_nodes.size()))
	if cameras.is_empty():
		items.append(_item(WARNING, "The scene has no Camera3D: MABA attaches to the viewport's current camera at run time."))
	var temporal := false
	for n in maba_nodes:
		if n.temporal:
			temporal = true
	for cam in cameras:
		if temporal and cam.projection != Camera3D.PROJECTION_PERSPECTIVE:
			items.append(_item(INFO, "Camera \"%s\" is not a perspective camera: the temporal tier leaves it alone (no jitter, so it only stabilises)." % cam.name))
	var envs := root.find_children("*", "WorldEnvironment", true, false)
	if root is WorldEnvironment:
		envs.append(root)
	for we in envs:
		var env: Environment = we.environment
		if env == null:
			continue
		if env.tonemap_mode != Environment.TONE_MAPPER_LINEAR:
			items.append(_item(WARNING, "WorldEnvironment \"%s\" tonemap is not Linear: MABA works on the linear image before the engine tonemap, so another curve re-shapes the result afterwards. Linear + exposure 1 is the faithful setup." % we.name))
		elif not is_equal_approx(env.tonemap_exposure, 1.0):
			items.append(_item(INFO, "WorldEnvironment \"%s\" tonemap exposure is %.2f (1.0 is the faithful setting)." % [we.name, env.tonemap_exposure]))
		if env.glow_enabled or env.adjustment_enabled:
			items.append(_item(INFO, "WorldEnvironment \"%s\" uses glow or colour adjustments; they run after MABA, on its result." % we.name))
	return items


## Everything, formatted for a dialog or the output panel.
static func report(root: Node) -> String:
	var lines := PackedStringArray()
	for item in check_project() + check_scene(root):
		var tags := {"error": "[ERROR]  ", "warning": "[WARNING]", "info": "[ok]     "}
		var tag: String = tags[item["level"]]
		lines.append("%s %s" % [tag, item["text"]])
	return "\n\n".join(lines)


## True when any item is an error (the effect cannot run).
static func has_errors(items: Array) -> bool:
	for item in items:
		if item["level"] == ERROR:
			return true
	return false


## The messages the editor shows next to a MabaUpscaler node (warning triangle).
static func configuration_warnings(node: Node) -> PackedStringArray:
	var out := PackedStringArray()
	for item in check_project():
		if item["level"] != INFO:
			out.append(item["text"])
	var scene_root := node.owner if node.owner != null else node
	var has_camera := not scene_root.find_children("*", "Camera3D", true, false).is_empty()
	if not has_camera:
		out.append("No Camera3D found in this scene. MABA needs a camera: it attaches to the viewport's current one.")
	for item in check_scene(scene_root):
		if item["level"] == WARNING and "tonemap" in item["text"]:
			out.append(item["text"])
	return out


## Sets the recommended tonemap (Linear, exposure 1) on every WorldEnvironment in the scene.
## Returns how many environments were changed.
static func apply_recommended(root: Node, undo_redo: EditorUndoRedoManager = null) -> int:
	var changed := 0
	if root == null:
		return 0
	var envs := root.find_children("*", "WorldEnvironment", true, false)
	if root is WorldEnvironment:
		envs.append(root)
	for we in envs:
		var env: Environment = we.environment
		if env == null:
			continue
		if env.tonemap_mode == Environment.TONE_MAPPER_LINEAR and is_equal_approx(env.tonemap_exposure, 1.0):
			continue
		if undo_redo != null:
			undo_redo.create_action("MABA: recommended tonemap")
			undo_redo.add_do_property(env, "tonemap_mode", Environment.TONE_MAPPER_LINEAR)
			undo_redo.add_undo_property(env, "tonemap_mode", env.tonemap_mode)
			undo_redo.add_do_property(env, "tonemap_exposure", 1.0)
			undo_redo.add_undo_property(env, "tonemap_exposure", env.tonemap_exposure)
			undo_redo.commit_action()
		else:
			env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
			env.tonemap_exposure = 1.0
		changed += 1
	return changed
