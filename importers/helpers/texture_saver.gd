@tool
extends RefCounted

##
## Shared texture-saving for the Krita importers.
##
## Lossless mode keeps the current behavior (PortableCompressedTexture2D).
## VRAM modes compress with Image.compress() and save an ImageTexture so
## the data stays GPU-compressed on disk and in VRAM.
##

const result_codes = preload("../../config/result_codes.gd")
const logger = preload("../../config/logger.gd")

const COMPRESSION_LOSSLESS = 0
const COMPRESSION_S3TC = 1
const COMPRESSION_BPTC = 2
const COMPRESSION_ETC2 = 3
const COMPRESSION_ASTC = 4


static func to_image_mode(mode: int) -> int:
	match mode:
		COMPRESSION_S3TC:
			return Image.COMPRESS_S3TC
		COMPRESSION_BPTC:
			return Image.COMPRESS_BPTC
		COMPRESSION_ETC2:
			return Image.COMPRESS_ETC2
		COMPRESSION_ASTC:
			return Image.COMPRESS_ASTC
		_:
			return -1


static func save_texture(image: Image, save_path: String, save_extension: String, compression: int, mipmaps: bool, source_file: String = "") -> int:
	if mipmaps and not image.has_mipmaps():
		image.generate_mipmaps()

	var image_mode := to_image_mode(compression)
	if image_mode < 0:
		return _save_lossless(image, save_path, save_extension, source_file)

	var err := image.compress(image_mode, Image.COMPRESS_SOURCE_SRGB)
	if err != OK:
		logger.warn("VRAM compression failed, falling back to lossless", source_file)
		return _save_lossless(image, save_path, save_extension, source_file)

	var tex := ImageTexture.create_from_image(image)
	var exit_code = ResourceSaver.save(tex, "%s.%s" % [save_path, save_extension])
	if exit_code != OK:
		logger.error("Could not persist Krita file: %s" % result_codes.get_error_message(exit_code), source_file)
		return FAILED
	return OK


static func _save_lossless(image: Image, save_path: String, save_extension: String, source_file: String = "") -> int:
	var tex := PortableCompressedTexture2D.new()
	tex.create_from_image(image, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)

	var exit_code = ResourceSaver.save(tex, "%s.%s" % [save_path, save_extension])
	if exit_code != OK:
		logger.error("Could not persist Krita file: %s" % result_codes.get_error_message(exit_code), source_file)
		return FAILED
	return OK