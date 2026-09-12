@tool
extends "./base_texture_import_plugin.gd"

##
## Tileset texture importer.
## Imports a Krita document as a texture meant to be sliced into tiles.
## The extra "frame_padding" option is accepted for API compatibility with
## the Aseprite wizard, but Krita documents do not carry tilemap metadata,
## so it currently behaves like the static texture importer.
##


func _get_importer_name():
	return "krita_wizard.plugin.tileset-texture"


func _get_visible_name():
	return "Krita Tileset Texture"


func _get_priority():
	return 2.0 if config.get_default_importer() == config.IMPORTER_TILESET_TEXTURE_NAME else 0.9


func _get_import_options(_path, _i):
	return [
		{"name": "layer/exclude_layers_pattern", "default_value": config.get_default_exclusion_pattern()},
		{"name": "layer/only_visible_layers",    "default_value": config.get_default_only_visible_layers()},
		{"name": "sheet/trim", "default_value": false},
		{"name": "sheet/frame_padding", "default_value": 0},
		{"name": "sheet/scale", "default_value": config.get_default_scale()},
	]