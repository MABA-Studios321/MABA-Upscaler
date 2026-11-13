# MABA Upscaler - editor plugin.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
#
# MabaUpscaler and MabaUpscalerRect declare class_name, so they already appear in the Create
# Node dialog. Registering them again with add_custom_type would list each node twice, so this
# plugin has nothing to register; it exists so the addon can be enabled / disabled as a unit.

@tool
extends EditorPlugin