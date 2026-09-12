@tool
extends EditorImportPlugin

##
## Parallax layers importer.
## Imports a Krita document as a Node2D scene: one Parallax2D +
## Sprite2D per paint layer, with scroll_scale taken from @speed /
## @speedx / @speedy layer tags (default 1, 1).
##
## Layer PNGs are written next to the source (or the configured folder),
## imported through Godot's own texture pipeline, and referenced by the
## generated scene. Stale PNGs from removed/renamed layers are cleaned up.
##

const result_codes = preload("../config/result_codes.gd")
const logger = preload("../config/logger.gd")
const KraParser = preload("../kra/kra_parser.gd")
const KraCompositor = preload("../kra/compositor.gd")
const layer_tags = preload("../kra/layer_tags.gd")

var config = preload("../config/config.gd").new()


func _get_importer_name():
	return "krita_wizard.plugin.parallax-layers"


func _get_visible_name():
	return "Krita Parallax Layers"


func _get_recognized_extensions():
	return ["kra"]


func _get_save_extension():
	return "scn"


func _get_resource_type():
	return "PackedScene"


func _get_preset_count():
	return 1


func _get_preset_name(i):
	return "Default"


func _get_priority():
	return 2.0 if config.get_default_importer() == config.IMPORTER_PARALLAX_LAYERS_NAME else 1.0


func _get_import_order():
	return 1


func _get_import_options(_path, _i):
	return [
		{"name": "layer/exclude_layers_pattern", "default_value": config.get_default_exclusion_pattern()},
		{"name": "layer/only_visible_layers",    "default_value": config.get_default_only_visible_layers()},
		{"name": "sheet/trim", "default_value": true},
		{"name": "sheet/scale", "default_value": config.get_default_scale()},
		{
			"name": "output/layers_resources_folder",
			"default_value": "",
			"property_hint": PROPERTY_HINT_DIR,
		},
	]


func _get_option_visibility(path, option, options):
	return true


func _import(source_file, save_path, options, platform_variants, gen_files):
	var parser = KraParser.new()
	var open_result = parser.open(source_file)
	if not open_result.is_ok:
		parser.close()
		logger.error("Could not open Krita file: %s" % result_codes.get_error_message(open_result.code), source_file)
		return FAILED

	var exception_pattern: String = options.get("layer/exclude_layers_pattern", "")
	var only_visible: bool = options.get("layer/only_visible_layers", false)
	var trim := bool(options.get("sheet/trim", true))
	var scale := maxf(0.01, float(options.get("sheet/scale", 1.0)))

	var output_folder: String = options.get("output/layers_resources_folder", "")
	if output_folder != "" and output_folder.is_relative_path():
		output_folder = source_file.get_base_dir().path_join(output_folder).simplify_path()
	if output_folder == "":
		output_folder = source_file.get_base_dir()
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(output_folder)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_folder))

	var doc_stem: String = source_file.get_file().get_basename()
	var width: int = parser.get_width()
	var height: int = parser.get_height()

	var compositor = KraCompositor.new()
	var used_names := {}
	var current_pngs := []
	var layer_nodes := []  # [{name, texture, position}] bottom-to-top

	for layer in parser.get_paint_layers():
		if not _should_include(layer, only_visible, exception_pattern):
			continue
		var tags: Dictionary = layer_tags.parse_layer_name(str(layer.name))
		var stem := _unique_stem(str(tags.clean_name), used_names)
		var png_path := "%s/%s_%s.png" % [output_folder, doc_stem, stem]

		var compose_result = compositor.compose_layer(parser, layer, {"trim": trim, "scale": scale})
		if not compose_result.is_ok:
			logger.warn("Skipping layer %s: %s" % [str(layer.name), result_codes.get_error_message(compose_result.code)], source_file)
			continue
		var image: Image = compose_result.content.image
		var used_rect: Rect2i = compose_result.content.used_rect

		if not _write_png_if_changed(image, png_path, source_file):
			parser.close()
			return FAILED
		current_pngs.push_back(png_path)

		# The filesystem cache doesn't know about the just-written file
		# yet; refresh it so the external import below can find it.
		EditorInterface.get_resource_filesystem().update_file(png_path)
		if append_import_external_resource(png_path) != OK:
			parser.close()
			logger.error("Could not import generated PNG: %s" % png_path, source_file)
			return FAILED
		gen_files.push_back(png_path)

		var texture: Texture2D = ResourceLoader.load(png_path)
		if texture == null:
			parser.close()
			logger.error("Could not load generated PNG: %s" % png_path, source_file)
			return FAILED

		var center := Vector2(width, height) * 0.5 * scale
		if trim:
			center = (Vector2(used_rect.position) + Vector2(used_rect.size) * 0.5) * scale
		layer_nodes.push_back({
			"name": _unique_node_name(stem, layer_nodes),
			"texture": texture,
			"position": center,
			"scroll": Vector2(float(tags.speed_x), float(tags.speed_y)),
		})

	parser.close()

	_cleanup_stale_pngs(output_folder, doc_stem, current_pngs, source_file)

	var packed := _build_parallax_scene(doc_stem, layer_nodes)
	if packed == null:
		logger.error("Could not build parallax scene (no layers exported)", source_file)
		return FAILED

	var exit_code = ResourceSaver.save(packed, "%s.%s" % [save_path, _get_save_extension()])
	if exit_code != OK:
		logger.error("Could not persist parallax scene: %s" % result_codes.get_error_message(exit_code), source_file)
		return FAILED

	return OK


## Builds the parallax scene: a Node2D root with one Parallax2D
## child per layer. Layers arrive bottom-to-top; child order matches
## so same-speed overlaps stack like in Krita.
func _build_parallax_scene(doc_stem: String, layer_nodes: Array) -> PackedScene:
	if layer_nodes.is_empty():
		return null

	var root := Node2D.new()
	root.name = doc_stem.validate_node_name()

	for entry in layer_nodes:
		var pl := Parallax2D.new()
		pl.name = str(entry.name)
		pl.scroll_scale = entry.scroll
		root.add_child(pl)
		pl.owner = root

		var sprite := Sprite2D.new()
		sprite.name = "Sprite2D"
		sprite.texture = entry.texture
		sprite.position = entry.position
		pl.add_child(sprite)
		sprite.owner = root

	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		return null
	return packed


## Writes the PNG only when bytes differ, so untouched layers don't
## trigger texture reimports downstream.
func _write_png_if_changed(image: Image, png_path: String, source_file: String) -> bool:
	var buffer := image.save_png_to_buffer()
	if buffer.is_empty():
		logger.error("Could not encode PNG: %s" % png_path, source_file)
		return false
	if FileAccess.file_exists(png_path):
		var existing := FileAccess.open(png_path, FileAccess.READ)
		if existing != null:
			var same := existing.get_buffer(existing.get_length()) == buffer
			existing.close()
			if same:
				return true
	var out := FileAccess.open(png_path, FileAccess.WRITE)
	if out == null:
		logger.error("Could not write PNG: %s" % png_path, source_file)
		return false
	out.store_buffer(buffer)
	out.close()
	return true


## Removes <doc>_<stem>.png files (+ their .import) that this import no
## longer generates (deleted/renamed layers). Scoped to our own prefix.
func _cleanup_stale_pngs(output_folder: String, doc_stem: String, current_pngs: Array, source_file: String) -> void:
	var keep := {}
	for path in current_pngs:
		keep[path] = true
	var dir := DirAccess.open(output_folder)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.begins_with(doc_stem + "_") and file_name.ends_with(".png"):
			var full: String = output_folder.path_join(file_name)
			if not keep.has(full):
				for candidate in [full, full + ".import"]:
					if FileAccess.file_exists(candidate):
						if DirAccess.remove_absolute(ProjectSettings.globalize_path(candidate)) != OK:
							logger.warn("Could not remove stale file: %s" % candidate, source_file)
		file_name = dir.get_next()
	dir.list_dir_end()


func _should_include(layer: Dictionary, only_visible: bool, exception_pattern: String) -> bool:
	if layer_tags.parse_layer_name(str(layer.name)).exclude:
		return false
	if only_visible:
		if not layer.visible:
			return false
		var parent = layer.get("parent_group")
		while parent != null:
			if not parent.visible:
				return false
			parent = parent.get("parent_group")
	if exception_pattern != "":
		if layer.name != null and str(layer.name).match(exception_pattern):
			return false
	return true


func _unique_stem(clean_name: String, used_names: Dictionary) -> String:
	var flat_name := _sanitize_layer_name(clean_name)
	if used_names.has(flat_name):
		used_names[flat_name] += 1
		return "%s_%d" % [flat_name, used_names[flat_name]]
	used_names[flat_name] = 0
	return flat_name


func _unique_node_name(stem: String, layer_nodes: Array) -> String:
	var candidate := stem.validate_node_name()
	if candidate == "":
		candidate = "Layer"
	var taken := {}
	for entry in layer_nodes:
		taken[str(entry.name)] = true
	if not taken.has(candidate):
		return candidate
	var counter := 1
	while taken.has("%s_%d" % [candidate, counter]):
		counter += 1
	return "%s_%d" % [candidate, counter]


func _sanitize_layer_name(layer_name: String) -> String:
	var out := layer_name.strip_edges().replace("/", "_").replace("\\", "_")
	while out.contains("  "):
		out = out.replace("  ", " ")
	out = out.replace(" ", "_")
	if out == "":
		out = "layer"
	return out
