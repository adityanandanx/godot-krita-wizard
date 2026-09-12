@tool
extends "./base_texture_import_plugin.gd"


func _get_importer_name():
	return "krita_wizard.plugin.static-texture"


func _get_visible_name():
	return "Krita Texture"


func _get_priority():
	return 2.0 if config.get_default_importer() == config.IMPORTER_STATIC_TEXTURE_NAME else 1.0


func _get_import_options(_path, _i):
	return [
		{"name": "layer/exclude_layers_pattern", "default_value": config.get_default_exclusion_pattern()},
		{"name": "layer/only_visible_layers",    "default_value": config.get_default_only_visible_layers()},
		{"name": "sheet/trim", "default_value": false},
		{"name": "sheet/scale", "default_value": config.get_default_scale()},
		{
			"name": "texture/compression",
			"default_value": config.get_default_compression(),
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": "Lossless,VRAM - S3TC (Desktop),VRAM - BPTC (Desktop HQ),VRAM - ETC2 (Mobile),VRAM - ASTC (Mobile HQ)",
		},
		{"name": "texture/mipmaps", "default_value": config.get_default_mipmaps()},
	]