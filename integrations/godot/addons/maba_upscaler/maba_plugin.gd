# MABA Upscaler - editor plugin.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
#
# Adds three entries to Project > Tools:
#   MABA Upscaler: add to open scene      adds a MabaUpscaler node (undoable)
#   MABA Upscaler: check setup            reports renderer / camera / tonemap problems
#   MABA Upscaler: apply recommended      sets WorldEnvironment tonemap to Linear, exposure 1 (undoable)
#
# MabaUpscaler and MabaUpscalerRect declare class_name, so they already appear in the Create
# Node dialog; this plugin does not register them again (that would list each node twice).

@tool
extends EditorPlugin

const MENU_ADD := "MABA Upscaler: add to open scene"
const MENU_CHECK := "MABA Upscaler: check setup"
const MENU_APPLY := "MABA Upscaler: apply recommended settings"

var _dialog: AcceptDialog


func _enter_tree() -> void:
	add_tool_menu_item(MENU_ADD, _add_to_scene)
	add_tool_menu_item(MENU_CHECK, _check_setup)
	add_tool_menu_item(MENU_APPLY, _apply_recommended)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_ADD)
	remove_tool_menu_item(MENU_CHECK)
	remove_tool_menu_item(MENU_APPLY)
	if _dialog != null:
		_dialog.queue_free()
		_dialog = null


func _show(title: String, text: String) -> void:
	if _dialog == null:
		_dialog = AcceptDialog.new()
		_dialog.min_size = Vector2i(640, 260)
		EditorInterface.get_base_control().add_child(_dialog)
	_dialog.title = title
	_dialog.dialog_text = text
	_dialog.popup_centered()


func _add_to_scene() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_show("MABA Upscaler", "Open a 3D scene first.")
		return
	if not root.find_children("*", "MabaUpscaler", true, false).is_empty() or root is MabaUpscaler:
		_show("MABA Upscaler", "This scene already has a MabaUpscaler node.")
		return
	var node := MabaUpscaler.new()
	node.name = "MabaUpscaler"
	var undo := get_undo_redo()
	undo.create_action("Add MabaUpscaler")
	undo.add_do_method(root, "add_child", node, true)
	undo.add_do_method(node, "set_owner", root)
	undo.add_do_reference(node)
	undo.add_undo_method(root, "remove_child", node)
	undo.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)
	_show("MABA Upscaler", "Added a MabaUpscaler node.\n\n" + MabaSetup.report(root))


func _check_setup() -> void:
	_show("MABA Upscaler: setup check", MabaSetup.report(EditorInterface.get_edited_scene_root()))


func _apply_recommended() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_show("MABA Upscaler", "Open a 3D scene first.")
		return
	var changed := MabaSetup.apply_recommended(root, get_undo_redo())
	_show("MABA Upscaler", "Set tonemap to Linear (exposure 1) on %d WorldEnvironment(s). Undo with Ctrl+Z." % changed if changed > 0
		else "Nothing to change: every WorldEnvironment already uses Linear tonemap at exposure 1 (or the scene has none).")
