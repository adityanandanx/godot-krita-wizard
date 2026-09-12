@tool
extends PanelContainer

## Krita Wizard dock: pick a .kra source, choose layers and output
## options, and generate PNG files. Phase 1 covers static (non-animation)
## exports only.

signal close_requested

const KraParser = preload("../kra/kra_parser.gd")
const KraCompositor = preload("../kra/compositor.gd")
const result_codes = preload("../config/result_codes.gd")
const logger = preload("../config/logger.gd")
const layer_tags = preload("../kra/layer_tags.gd")

var config = preload("../config/config.gd").new()

var _parser = null
var _source_path := ""
var _layer_items := {}  # paint filename -> TreeItem
var _group_items := {}  # group filename -> TreeItem

var _source_edit: LineEdit
var _output_edit: LineEdit
var _prefix_edit: LineEdit
var _pattern_edit: LineEdit
var _visible_check: CheckBox
var _trim_check: CheckBox
var _split_check: CheckBox
var _scale_spin: SpinBox
var _tree: Tree
var _apply_button: Button
var _status_label: Label
var _history_list: ItemList
var _history: Array = []


func _ready() -> void:
	_build_ui()
	_load_history()
	_apply_config_defaults()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 16)
	margin.add_child(main)

	# ---- Left: source, layers, options ----
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 3.0
	main.add_child(left)

	left.add_child(_make_header_row())
	left.add_child(_make_file_row("Krita File Location:", true))
	left.add_child(_make_layers_section())
	left.add_child(_make_options_section())
	left.add_child(_make_output_section())
	left.add_child(_make_buttons_row())
	left.add_child(_make_status_row())

	# ---- Right: history ----
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.5
	main.add_child(right)

	var history_label := Label.new()
	history_label.text = "Import History:"
	right.add_child(history_label)

	_history_list = ItemList.new()
	_history_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history_list.item_activated.connect(_on_history_activated)
	right.add_child(_history_list)


func _make_header_row() -> Control:
	var row := HBoxContainer.new()
	var title := Label.new()
	title.text = "Krita Layers Wizard"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)
	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(func() -> void: close_requested.emit())
	row.add_child(close_button)
	return row


func _make_file_row(label_text: String, is_source: bool) -> Control:
	var box := VBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	box.add_child(label)
	var row := HBoxContainer.new()
	box.add_child(row)

	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.editable = false
	row.add_child(edit)

	var button := Button.new()
	button.text = "Select"
	row.add_child(button)

	if is_source:
		_source_edit = edit
		button.pressed.connect(_on_select_source_pressed)
		edit.text_changed.connect(_on_source_text_changed)
	else:
		_output_edit = edit
		button.pressed.connect(_on_select_output_pressed)

	return box


func _make_layers_section() -> Control:
	var box := VBoxContainer.new()
	var label := Label.new()
	label.text = "Layers (check to export; Merge flattens a group into one file):"
	box.add_child(label)

	_tree = Tree.new()
	_tree.custom_minimum_size = Vector2(0, 220)
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.columns = 4
	_tree.column_titles_visible = true
	_tree.set_column_title(0, "Layer")
	_tree.set_column_title(1, "Info")
	_tree.set_column_title(2, "Merge")
	_tree.set_column_title(3, "Trim")
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, false)
	_tree.set_column_expand(2, false)
	_tree.set_column_expand(3, false)
	_tree.set_column_custom_minimum_width(1, 130)
	_tree.set_column_custom_minimum_width(2, 70)
	_tree.set_column_custom_minimum_width(3, 60)
	_tree.set_column_clip_content(1, true)
	_tree.item_edited.connect(_on_layer_item_edited)
	box.add_child(_tree)
	return box


func _make_options_section() -> Control:
	var box := VBoxContainer.new()

	var pattern_row := HBoxContainer.new()
	var pattern_label := Label.new()
	pattern_label.text = "Exclude pattern:"
	pattern_row.add_child(pattern_label)
	_pattern_edit = LineEdit.new()
	_pattern_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pattern_edit.placeholder_text = "e.g. _* (glob)"
	pattern_row.add_child(_pattern_edit)
	box.add_child(pattern_row)

	_visible_check = CheckBox.new()
	_visible_check.text = "Only include visible layers"
	box.add_child(_visible_check)

	_trim_check = CheckBox.new()
	_trim_check.text = "Trim to content (sets all rows below)"
	_trim_check.tooltip_text = "Toggling this sets the Trim box on every layer and group row. Rows stay individually flippable afterwards."
	_trim_check.button_pressed = false
	_trim_check.toggled.connect(_on_global_trim_toggled)
	box.add_child(_trim_check)

	_split_check = CheckBox.new()
	_split_check.text = "Split layers in multiple files (one PNG per layer)"
	_split_check.button_pressed = true
	box.add_child(_split_check)

	var scale_row := HBoxContainer.new()
	var scale_label := Label.new()
	scale_label.text = "Scale:"
	scale_row.add_child(scale_label)
	_scale_spin = SpinBox.new()
	_scale_spin.min_value = 0.1
	_scale_spin.max_value = 8.0
	_scale_spin.step = 0.1
	_scale_spin.value = 1.0
	scale_row.add_child(_scale_spin)
	box.add_child(scale_row)

	return box


func _make_output_section() -> Control:
	var box := VBoxContainer.new()

	var folder_row := HBoxContainer.new()
	var folder_label := Label.new()
	folder_label.text = "Output Folder:"
	folder_row.add_child(folder_label)
	_output_edit = LineEdit.new()
	_output_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_output_edit.text = "res://"
	folder_row.add_child(_output_edit)
	var folder_button := Button.new()
	folder_button.text = "Select"
	folder_button.pressed.connect(_on_select_output_pressed)
	folder_row.add_child(folder_button)
	box.add_child(folder_row)

	var prefix_row := HBoxContainer.new()
	var prefix_label := Label.new()
	prefix_label.text = "File Name / Prefix:"
	prefix_row.add_child(prefix_label)
	_prefix_edit = LineEdit.new()
	_prefix_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prefix_row.add_child(_prefix_edit)
	box.add_child(prefix_row)

	return box


func _make_buttons_row() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	_apply_button = Button.new()
	_apply_button.text = "Generate PNGs"
	_apply_button.pressed.connect(_on_apply_pressed)
	row.add_child(_apply_button)
	return row


func _make_status_row() -> Control:
	_status_label = Label.new()
	_status_label.text = "Select a .kra file to begin."
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return _status_label


func _apply_config_defaults() -> void:
	_pattern_edit.text = config.get_default_exclusion_pattern()
	_visible_check.button_pressed = config.get_default_only_visible_layers()
	_scale_spin.value = float(config.get_default_scale())


# ---------------------------------------------------------------- source

func _on_select_source_pressed() -> void:
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.kra", "Krita Document")
	dialog.file_selected.connect(_on_source_file_selected.bind(dialog))
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


func _on_source_file_selected(path: String, dialog: EditorFileDialog) -> void:
	dialog.queue_free()
	set_source(path)


func _on_source_text_changed(_new_text: String) -> void:
	pass


func set_source(path: String) -> void:
	_source_path = path
	_source_edit.text = path
	_load_layers()


func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if not data.has("type") or data["type"] != "files":
		return false
	var files: PackedStringArray = data["files"]
	return files.size() > 0 and files[0].get_extension().to_lower() == "kra"


func _drop_data(_pos: Vector2, data: Variant) -> void:
	var files: PackedStringArray = data["files"]
	if files.size() > 0:
		set_source(files[0])


func _load_layers() -> void:
	_tree.clear()
	_layer_items.clear()
	_group_items.clear()

	if _source_path == "":
		return

	_parser = KraParser.new()
	var res: Dictionary = _parser.open(_source_path)
	if not res.is_ok:
		_set_status("Could not open %s: %s" % [_source_path, result_codes.get_error_message(res.code)], true)
		_parser = null
		return

	var root := _tree.create_item()
	_add_layer_items(root, res.content.layers)
	_normalize_tree(root)
	_refresh_tree_states()

	_prefix_edit.text = res.content.name
	_set_status("Loaded %s (%dx%d). Check layers and press Generate PNGs." % [res.content.name, res.content.width, res.content.height], false)


## Unchecked groups force their whole subtree off, so an indeterminate
## state always means "partially selected inside an enabled group".
func _normalize_tree(item: TreeItem) -> void:
	for child in item.get_children():
		var meta: Dictionary = child.get_metadata(0)
		if meta.get("kind") == "group" and not child.is_checked(0):
			_propagate_group_check(child, false)
		_normalize_tree(child)


func _add_layer_items(parent: TreeItem, layers: Array) -> void:
	for layer in layers:
		var item := _tree.create_item(parent)
		# Per-row Trim box, seeded from the @trim tag when present,
		# otherwise from the global Trim option. Afterwards the row
		# is the source of truth for that layer/group.
		var tags: Dictionary = layer_tags.parse_layer_name(str(layer.name))
		var trim_default := _trim_check.button_pressed
		if tags.trim != null:
			trim_default = bool(tags.trim)
		if layer.nodetype == "grouplayer":
			item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			item.set_checked(0, bool(layer.visible))
			item.set_editable(0, true)
			item.set_text(0, str(layer.name))
			item.set_metadata(0, {"kind": "group", "ref": layer})
			item.set_cell_mode(2, TreeItem.CELL_MODE_CHECK)
			# @merge defaults the Merge box on; the checkbox still wins.
			item.set_checked(2, tags.merge == true)
			item.set_editable(2, true)
			item.set_tooltip_text(2, "Export this group as one merged PNG")
			item.set_cell_mode(3, TreeItem.CELL_MODE_CHECK)
			item.set_checked(3, trim_default)
			item.set_editable(3, true)
			item.set_tooltip_text(3, "Trim this group's merged PNG to content")
			_group_items[str(layer.filename)] = item
			_add_layer_items(item, layer.children)
		else:
			item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			item.set_checked(0, bool(layer.visible))
			item.set_editable(0, true)
			item.set_text(0, str(layer.name))
			item.set_metadata(0, {"kind": "layer", "ref": layer})
			item.set_text(1, _layer_info_text(item, layer))
			item.set_cell_mode(3, TreeItem.CELL_MODE_CHECK)
			item.set_checked(3, trim_default)
			item.set_editable(3, true)
			item.set_tooltip_text(3, "Trim this layer's PNG to content")
			_layer_items[str(layer.filename)] = item


## Short summary for the Info column: blend mode (when non-normal)
## and effective opacity (when below 100%, inherited through groups).
func _layer_info_text(item: TreeItem, layer: Dictionary) -> String:
	var parts := PackedStringArray()
	var mode := str(layer.get("blend_mode", "normal"))
	if mode != "" and mode != "normal":
		parts.push_back(mode)
	var eff := int(layer.opacity)
	var parent := item.get_parent()
	while parent != null and parent != _tree.get_root():
		var meta: Dictionary = parent.get_metadata(0)
		var ref = meta.get("ref")
		if ref != null:
			eff = (eff * int(ref.opacity)) / 255
		parent = parent.get_parent()
	if eff < 255:
		parts.push_back("%d%%" % int(eff * 100.0 / 255.0))
	return " · ".join(parts)


var _updating_tree := false


func _on_global_trim_toggled(pressed: bool) -> void:
	# Explicit user action: push the global value into every row.
	# Rows stay individually flippable afterwards.
	if _tree.get_root() == null:
		return
	_updating_tree = true
	_set_trim_recursive(_tree.get_root(), pressed)
	_updating_tree = false


func _set_trim_recursive(item: TreeItem, pressed: bool) -> void:
	for child in item.get_children():
		child.set_checked(3, pressed)
		_set_trim_recursive(child, pressed)


func _on_layer_item_edited() -> void:
	if _updating_tree:
		return
	var item := _tree.get_edited()
	if item == null:
		return
	_updating_tree = true
	if _tree.get_edited_column() == 0:
		var meta: Dictionary = item.get_metadata(0)
		if meta.get("kind") == "group":
			_propagate_group_check(item, item.is_checked(0))
	_refresh_tree_states()
	_updating_tree = false


func _propagate_group_check(item: TreeItem, checked: bool) -> void:
	for child in item.get_children():
		if child.is_editable(0):
			child.set_checked(0, checked)
			child.set_indeterminate(0, false)
		_propagate_group_check(child, checked)


## A group counts as enabled when fully checked OR partially selected
## (Godot check/indeterminate states are mutually exclusive, so partial
## selection is indeterminate-alone).
func _is_item_enabled(item: TreeItem) -> bool:
	return item.is_checked(0) or item.is_indeterminate(0)


## Recomputes tri-state checks bottom-up and dimming top-down, so the
## tree always shows what will actually export: partially selected
## groups read indeterminate, and rows under an unchecked group dim.
func _refresh_tree_states() -> void:
	var root := _tree.get_root()
	if root == null:
		return
	_update_group_state(root)
	_update_dimming(root, false)


## Returns [checked_count, paint_count] for the subtree.
func _update_group_state(item: TreeItem) -> Array:
	var checked := 0
	var total := 0
	for child in item.get_children():
		var meta: Dictionary = child.get_metadata(0)
		if meta.get("kind") == "group":
			var sub := _update_group_state(child)
			checked += sub[0]
			total += sub[1]
		else:
			total += 1
			if child.is_checked(0):
				checked += 1
	if item != _tree.get_root():
		if total > 0 and checked == total:
			item.set_checked(0, true)
		elif checked == 0:
			item.set_checked(0, false)
		else:
			item.set_checked(0, false)
			item.set_indeterminate(0, true)
	return [checked, total]


func _update_dimming(item: TreeItem, dimmed_above: bool) -> void:
	for child in item.get_children():
		var meta: Dictionary = child.get_metadata(0)
		var dimmed := dimmed_above
		if meta.get("kind") == "group" and not _is_item_enabled(child):
			dimmed = true
		if dimmed:
			child.set_custom_color(0, Color(1, 1, 1, 0.35))
		else:
			child.clear_custom_color(0)
		_update_dimming(child, dimmed)


# ---------------------------------------------------------------- apply

func _collect_checked_layers() -> Array:
	var out := []
	_collect_checked(_tree.get_root(), out)
	return out


func _collect_checked(item: TreeItem, out: Array) -> void:
	if item == null:
		return
	# Skip the invisible root.
	if item != _tree.get_root():
		var meta: Dictionary = item.get_metadata(0)
		if meta.get("kind") == "layer" and item.is_checked(0):
			out.push_back(meta["ref"])
	for child in item.get_children():
		_collect_checked(child, out)


## Collects export jobs top-down: {kind: "layer", ref} for checked paint
## layers, {kind: "group", ref, subset} for checked groups with Merge on
## (subset = checked descendant paint layers, document order).
## Anything under an unchecked group is skipped.
func _collect_export_jobs() -> Array:
	var jobs := []
	_collect_jobs(_tree.get_root(), true, jobs)
	return jobs


func _collect_jobs(item: TreeItem, enabled_above: bool, jobs: Array) -> void:
	if item == null:
		return
	for child in item.get_children():
		var meta: Dictionary = child.get_metadata(0)
		var kind := str(meta.get("kind", ""))
		var enabled := enabled_above and _is_item_enabled(child)
		if kind == "group":
			if enabled and child.is_checked(2):
				var subset := []
				_collect_checked_leaves(child, subset)
				jobs.push_back({"kind": "group", "ref": meta["ref"], "subset": subset, "trim": child.is_checked(3)})
			else:
				_collect_jobs(child, enabled, jobs)
		elif kind == "layer" and enabled:
			jobs.push_back({"kind": "layer", "ref": meta["ref"], "trim": child.is_checked(3)})


## Checked paint-leaf refs under item, document order, honoring nested
## group switches (unchecked nested groups contribute nothing).
func _collect_checked_leaves(item: TreeItem, out: Array) -> void:
	for child in item.get_children():
		var meta: Dictionary = child.get_metadata(0)
		if str(meta.get("kind", "")) == "group":
			if _is_item_enabled(child):
				_collect_checked_leaves(child, out)
		elif child.is_checked(0):
			out.push_back(meta["ref"])


func _on_apply_pressed() -> void:
	if _parser == null or _source_path == "":
		_set_status("Select a .kra source file first.", true)
		return

	var jobs := _collect_export_jobs()
	var layers := _collect_checked_layers()
	if jobs.is_empty() and layers.is_empty():
		_set_status("No layers checked for export.", true)
		return

	var output_folder: String = _output_edit.text.strip_edges()
	if output_folder == "":
		_set_status("Choose an output folder.", true)
		return

	var abs_output := ProjectSettings.globalize_path(output_folder)
	if not DirAccess.dir_exists_absolute(abs_output):
		var err := DirAccess.make_dir_recursive_absolute(abs_output)
		if err != OK:
			_set_status("Could not create output folder: %s" % output_folder, true)
			return

	var prefix: String = _prefix_edit.text.strip_edges()
	var options := {
		"only_visible": _visible_check.button_pressed,
		"exception_pattern": _pattern_edit.text.strip_edges(),
		"trim": _trim_check.button_pressed,
		"scale": float(_scale_spin.value),
	}

	_apply_button.disabled = true
	_set_status("Exporting...", false)
	await get_tree().process_frame

	var comp = KraCompositor.new()
	var exported := 0

	if _split_check.button_pressed:
		# Number files sequentially in paint order (bottom first) so
		# they sort correctly in file browsers.
		var ordered := jobs.duplicate()
		ordered.reverse()
		var pad_width := maxi(2, str(ordered.size() - 1).length())
		var seq := 0
		for job in ordered:
			var display_name := ""
			if str(job.kind) == "group":
				var group: Dictionary = job.ref
				var subset: Array = job.subset
				if subset.is_empty():
					logger.warn("Skipping merged group %s: no checked layers inside" % str(group.name), _source_path)
					continue
				if not _export_group_job(comp, group, subset, bool(job.trim), options, prefix, abs_output, pad_width, seq):
					continue
				display_name = str(group.name)
			else:
				var layer: Dictionary = job.ref
				if not _export_layer_job(comp, layer, bool(job.trim), options, prefix, abs_output, pad_width, seq):
					continue
				display_name = str(layer.name)
			seq += 1
			exported += 1
	else:
		# compose() paints bottom-to-top; the tree lists layers top-first.
		var paint_order := layers.duplicate()
		paint_order.reverse()
		var merged: Dictionary = comp.compose(_parser, paint_order, options)
		if merged.is_ok:
			var file_name := "%s.png" % (prefix if prefix != "" else "merged")
			var abs_path := abs_output.path_join(file_name)
			var save_err: int = (merged.content.image as Image).save_png(abs_path)
			if save_err == OK:
				exported += 1
			else:
				logger.error("Could not write %s" % abs_path, _source_path)
		else:
			_set_status("Export failed: %s" % result_codes.get_error_message(merged.code), true)
			_apply_button.disabled = false
			return

	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
	_apply_button.disabled = false

	if exported > 0:
		_set_status("Exported %d PNG file(s) to %s." % [exported, output_folder], false)
		_push_history_entry(output_folder, prefix, layers, options)
	else:
		_set_status("Nothing was exported. Check layer filters.", true)


func _export_layer_job(comp, layer: Dictionary, trim_row: bool, options: Dictionary, prefix: String, abs_output: String, pad_width: int, seq: int) -> bool:
	if not _layer_passes_filters(layer, options):
		return false
	var tags: Dictionary = layer_tags.parse_layer_name(str(layer.name))
	var layer_options := options.duplicate()
	layer_options.trim = trim_row
	if tags.scale != null:
		layer_options.scale = float(tags.scale)
	var single: Dictionary = comp.compose_layer(_parser, layer, layer_options)
	if not single.is_ok:
		logger.warn("Skipping layer %s: %s" % [str(layer.name), result_codes.get_error_message(single.code)], _source_path)
		return false
	var file_name := "%s%s_%s.png" % [prefix + "_" if prefix != "" else "", str(seq).lpad(pad_width, "0"), _sanitize_layer_name(str(tags.clean_name))]
	return _save_png(single.content.image, abs_output.path_join(file_name))


func _export_group_job(comp, group: Dictionary, subset: Array, trim_row: bool, options: Dictionary, prefix: String, abs_output: String, pad_width: int, seq: int) -> bool:
	var tags: Dictionary = layer_tags.parse_layer_name(str(group.name))
	var grouped: Dictionary = comp.compose_group_isolated(_parser, group, subset, options)
	if not grouped.is_ok:
		logger.warn("Skipping group %s: %s" % [str(group.name), result_codes.get_error_message(grouped.code)], _source_path)
		return false
	var image: Image = grouped.content.image
	var used_rect: Rect2i = grouped.content.rect
	var trim_opt := trim_row
	if trim_opt:
		image = image.get_region(used_rect)
	var scale_opt := float(options.get("scale", 1.0))
	if tags.scale != null:
		scale_opt = float(tags.scale)
	if not is_equal_approx(scale_opt, 1.0):
		var new_width := maxi(1, int(image.get_width() * scale_opt + 0.5))
		var new_height := maxi(1, int(image.get_height() * scale_opt + 0.5))
		var interpolation := Image.INTERPOLATE_NEAREST if scale_opt > 1.0 else Image.INTERPOLATE_BILINEAR
		image.resize(new_width, new_height, interpolation)
	var file_name := "%s%s_%s.png" % [prefix + "_" if prefix != "" else "", str(seq).lpad(pad_width, "0"), _sanitize_layer_name(str(tags.clean_name))]
	return _save_png(image, abs_output.path_join(file_name))


func _save_png(image: Image, abs_path: String) -> bool:
	var save_err: int = image.save_png(abs_path)
	if save_err != OK:
		logger.error("Could not write %s" % abs_path, _source_path)
		return false
	return true


func _layer_passes_filters(layer: Dictionary, options: Dictionary) -> bool:
	if layer_tags.parse_layer_name(str(layer.name)).exclude:
		return false
	if bool(options.get("only_visible", false)):
		if not bool(layer.visible):
			return false
		var parent = layer.get("parent_group")
		while parent != null:
			if not bool(parent.visible):
				return false
			parent = parent.get("parent_group")
	var pattern: String = str(options.get("exception_pattern", ""))
	if pattern != "" and str(layer.name).match(pattern):
		return false
	return true


func _sanitize_layer_name(layer_name: String) -> String:
	var out := layer_name.strip_edges().replace("/", "_").replace("\\", "_")
	while out.contains("  "):
		out = out.replace("  ", " ")
	out = out.replace(" ", "_")
	if out == "":
		out = "layer"
	return out


func _set_status(text: String, is_error: bool) -> void:
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", Color(1, 0.45, 0.45) if is_error else Color(0.7, 0.9, 0.7))


# ---------------------------------------------------------------- output

func _on_select_output_pressed() -> void:
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.dir_selected.connect(_on_output_dir_selected.bind(dialog))
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


func _on_output_dir_selected(path: String, dialog: EditorFileDialog) -> void:
	dialog.queue_free()
	_output_edit.text = path


# ---------------------------------------------------------------- history

func _load_history() -> void:
	_history = config.get_import_history()
	_refresh_history_list()


func _refresh_history_list() -> void:
	_history_list.clear()
	for entry in _history:
		var entry_dict: Dictionary = entry
		_history_list.add_item("%s -> %s" % [str(entry_dict.get("source", "?")).get_file(), str(entry_dict.get("output", "?"))])


func _push_history_entry(output_folder: String, prefix: String, layers: Array, options: Dictionary) -> void:
	var names := []
	for layer in layers:
		names.push_back(str(layer.name))
	_history.push_front({
		"source": _source_path,
		"output": output_folder,
		"prefix": prefix,
		"layers": names,
		"merged": _collect_merged_groups(),
		"trims": _collect_trim_states(),
		"options": options,
	})
	var max_entries := config.get_history_max_entries()
	while _history.size() > max_entries:
		_history.pop_back()
	config.save_import_history(_history)
	_refresh_history_list()


## Filenames of groups with Merge checked (for history round-trip).
func _collect_merged_groups() -> Array:
	var out := []
	_collect_merged(_tree.get_root(), out)
	return out


func _collect_merged(item: TreeItem, out: Array) -> void:
	if item == null:
		return
	for child in item.get_children():
		var meta: Dictionary = child.get_metadata(0)
		if str(meta.get("kind", "")) == "group" and child.is_checked(2):
			out.push_back(str(meta["ref"].filename))
		_collect_merged(child, out)


func _apply_merged_state(item: TreeItem, wanted_merged: Array) -> void:
	if item == null:
		return
	for child in item.get_children():
		var meta: Dictionary = child.get_metadata(0)
		if str(meta.get("kind", "")) == "group":
			child.set_checked(2, str(meta["ref"].filename) in wanted_merged)
		_apply_merged_state(child, wanted_merged)


## Trim states keyed by node filename (paint layers and groups).
func _collect_trim_states() -> Dictionary:
	var out := {}
	_collect_trims(_tree.get_root(), out)
	return out


func _collect_trims(item: TreeItem, out: Dictionary) -> void:
	if item == null:
		return
	for child in item.get_children():
		var meta: Dictionary = child.get_metadata(0)
		if meta.has("ref"):
			out[str(meta["ref"].filename)] = child.is_checked(3)
		_collect_trims(child, out)


func _apply_trim_states(item: TreeItem, wanted_trims: Dictionary) -> void:
	if item == null:
		return
	for child in item.get_children():
		var meta: Dictionary = child.get_metadata(0)
		if meta.has("ref"):
			var filename := str(meta["ref"].filename)
			if wanted_trims.has(filename):
				child.set_checked(3, bool(wanted_trims[filename]))
		_apply_trim_states(child, wanted_trims)


func _on_history_activated(index: int) -> void:
	if index < 0 or index >= _history.size():
		return
	var entry: Dictionary = _history[index]
	set_source(str(entry.get("source", "")))
	_output_edit.text = str(entry.get("output", ""))
	_prefix_edit.text = str(entry.get("prefix", ""))
	var options: Dictionary = entry.get("options", {})
	_pattern_edit.text = str(options.get("exception_pattern", ""))
	_visible_check.button_pressed = bool(options.get("only_visible", false))
	_trim_check.button_pressed = bool(options.get("trim", false))
	_scale_spin.value = float(options.get("scale", 1.0))
	var wanted: Array = entry.get("layers", [])
	var wanted_merged: Array = entry.get("merged", [])
	var wanted_trims: Dictionary = entry.get("trims", {})
	_updating_tree = true
	for filename in _layer_items.keys():
		var item: TreeItem = _layer_items[filename]
		var meta: Dictionary = item.get_metadata(0)
		item.set_checked(0, str(meta["ref"].name) in wanted)
	_apply_merged_state(_tree.get_root(), wanted_merged)
	_apply_trim_states(_tree.get_root(), wanted_trims)
	_updating_tree = false
	_normalize_tree(_tree.get_root())
	_refresh_tree_states()