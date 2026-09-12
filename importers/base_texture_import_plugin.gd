@tool
extends EditorImportPlugin

##
## Base importer for merging a Krita document into a single texture.
## Subclasses define the visible name, options and priorities.
##

const result_codes = preload("../config/result_codes.gd")
const logger = preload("../config/logger.gd")
const KraParser = preload("../kra/kra_parser.gd")
const KraCompositor = preload("../kra/compositor.gd")

var config = preload("../config/config.gd").new()

func _get_recognized_extensions():
	return ["kra"]


func _get_save_extension():
	return "res"


func _get_resource_type():
	return "PortableCompressedTexture2D"


func _get_preset_count():
	return 1


func _get_preset_name(i):
	return "Default"


func _get_import_order():
	return 1


func _get_option_visibility(path, option, options):
	return true


func _import(source_file, save_path, options, platform_variants, gen_files):
	var parser = KraParser.new()
	var open_result = parser.open(source_file)

	if not open_result.is_ok:
		parser.close()
		logger.error("Could not open Krita file: %s" % result_codes.get_error_message(open_result.code), source_file)
		return open_result.code if open_result.code != result_codes.SUCCESS else FAILED

	var opts = {
		"only_visible": options.get("layer/only_visible_layers", false),
		"exception_pattern": options.get("layer/exclude_layers_pattern", ""),
		"trim": options.get("sheet/trim", false),
		"scale": float(options.get("sheet/scale", 1.0)),
	}

	var compositor = KraCompositor.new()
	var compose_result = compositor.compose_tree(parser, opts)

	if not compose_result.is_ok:
		parser.close()
		logger.error("Could not compose Krita layers: %s" % result_codes.get_error_message(compose_result.code), source_file)
		return FAILED

	var image: Image = compose_result.content.image

	var tex := PortableCompressedTexture2D.new()
	tex.create_from_image(image, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)

	var exit_code = ResourceSaver.save(tex, "%s.%s" % [save_path, _get_save_extension()])

	parser.close()

	if exit_code != OK:
		logger.error("Could not persist Krita file: %s" % result_codes.get_error_message(exit_code), source_file)
		return FAILED

	return OK