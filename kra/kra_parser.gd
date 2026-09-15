@tool
extends RefCounted

const result_codes = preload("../config/result_codes.gd")
const logger = preload("../config/logger.gd")
const lzf = preload("./lzf.gd")

const MIME_TYPE_ATTRIBUTE = "mime"
const KRA_MIME = "application/x-kra"
const XML_NS = ""
const NODE_ELEMENT = 1
const NODE_ELEMENT_END = 2
const NODE_TEXT = 3
const NODE_OTHER = 4

var _zip: ZIPReader = ZIPReader.new()
var _xml_parser: XMLParser = XMLParser.new()
var _lzf: RefCounted = lzf.new()

var _width: int = 0
var _height: int = 0
var _colorspace: String = ""
var _depth: String = ""
var _doc_name: String = ""
var _layers: Array = []
var _framerate: int = 0
var _anim_range_from: int = 0
var _anim_range_to: int = 0
var _warned_mask_types := {}


##
## Opens a .kra file and parses maindoc.xml into a layer tree.
##
func open(source_file: String) -> Dictionary:
	close()

	if not FileAccess.file_exists(ProjectSettings.globalize_path(source_file)):
		return result_codes.error(result_codes.ERR_SOURCE_FILE_NOT_FOUND)

	var err := _zip.open(ProjectSettings.globalize_path(source_file))
	if err != OK:
		return result_codes.error(result_codes.ERR_ZIP_READ_FAILED)

	if not _zip.file_exists("maindoc.xml"):
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var xml_buf := _zip.read_file("maindoc.xml")
	if xml_buf == null or xml_buf.is_empty():
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var parse_result := _parse_document(xml_buf)
	if not parse_result.is_ok:
		return parse_result

	return result_codes.result({
		"name": source_file.get_basename().get_file(),
		"width": _width,
		"height": _height,
		"colorspace": _colorspace,
		"depth": _depth,
		"layers": _layers,
	})


func close() -> void:
	if _width > 0 and _height > 0 and is_instance_valid(_zip):
		_zip.close()
	_layers = []
	_width = 0
	_height = 0
	_colorspace = ""
	_depth = ""
	_framerate = 0
	_anim_range_from = 0
	_anim_range_to = 0


func is_open() -> bool:
	return _width > 0 and _height > 0


func get_width() -> int:
	return _width


func get_height() -> int:
	return _height


func get_layers() -> Array:
	return _layers


## Timeline metadata from the maindoc <animation> block.
## framerate is 0 when the document has no animation data.
func get_framerate() -> int:
	return _framerate


func get_anim_range_from() -> int:
	return _anim_range_from


func get_anim_range_to() -> int:
	return _anim_range_to


func has_animation_block() -> bool:
	return _framerate > 0


## In-zip path of a layer's keyframes file, or "" when the layer
## is static. `keyframes_attr` is the layer's "keyframes" attribute.
func get_keyframes_store_path(keyframes_attr: String) -> String:
	if keyframes_attr == "":
		return ""
	return "%s/layers/%s" % [_doc_name, keyframes_attr]


## Raw bytes of any file inside the .kra archive, or an empty
## array when the file is missing/unreadable. Used for auxiliary
## files (keyframes) that are not tile data.
func read_store_bytes(zip_path: String) -> PackedByteArray:
	if not is_open() or zip_path == "":
		return PackedByteArray()
	if not _zip.file_exists(zip_path):
		return PackedByteArray()
	var buf := _zip.read_file(zip_path)
	return buf if buf != null else PackedByteArray()


## Finds any node (paint layer or group) by its stable file id.
## Returns the node Dictionary or null.
func find_node(node_filename: String) -> Variant:
	return _find_node_recursive(_layers, node_filename)


func _find_node_recursive(nodes: Array, node_filename: String) -> Variant:
	for node in nodes:
		if node.filename == node_filename:
			return node
		if node.nodetype == "grouplayer":
			var found: Variant = _find_node_recursive(node.children, node_filename)
			if found != null:
				return found
	return null


##
## Returns all paint layers (skipping group layers) in paint order
## (bottom to top). Group layers are flattened: entries remember their
## parent group so visibility/opacity can be inherited.
##
func get_paint_layers() -> Array:
	var result := []
	_collect_paint_layers(_layers, null, result)
	# Krita lists layers top-to-bottom; paint order is bottom-to-top.
	result.reverse()
	return result


func _collect_paint_layers(layers: Array, parent_group: Variant, out: Array) -> void:
	for layer in layers:
		if layer.nodetype == "grouplayer":
			_collect_paint_layers(layer.children, layer, out)
		elif layer.nodetype == "paintlayer":
			var copy: Dictionary = layer.duplicate()
			copy.parent_group = parent_group
			out.push_back(copy)


##
## Parses maindoc.xml using the pull-style XMLParser. Krita documents
## nest <layers><layer nodetype="paintlayer|grouplayer" ...></layer></layers>.
##
func _parse_document(buffer: PackedByteArray) -> Dictionary:
	var err := _xml_parser.open_buffer(buffer)
	if err != OK:
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var in_image := false
	var in_animation := false
	var stack: Array = []
	var current_group = null

	while true:
		var read_result := _xml_parser.read()
		if read_result != OK:
			break

		var node_type := _xml_parser.get_node_type()

		match node_type:
			NODE_ELEMENT:
				var node_name: String = _xml_parser.get_node_name()
				match node_name:
					"IMAGE":
						in_image = true
						_width = int(_xml_parser.get_named_attribute_value("width"))
						_height = int(_xml_parser.get_named_attribute_value("height"))
						_colorspace = _xml_parser.get_named_attribute_value("colorspacename")
						_doc_name = _xml_parser.get_named_attribute_value("name")
					"layer":
						if not in_image:
							break
						var layer: Variant = _parse_layer_element()
						if layer != null:
							if current_group != null:
								current_group.children.push_back(layer)
							else:
								_layers.push_back(layer)
							stack.push_back(layer)
							current_group = layer if layer.nodetype == "grouplayer" else current_group
					"mask":
						if not in_image or stack.is_empty():
							break
						var mask: Variant = _parse_mask_element()
						if mask != null:
							(stack[stack.size() - 1] as Dictionary).masks.push_back(mask)
						else:
							var mask_type: String = _xml_parser.get_named_attribute_value("nodetype")
							if not _warned_mask_types.has(mask_type):
								_warned_mask_types[mask_type] = true
								logger.warn("Unsupported mask type '%s' will be ignored (only transparency/selection masks are applied)" % mask_type)
					"animation":
						if in_image:
							in_animation = true
					"framerate":
						if in_image and in_animation:
							var fps_attr: String = _xml_parser.get_named_attribute_value("value")
							if fps_attr != "":
								_framerate = int(fps_attr)
					"range":
						if in_image and in_animation:
							var from_attr: String = _xml_parser.get_named_attribute_value("from")
							var to_attr: String = _xml_parser.get_named_attribute_value("to")
							if from_attr != "":
								_anim_range_from = int(from_attr)
							if to_attr != "":
								_anim_range_to = int(to_attr)
			NODE_ELEMENT_END:
				var end_name: String = _xml_parser.get_node_name()
				match end_name:
					"animation":
						in_animation = false
					"layer":
						if not stack.is_empty():
							stack.pop_back()
							if stack.is_empty():
								current_group = null
							elif stack[stack.size() - 1].nodetype == "grouplayer":
								current_group = stack[stack.size() - 1]
							else:
								current_group = null
					"IMAGE":
						in_image = false
			NODE_TEXT:
				pass
			NODE_OTHER:
				pass
			_:
				# NODE_NONE: stop when the buffer is exhausted
				if node_type == 0:
					break

	if _width <= 0 or _height <= 0:
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	return result_codes.result(true)


func _parse_layer_element() -> Variant:
	const PAINT_NODE = "paintlayer"
	const GROUP_NODE = "grouplayer"

	var nodetype: String = _xml_parser.get_named_attribute_value("nodetype")
	if nodetype != PAINT_NODE and nodetype != GROUP_NODE:
		return null

	var opacity_attr: String = _xml_parser.get_named_attribute_value("opacity")
	var compositeop: String = _xml_parser.get_named_attribute_value("compositeop")

	return {
		"name": _xml_parser.get_named_attribute_value("name"),
		"filename": _xml_parser.get_named_attribute_value("filename"),
		"nodetype": nodetype,
		"visible": _xml_parser.get_named_attribute_value("visible") != "0",
		"opacity": int(opacity_attr) if opacity_attr != "" else 255,
		"blend_mode": compositeop if compositeop != "" else "normal",
		"x": int(_xml_parser.get_named_attribute_value("x")),
		"y": int(_xml_parser.get_named_attribute_value("y")),
		"keyframes": _xml_parser.get_named_attribute_value("keyframes") if _xml_parser.has_attribute("keyframes") else "",
		"children": [],
		"masks": [],
		"parent_group": null,
	}


##
## Parses a <mask> element nested inside a layer's <masks> block.
## Returns null for unsupported mask types (filter/transform/colorize),
## which are reported once per file by the caller via _warned_masks.
##
## Only transparency-style masks (transparencymask, selectionmask) carry
## directly usable alpha data. Their pixels live in a GrayA8 tile file at
## <doc>/layers/<filename>.pixelselection; the gray channel holds the
## mask value (white reveals, black conceals).
##
func _parse_mask_element() -> Variant:
	const SUPPORTED_MASK_NODES := ["transparencymask", "selectionmask"]

	var nodetype: String = _xml_parser.get_named_attribute_value("nodetype")
	if not SUPPORTED_MASK_NODES.has(nodetype):
		return null

	return {
		"name": _xml_parser.get_named_attribute_value("name"),
		"filename": _xml_parser.get_named_attribute_value("filename"),
		"nodetype": nodetype,
		"visible": _xml_parser.get_named_attribute_value("visible") != "0",
		"x": int(_xml_parser.get_named_attribute_value("x")),
		"y": int(_xml_parser.get_named_attribute_value("y")),
	}


##
## Decodes a single paint layer into a full-size interleaved RGBA buffer.
## Missing tiles use the layer's default pixel (usually transparent).
##
func decode_layer(layer: Dictionary) -> Dictionary:
	if layer.filename == null:
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var tile_path: String = _layer_file_path(layer.filename)
	if not _zip.file_exists(tile_path):
		logger.error("Layer data file missing: %s" % tile_path)
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var layer_buf := _zip.read_file(tile_path)
	if layer_buf == null or layer_buf.is_empty():
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var parse_result: Dictionary = _lzf.read_layer_tiles(layer_buf)
	if not parse_result.is_ok:
		return parse_result

	var tiles: Array = parse_result.content.tiles
	var canvas_size := _width * _height * 4
	var canvas: PackedByteArray = PackedByteArray()
	canvas.resize(canvas_size)

	var default_pixel: Variant = _read_default_pixel(layer)
	if default_pixel != null:
		# Default pixels are stored in native B,G,R,A order like tiles.
		var dr: int = default_pixel[0]
		var dg: int = default_pixel[1]
		var db: int = default_pixel[2]
		var da: int = default_pixel[3]
		for i in range(canvas_size / 4):
			var offset := i * 4
			canvas[offset] = db
			canvas[offset + 1] = dg
			canvas[offset + 2] = dr
			canvas[offset + 3] = da
	else:
		canvas.fill(0)

	for tile in tiles:
		_blit_tile(canvas, tile.x, tile.y, tile.data)

	return result_codes.result(canvas)


func _blit_tile(canvas: PackedByteArray, tile_x: int, tile_y: int, tile_data: PackedByteArray) -> void:
	var row_bytes := _width * 4
	for row in range(lzf.TILE_HEIGHT):
		var canvas_row := tile_y + row
		if canvas_row < 0 or canvas_row >= _height:
			continue
		var col_start := tile_x
		if col_start < 0:
			col_start = 0
		var tile_col := col_start - tile_x
		while col_start < _width and tile_col < lzf.TILE_WIDTH:
			var dst_offset: int = canvas_row * row_bytes + col_start * 4
			var src_offset: int = (row * lzf.TILE_WIDTH + tile_col) * 4
			canvas[dst_offset] = tile_data[src_offset]
			canvas[dst_offset + 1] = tile_data[src_offset + 1]
			canvas[dst_offset + 2] = tile_data[src_offset + 2]
			canvas[dst_offset + 3] = tile_data[src_offset + 3]
			col_start += 1
			tile_col += 1


func _read_default_pixel(layer: Dictionary) -> Variant:
	if layer.filename == null:
		return null
	var default_path: String = "%s.defaultpixel" % _layer_file_path(layer.filename)
	if not _zip.file_exists(default_path):
		return null
	var buf := _zip.read_file(default_path)
	if buf == null or buf.size() < 4:
		return null
	return buf


func _layer_file_path(filename: String) -> String:
	return "%s/layers/%s" % [_doc_name, filename]


##
## Reads and decodes the raw tile records of a paint layer.
## Returns { tiles: [{x, y, data}] } with interleaved RGBA data.
##
func get_layer_tile_data(layer: Dictionary) -> Dictionary:
	if layer.filename == null:
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var tile_path: String = _layer_file_path(layer.filename)
	if not _zip.file_exists(tile_path):
		logger.error("Layer data file missing: %s" % tile_path)
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var layer_buf := _zip.read_file(tile_path)
	if layer_buf == null or layer_buf.is_empty():
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	return _lzf.read_layer_tiles(layer_buf)


##
## Scans a paint layer's tile headers without decoding payloads.
## Returns { tiles: [{x, y, payload}] }. Payloads can be decoded with
## Lzf.decode_tile_payload, including on worker threads.
##
func get_layer_tile_headers(layer: Dictionary) -> Dictionary:
	if layer.filename == null:
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var tile_path: String = _layer_file_path(layer.filename)
	if not _zip.file_exists(tile_path):
		logger.error("Layer data file missing: %s" % tile_path)
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var layer_buf := _zip.read_file(tile_path)
	if layer_buf == null or layer_buf.is_empty():
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	return _lzf.parse_tile_headers(layer_buf)


##
## Returns the layer's default pixel (used where no tile is stored),
## or null when the layer has none / it could not be read.
##
func get_layer_default_pixel(layer: Dictionary) -> Variant:
	return _read_default_pixel(layer)


##
## MD5 hex of a layer's raw tile-file bytes. Used for change detection:
## identical bytes mean identical pixels, so the texture needs no
## reimport. Returns "" when the data cannot be read (treated as changed).
##
func get_layer_tile_hash(layer: Dictionary) -> String:
	var data := get_layer_tile_bytes(layer)
	if data == null:
		return ""
	return _md5_hex(data)


func get_layer_tile_bytes(layer: Dictionary) -> Variant:
	if layer.filename == null:
		return null
	var tile_path: String = _layer_file_path(layer.filename)
	if not _zip.file_exists(tile_path):
		return null
	var buf := _zip.read_file(tile_path)
	if buf == null or buf.is_empty():
		return null
	return buf


##
## Combined tile hash for any node: paint layers hash their own file,
## groups hash their paint descendants in stored order. Returns "" when
## anything cannot be read (treated as changed).
##
func get_node_tile_hash(node: Dictionary) -> String:
	if node.nodetype == "paintlayer":
		return get_layer_tile_hash(node)
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_MD5) != OK:
		return ""
	var paint := []
	_collect_hash_paint(node.children, paint)
	for layer in paint:
		var data := get_layer_tile_bytes(layer)
		if data == null:
			return ""
		if ctx.update(data) != OK:
			return ""
	return _md5_hex(ctx.finish())


func _collect_hash_paint(nodes: Array, out: Array) -> void:
	for child in nodes:
		if child.nodetype == "paintlayer":
			out.push_back(child)
		elif child.nodetype == "grouplayer":
			_collect_hash_paint(child.children, out)


func _md5_hex(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_MD5) != OK:
		return ""
	if ctx.update(data) != OK:
		return ""
	return ctx.finish().hex_encode()


##
## Reads a transparency/selection mask's tile headers without decoding.
## Mask pixels live in a GrayA8 tile file at
## <doc>/layers/<filename>.pixelselection (PIXELSIZE 2).
## Returns { tiles: [{x, y, payload}] }.
##
func get_mask_tile_headers(mask: Dictionary) -> Dictionary:
	if mask.filename == null:
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var mask_path: String = "%s/layers/%s.pixelselection" % [_doc_name, mask.filename]
	if not _zip.file_exists(mask_path):
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var mask_buf := _zip.read_file(mask_path)
	if mask_buf == null or mask_buf.is_empty():
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	return _lzf.parse_tile_headers(mask_buf)