@tool
extends Window

## Krita Wizard configuration dialog. Edits the project settings
## managed by config.gd.

var config = preload("../config/config.gd").new()

var _importer_option: OptionButton
var _pattern_edit: LineEdit
var _visible_check: CheckBox
var _cleanup_check: CheckBox
var _scale_spin: SpinBox
var _compression_option: OptionButton
var _mipmaps_check: CheckBox
var _history_spin: SpinBox


func _ready() -> void:
	title = "Krita Wizard Config"
	_build_ui()
	_load_values()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	box.add_child(_make_labeled_row("Default automatic importer:", _make_importer_option()))
	box.add_child(_make_labeled_row("Default layer exclusion pattern:", _make_pattern_edit()))

	_visible_check = CheckBox.new()
	_visible_check.text = "Only include visible layers by default"
	_visible_check.tooltip_text = "When on, layers hidden in Krita are skipped by default (still overridable per file in the Import dock)."
	box.add_child(_visible_check)

	_cleanup_check = CheckBox.new()
	_cleanup_check.text = "Remove temporary files after import"
	_cleanup_check.tooltip_text = "Delete intermediate files the wizard writes next to the source during import."
	box.add_child(_cleanup_check)

	box.add_child(_make_labeled_row("Default scale:", _make_scale_spin()))
	box.add_child(_make_labeled_row("Default texture compression:", _make_compression_option()))

	_mipmaps_check = CheckBox.new()
	_mipmaps_check.text = "Generate mipmaps by default (VRAM compression)"
	_mipmaps_check.tooltip_text = "Generate mipmaps before compressing. Recommended with VRAM compression to avoid shimmer on minified textures; ignored by the lossless path."
	box.add_child(_mipmaps_check)

	box.add_child(_make_labeled_row("Max wizard history entries:", _make_history_spin()))

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)

	var close_button := Button.new()
	close_button.text = "Close"
	close_button.tooltip_text = "Close without saving."
	close_button.pressed.connect(_on_close_pressed)
	buttons.add_child(close_button)

	var save_button := Button.new()
	save_button.text = "Save"
	save_button.tooltip_text = "Save these defaults to the project settings and close."
	save_button.pressed.connect(_on_save_pressed)
	buttons.add_child(save_button)


func _make_labeled_row(label_text: String, control: Control) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = control.tooltip_text
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row

func _make_importer_option() -> OptionButton:
	_importer_option = OptionButton.new()
	_importer_option.add_item(config.IMPORTER_NOOP_NAME)
	_importer_option.add_item(config.IMPORTER_STATIC_TEXTURE_NAME)
	_importer_option.add_item(config.IMPORTER_STATIC_TEXTURE_SPLIT_NAME)
	_importer_option.add_item(config.IMPORTER_TILESET_TEXTURE_NAME)
	_importer_option.add_item(config.IMPORTER_PARALLAX_LAYERS_NAME)
	_importer_option.tooltip_text = "Importer assigned to newly added .kra files. Per-file choice in the Import dock still wins."
	return _importer_option


func _make_pattern_edit() -> LineEdit:
	_pattern_edit = LineEdit.new()
	_pattern_edit.placeholder_text = "e.g. _* (glob)"
	_pattern_edit.tooltip_text = "Default glob matched against layer names; matching layers are skipped by importers and pre-filled in the wizard."
	return _pattern_edit


func _make_scale_spin() -> SpinBox:
	_scale_spin = SpinBox.new()
	_scale_spin.min_value = 0.1
	_scale_spin.max_value = 8.0
	_scale_spin.step = 0.1
	_scale_spin.tooltip_text = "Default resize factor for imports and the wizard (0.1 – 8.0). Per-layer @scale tags override it."
	return _scale_spin


func _make_history_spin() -> SpinBox:
	_history_spin = SpinBox.new()
	_history_spin.min_value = 1.0
	_history_spin.max_value = 1000.0
	_history_spin.step = 1.0
	_history_spin.tooltip_text = "How many wizard exports are remembered in the Import History list."
	return _history_spin


func _make_compression_option() -> OptionButton:
	_compression_option = OptionButton.new()
	_compression_option.add_item("Lossless", 0)
	_compression_option.add_item("VRAM - S3TC (Desktop)", 1)
	_compression_option.add_item("VRAM - BPTC (Desktop HQ)", 2)
	_compression_option.add_item("VRAM - ETC2 (Mobile)", 3)
	_compression_option.add_item("VRAM - ASTC (Mobile HQ)", 4)
	_compression_option.tooltip_text = "Default texture compression for imports. Lossless is pixel-exact; VRAM modes stay GPU-compressed on disk and in VRAM (smaller, faster, slightly lossy)."
	return _compression_option


func _load_values() -> void:
	_select_importer(config.get_default_importer())
	_pattern_edit.text = config.get_default_exclusion_pattern()
	_visible_check.button_pressed = config.get_default_only_visible_layers()
	_cleanup_check.button_pressed = config.should_remove_temporary_files()
	_scale_spin.value = float(config.get_default_scale())
	_compression_option.select(clampi(config.get_default_compression(), 0, 4))
	_mipmaps_check.button_pressed = config.get_default_mipmaps()
	_history_spin.value = float(config.get_history_max_entries())


func _select_importer(importer_name: String) -> void:
	for i in range(_importer_option.item_count):
		if _importer_option.get_item_text(i) == importer_name:
			_importer_option.select(i)
			return


func _on_save_pressed() -> void:
	config.set_project_setting('krita/import/import_plugin/default_automatic_importer', _importer_option.get_item_text(_importer_option.selected))
	config.set_project_setting('krita/layers/exclusion_pattern', _pattern_edit.text)
	config.set_project_setting('krita/layers/only_include_visible_layers_by_default', _visible_check.button_pressed)
	config.set_project_setting('krita/import/cleanup/remove_temporary_files', _cleanup_check.button_pressed)
	config.set_project_setting('krita/import/scale', float(_scale_spin.value))
	config.set_project_setting('krita/import/compression', int(_compression_option.selected))
	config.set_project_setting('krita/import/mipmaps', _mipmaps_check.button_pressed)
	config.set_project_setting('krita/wizard/history/max_history_entries', int(_history_spin.value))
	hide()


func _on_close_pressed() -> void:
	hide()


func _on_close_requested() -> void:
	hide()