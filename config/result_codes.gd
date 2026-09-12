@tool
extends RefCounted

const SUCCESS = 0
const ERR_SOURCE_FILE_NOT_FOUND = 992
const ERR_OUTPUT_FOLDER_NOT_FOUND = 993
const ERR_INVALID_KRA_FILE = 994
const ERR_UNSUPPORTED_COLORSPACE = 995
const ERR_NO_VALID_LAYERS_FOUND = 996
const ERR_ZIP_READ_FAILED = 997


static func get_error_message(code: int) -> String:
	match code:
		ERR_SOURCE_FILE_NOT_FOUND:
			return "source file does not exist"
		ERR_OUTPUT_FOLDER_NOT_FOUND:
			return "output location does not exist"
		ERR_INVALID_KRA_FILE:
			return "file is not a valid Krita (.kra) document"
		ERR_UNSUPPORTED_COLORSPACE:
			return "unsupported color space. Only 8 bit RGBA (GRAY/RGBA/CMYKA with depth U8) documents are supported."
		ERR_NO_VALID_LAYERS_FOUND:
			return "no valid layers found"
		ERR_ZIP_READ_FAILED:
			return "could not read the .kra archive"
		_:
			return "import failed: %d" % error_string(code)


static func error(error_code: int) -> Dictionary:
	return { "code": error_code, "content": null, "is_ok": false }


static func result(data: Variant) -> Dictionary:
	return { "code": SUCCESS, "content": data, "is_ok": true }