@tool
extends RefCounted

const _CONFIG_SECTION_KEY = 'krita'
const _DEFAULT_EXCLUSION_PATTERN_KEY = 'krita/layers/exclusion_pattern'
const _DEFAULT_ONLY_VISIBLE_LAYERS = 'krita/layers/only_include_visible_layers_by_default'
const _REMOVE_SOURCE_FILES_KEY = 'krita/import/cleanup/remove_temporary_files'
const _IMPORTER_ENABLE_KEY = 'krita/import/import_plugin/enable_automatic_importer'
const _DEFAULT_IMPORTER_KEY = 'krita/import/import_plugin/default_automatic_importer'
const _DEFAULT_SCALE = 'krita/import/scale'
const _DEFAULT_COMPRESSION = 'krita/import/compression'
const _DEFAULT_MIPMAPS = 'krita/import/mipmaps'
const _WIZARD_HISTORY = "wizard_history"
const _HISTORY_MAX_ENTRIES = 'krita/wizard/history/max_history_entries'
const _HISTORY_DEFAULT_MAX_ENTRIES = 100

const IMPORTER_NOOP_NAME = "No Import"
const IMPORTER_STATIC_TEXTURE_NAME = "Static Texture"
const IMPORTER_STATIC_TEXTURE_SPLIT_NAME = "Static Texture (Split By Layer)"
const IMPORTER_TILESET_TEXTURE_NAME = "Tileset Texture"
const IMPORTER_PARALLAX_LAYERS_NAME = "Parallax Layers"
const IMPORTER_ANIMATION_NAME = "Animation"

var _editor_settings: EditorSettings = null


## EditorSettings is only available inside the editor. Outside of it
## (e.g. headless test scripts) metadata calls degrade to defaults.
func _ed_settings() -> EditorSettings:
	if _editor_settings == null and Engine.is_editor_hint():
		_editor_settings = EditorInterface.get_editor_settings()
	return _editor_settings


## Get plugin metadata (persisted per-project)
func get_project_setting(key: String, default_value: Variant = null) -> Variant:
	if not ProjectSettings.has_setting(key):
		return default_value
	var value = ProjectSettings.get(key)
	return value if value != null else default_value


func set_project_setting(key: String, value: Variant) -> void:
	ProjectSettings.set(key, value)
	ProjectSettings.save()


func get_default_exclusion_pattern() -> String:
	return get_project_setting(_DEFAULT_EXCLUSION_PATTERN_KEY, "")


func get_default_only_visible_layers() -> bool:
	return get_project_setting(_DEFAULT_ONLY_VISIBLE_LAYERS, false)


func get_default_scale() -> float:
	return float(get_project_setting(_DEFAULT_SCALE, 1.0))


func get_default_compression() -> int:
	return int(get_project_setting(_DEFAULT_COMPRESSION, 0))


func get_default_mipmaps() -> bool:
	return bool(get_project_setting(_DEFAULT_MIPMAPS, false))


func is_importer_enabled() -> bool:
	return get_project_setting(_IMPORTER_ENABLE_KEY, false)


func get_default_importer() -> String:
	return get_project_setting(
		_DEFAULT_IMPORTER_KEY,
		IMPORTER_STATIC_TEXTURE_NAME if is_importer_enabled() else IMPORTER_NOOP_NAME
	)


func should_remove_temporary_files() -> bool:
	return get_project_setting(_REMOVE_SOURCE_FILES_KEY, true)


func get_plugin_metadata(key: String, default_value: Variant = null) -> Variant:
	var settings := _ed_settings()
	if settings == null:
		return default_value
	return settings.get_project_metadata(_CONFIG_SECTION_KEY, key, default_value)


func set_plugin_metadata(key: String, data: Variant) -> void:
	var settings := _ed_settings()
	if settings == null:
		return
	settings.set_project_metadata(_CONFIG_SECTION_KEY, key, data)


func get_history_max_entries() -> int:
	return get_project_setting(_HISTORY_MAX_ENTRIES, _HISTORY_DEFAULT_MAX_ENTRIES)


func get_import_history() -> Array:
	return get_plugin_metadata(_WIZARD_HISTORY, [])


func save_import_history(history: Array) -> void:
	set_plugin_metadata(_WIZARD_HISTORY, history)


func initialize_project_settings() -> void:
	_initialize_project_cfg(_DEFAULT_EXCLUSION_PATTERN_KEY, "", TYPE_STRING)
	_initialize_project_cfg(_DEFAULT_ONLY_VISIBLE_LAYERS, false, TYPE_BOOL)
	_initialize_project_cfg(_DEFAULT_SCALE, 1.0, TYPE_FLOAT)
	_initialize_project_cfg(_DEFAULT_COMPRESSION, 0, TYPE_INT, PROPERTY_HINT_ENUM, "Lossless,VRAM - S3TC (Desktop),VRAM - BPTC (Desktop HQ),VRAM - ETC2 (Mobile),VRAM - ASTC (Mobile HQ)")
	_initialize_project_cfg(_DEFAULT_MIPMAPS, false, TYPE_BOOL)
	_initialize_project_cfg(_REMOVE_SOURCE_FILES_KEY, true, TYPE_BOOL)
	_initialize_project_cfg(
		_DEFAULT_IMPORTER_KEY,
		IMPORTER_STATIC_TEXTURE_NAME if is_importer_enabled() else IMPORTER_NOOP_NAME,
		TYPE_STRING,
		PROPERTY_HINT_ENUM,
		",".join([
			IMPORTER_NOOP_NAME,
			IMPORTER_STATIC_TEXTURE_NAME,
			IMPORTER_STATIC_TEXTURE_SPLIT_NAME,
			IMPORTER_TILESET_TEXTURE_NAME,
			IMPORTER_PARALLAX_LAYERS_NAME,
			IMPORTER_ANIMATION_NAME
		])
	)
	_initialize_project_cfg(_HISTORY_MAX_ENTRIES, _HISTORY_DEFAULT_MAX_ENTRIES, TYPE_INT)
	ProjectSettings.save()


func _initialize_project_cfg(key: String, default_value: Variant, type: int, hint: int = PROPERTY_HINT_NONE, hint_string: Variant = null) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.add_property_info({
		"name": key,
		"type": type,
		"hint": hint,
		"hint_string": hint_string,
	})