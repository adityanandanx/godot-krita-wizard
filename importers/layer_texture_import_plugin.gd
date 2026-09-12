@tool
extends EditorImportPlugin

##
## Layer texture importer.
## Imports one Krita paint layer (described by a `.kra_layer_tex` sidecar
## written by the Split By Layer importer) as its own texture.
##

const result_codes = preload("../config/result_codes.gd")
const logger = preload("../config/logger.gd")
const KraParser = preload("../kra/kra_parser.gd")
const KraCompositor = preload("../kra/compositor.gd")
const layer_tags = preload("../kra/layer_tags.gd")

var config = preload("../config/config.gd").new()


func _get_importer_name():
	return "krita_wizard.plugin.layer-texture"


func _get_visible_name():
	return "Krita Layer Texture"


func _get_recognized_extensions():
	return ["kra_layer_tex"]


func _get_save_extension():
	return "res"


func _get_resource_type():
	return "PortableCompressedTexture2D"


func _get_preset_count():
	return 1


func _get_preset_name(i):
	return "Default"


func _get_priority():
	return 1.0


func _get_import_order():
	return 1


func _get_import_options(_path, _i):
	return []


func _get_option_visibility(path, option, options):
	return true


func _import(source_file, save_path, options, platform_variants, gen_files):
	var file := FileAccess.open(source_file, FileAccess.READ)
	if file == null:
		logger.error("Could not open layer file", source_file)
		return FAILED

	var sidecar = JSON.parse_string(file.get_as_text())
	if sidecar == null or not sidecar.has("import_options"):
		logger.error("Invalid layer file, missing import options", source_file)
		return FAILED

	var kra_source: String = sidecar.import_options.get("source", "")
	if kra_source == "" or not FileAccess.file_exists(kra_source):
		logger.error("Krita source not found: %s" % kra_source, source_file)
		return FAILED

	var parser = KraParser.new()
	var open_result = parser.open(kra_source)
	if not open_result.is_ok:
		parser.close()
		logger.error("Could not open Krita file: %s" % result_codes.get_error_message(open_result.code), source_file)
		return FAILED

	# Sidecars written before kinds existed are always single layers.
	var kind := str(sidecar.get("kind", "layer"))
	var trim_opt := bool(sidecar.import_options.get("trim", false))
	var scale_opt := float(sidecar.import_options.get("scale", 1.0))

	var compositor = KraCompositor.new()
	var compose_result: Dictionary
	if kind == "group":
		compose_result = _import_group(parser, compositor, sidecar, trim_opt, scale_opt, source_file)
	else:
		compose_result = _import_layer(parser, compositor, sidecar, trim_opt, scale_opt, source_file)
	parser.close()

	if not compose_result.is_ok:
		logger.error("Could not compose layer: %s" % result_codes.get_error_message(compose_result.code), source_file)
		return FAILED

	var image: Image = compose_result.content.image

	var tex := PortableCompressedTexture2D.new()
	tex.create_from_image(image, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)

	var exit_code = ResourceSaver.save(tex, "%s.%s" % [save_path, _get_save_extension()])
	if exit_code != OK:
		logger.error("Could not persist layer texture: %s" % result_codes.get_error_message(exit_code), source_file)
		return FAILED

	return OK


func _import_layer(parser, compositor, sidecar: Dictionary, trim_opt: bool, scale_opt: float, source_file: String) -> Dictionary:
	if not sidecar.has("layer_filename"):
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var layer = _find_layer(parser, str(sidecar.layer_filename), str(sidecar.get("layer_name", "")))
	if layer == null:
		logger.error("Layer not found in Krita file: %s" % str(sidecar.get("layer_name", sidecar.layer_filename)), source_file)
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var tags: Dictionary = layer_tags.parse_layer_name(str(layer.name))
	if tags.trim != null:
		trim_opt = bool(tags.trim)
	if tags.scale != null:
		scale_opt = float(tags.scale)

	return compositor.compose_layer(parser, layer, {
		"trim": trim_opt,
		"scale": scale_opt,
	})


func _import_group(parser, compositor, sidecar: Dictionary, trim_opt: bool, scale_opt: float, source_file: String) -> Dictionary:
	if not sidecar.has("layer_filename"):
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var group = parser.find_node(str(sidecar.layer_filename))
	if group == null or group.nodetype != "grouplayer":
		logger.error("Group not found in Krita file: %s" % str(sidecar.get("layer_name", sidecar.layer_filename)), source_file)
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var tags: Dictionary = layer_tags.parse_layer_name(str(group.name))
	if tags.trim != null:
		trim_opt = bool(tags.trim)
	if tags.scale != null:
		scale_opt = float(tags.scale)

	var grouped: Dictionary = compositor.compose_group_isolated(parser, group, [], {
		"only_visible": bool(sidecar.import_options.get("only_visible", false)),
		"exception_pattern": str(sidecar.import_options.get("exception_pattern", "")),
	})
	if not grouped.is_ok:
		return grouped

	var image: Image = grouped.content.image
	var used_rect: Rect2i = grouped.content.rect
	if trim_opt:
		image = image.get_region(used_rect)

	var width := image.get_width()
	var height := image.get_height()
	if not is_equal_approx(scale_opt, 1.0):
		var new_width := maxi(1, int(width * scale_opt + 0.5))
		var new_height := maxi(1, int(height * scale_opt + 0.5))
		var interpolation := Image.INTERPOLATE_NEAREST if scale_opt > 1.0 else Image.INTERPOLATE_BILINEAR
		image.resize(new_width, new_height, interpolation)

	return result_codes.result({"image": image, "used_rect": used_rect})


## Layers are identified by their stable file id, falling back to the
## display name when the id is missing (e.g. recreated layers).
func _find_layer(parser, layer_filename: String, layer_name: String) -> Variant:
	var by_name = null
	for layer in parser.get_paint_layers():
		if layer.filename == layer_filename:
			return layer
		if layer.name == layer_name:
			by_name = layer
	return by_name