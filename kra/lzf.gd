@tool
extends RefCounted

const result_codes = preload("../config/result_codes.gd")

const COMPRESSED_DATA_FLAG = 1
const RAW_DATA_FLAG = 0

const TILE_WIDTH = 64
const TILE_HEIGHT = 64

## Pixel size expected for each tile once decompressed.
## Only 8-bit RGBA (4 channels) is supported in this phase.
const PIXEL_SIZE = 4

const TILE_DATA_SIZE = TILE_WIDTH * TILE_HEIGHT * PIXEL_SIZE

## Krita stores 8-bit RGB pixels B,G,R,A in memory (see KoRgbU8ColorSpace:
## Blue is byte 0, Red is byte 2), so the linearized channel planes come
## out as [B... G... R... A...]. Delinearizing maps them back to RGBA.
## GrayA masks are [gray, alpha] and need no reordering.
const RGBA_CHANNEL_ORDER := [2, 1, 0, 3]
const GRAYA_CHANNEL_ORDER := [0, 1]

const _NEW_LINE = 10

var _tiles: Array = []


##
## Reads all tiles from a Krita layer data blob and returns a flat
## interleaved RGBA buffer of the whole layer.
##
## The layer file format (VERSION 2) is:
##   VERSION <n>\n
##   TILEWIDTH <w>\n
##   TILEHEIGHT <h>\n
##   PIXELSIZE <s>\n
##   DATA <num_tiles>\n
##   <x>,<y>,<COMPRESSION>,<size>\n<data> repeated num_tiles times
##
## Each tile payload: first byte is a flag (0 = raw, 1 = LZF), then
## either the raw interleaved pixel bytes or the LZF stream. Krita
## stores color channels linearly (all reds, then greens, ...), so
## after decompression the data must be delinearized back to
## interleaved RGBA.
##
func read_layer_tiles(data: PackedByteArray) -> Dictionary:
	_tiles = []
	var headers_result := parse_tile_headers(data)
	if not headers_result.is_ok:
		return headers_result

	for header in headers_result.content.tiles:
		var tile: Variant = decode_tile_payload(header.payload, 1.0, false, 0, 0, TILE_WIDTH - 1, TILE_HEIGHT - 1, PIXEL_SIZE)
		if tile == null:
			return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

		_tiles.push_back({
			"x": header.x,
			"y": header.y,
			"data": tile.data,
		})

	return result_codes.result({
		"tiles": _tiles,
	})


##
## Scans the tile headers of a layer file without decoding payloads.
## Fast: only walks header lines and records payload slices.
## Returns { tiles: [{x, y, payload}] }.
##
func parse_tile_headers(data: PackedByteArray) -> Dictionary:
	var headers := []
	var pos := 0
	var num_tiles := -1

	while true:
		var line_result := _read_line(data, pos)
		if not line_result.is_ok:
			return line_result
		var line: String = line_result.content[0]
		pos = line_result.content[1]

		if line.strip_edges() == "":
			continue

		var parts := line.split(" ")
		if parts.size() == 0:
			continue

		var keyword = parts[0]
		if keyword == "DATA":
			num_tiles = int(parts[1])
			break

		var valid_headers = ["VERSION", "TILEWIDTH", "TILEHEIGHT", "PIXELSIZE"]
		if not valid_headers.has(keyword):
			return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	if num_tiles < 0:
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	for i in range(num_tiles):
		var line_result := _read_line(data, pos)
		if not line_result.is_ok:
			return line_result
		var tile_header: String = line_result.content[0]
		pos = line_result.content[1]

		var parts := tile_header.split(",")
		if parts.size() < 4:
			return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

		var x := int(parts[0])
		var y := int(parts[1])
		var size := int(parts[3])

		if pos + size > data.size():
			return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

		headers.push_back({
			"x": x,
			"y": y,
			"payload": data.slice(pos, pos + size),
		})
		pos += size

	return result_codes.result({"tiles": headers})


##
## Decodes one tile payload into an interleaved pixel buffer.
## Pure function of its inputs: safe to run on worker threads.
## opacity/bake_alpha scale the alpha channel (same truncation math as before;
## only applied to 4-channel RGBA tiles).
## pixelsize selects the channel count: 4 for RGBA layers, 2 for GrayA
## transparency masks. Content bounds are computed only inside the given
## tile-local clip rect (inclusive), so off-canvas content never affects
## trimming. Pass the full tile (0, 0, 63, 63) when no clipping applies.
##
## Returns { data, has_content, min_x, min_y, max_x, max_y } where the
## bounds are tile-local coordinates of non-transparent pixels
## (for masks: pixels with nonzero gray value).
## Returns null on failure.
##
static func decode_tile_payload(payload: PackedByteArray, opacity: float, bake_alpha: bool, clip_x0: int, clip_y0: int, clip_x1: int, clip_y1: int, pixelsize: int = PIXEL_SIZE) -> Variant:
	if payload.is_empty():
		return null

	var tile_size := TILE_WIDTH * TILE_HEIGHT * pixelsize
	var flag := payload[0]
	var rest := payload.slice(1, payload.size())
	var interleaved: PackedByteArray

	if flag == RAW_DATA_FLAG:
		# Raw tiles store native-order pixels directly (no channel
		# linearization), unlike LZF tiles. Native RGBA order is
		# B,G,R,A, so red and blue are swapped into place here.
		if rest.size() != tile_size:
			return null
		if pixelsize == PIXEL_SIZE:
			interleaved = PackedByteArray()
			interleaved.resize(tile_size)
			var p := 0
			while p < tile_size:
				interleaved[p] = rest[p + 2]
				interleaved[p + 1] = rest[p + 1]
				interleaved[p + 2] = rest[p]
				interleaved[p + 3] = rest[p + 3]
				p += 4
		else:
			interleaved = rest
	elif flag == COMPRESSED_DATA_FLAG:
		var decompressed: Variant = lzf_decompress(rest, tile_size)
		if decompressed == null:
			return null
		var linear: PackedByteArray = decompressed
		var order: Array = RGBA_CHANNEL_ORDER if pixelsize == PIXEL_SIZE else GRAYA_CHANNEL_ORDER
		interleaved = PackedByteArray()
		interleaved.resize(tile_size)
		var stride := tile_size / pixelsize
		var offset := 0
		for start in range(stride):
			for c in range(pixelsize):
				interleaved[offset] = linear[start + int(order[c]) * stride]
				offset += 1
	else:
		return null

	if bake_alpha and pixelsize == PIXEL_SIZE:
		var i := 3
		while i < interleaved.size():
			interleaved[i] = int(float(interleaved[i]) * opacity)
			i += 4

	# Bounds scan reads the coverage channel: alpha for RGBA, gray for GrayA.
	var value_offset := pixelsize - 1 if pixelsize == PIXEL_SIZE else 0
	var bounds := _tile_content_bounds(interleaved, clip_x0, clip_y0, clip_x1, clip_y1, value_offset, pixelsize)

	return {
		"data": interleaved,
		"has_content": bounds[0],
		"fully_opaque": bounds[5],
		"min_x": bounds[1],
		"min_y": bounds[2],
		"max_x": bounds[3],
		"max_y": bounds[4],
	}


## Finds the bounding box of non-transparent pixels in an interleaved
## tile, restricted to the given tile-local clip rect (inclusive).
## value_offset selects the coverage channel (3 = RGBA alpha, 0 = gray).
## Returns [found, min_x, min_y, max_x, max_y, fully_opaque] in tile-local
## coordinates. fully_opaque is true when every scanned pixel is opaque.
static func _tile_content_bounds(interleaved: PackedByteArray, clip_x0: int, clip_y0: int, clip_x1: int, clip_y1: int, value_offset: int, pixelsize: int) -> Array:
	var min_x := TILE_WIDTH
	var min_y := TILE_HEIGHT
	var max_x := -1
	var max_y := -1
	var fully_opaque := true

	var x0 := maxi(0, clip_x0)
	var y0 := maxi(0, clip_y0)
	var x1 := mini(TILE_WIDTH - 1, clip_x1)
	var y1 := mini(TILE_HEIGHT - 1, clip_y1)

	for row in range(y0, y1 + 1):
		var row_base := row * TILE_WIDTH * pixelsize
		for col in range(x0, x1 + 1):
			var v := interleaved[row_base + col * pixelsize + value_offset]
			if v > 0:
				if col < min_x:
					min_x = col
				if col > max_x:
					max_x = col
				if row < min_y:
					min_y = row
				if row > max_y:
					max_y = row
				if v < 255:
					fully_opaque = false
			else:
				fully_opaque = false

	# Pixels outside the clip rect are unknown to the caller; only the
	# scanned region counts toward opacity.
	if x0 > 0 or y0 > 0 or x1 < TILE_WIDTH - 1 or y1 < TILE_HEIGHT - 1:
		fully_opaque = false

	return [max_x >= 0, min_x, min_y, max_x, max_y, fully_opaque and max_x >= 0]


func _read_line(data: PackedByteArray, start: int) -> Dictionary:
	if start >= data.size():
		return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)
	var end := start
	while end < data.size() and data[end] != _NEW_LINE:
		end += 1
	var line := data.slice(start, end).get_string_from_ascii()
	return result_codes.result([line, end + 1])


##
## libLZF (as used by Krita) decompression.
## Returns a PackedByteArray with the given output size or null on failure.
##
## Speed: literal runs and non-overlapping matches are copied with native
## slice/append (memcpy); only overlapping matches fall back to a byte loop.
##
static func lzf_decompress(input_data: PackedByteArray, expected_output_size: int) -> Variant:
	var out := PackedByteArray()

	var ip := 0
	var input_size := input_data.size()

	while ip < input_size:
		var ctrl := input_data[ip]
		ip += 1

		if ctrl < 32:
			ctrl += 1
			if ip + ctrl > input_size:
				return null
			out.append_array(input_data.slice(ip, ip + ctrl))
			ip += ctrl
		else:
			var length := ctrl >> 5
			var op := out.size()
			var ref := op - ((ctrl & 0x1f) << 8) - 1

			if length == 7:
				if ip >= input_size:
					return null
				length += input_data[ip]
				ip += 1

			if ip >= input_size:
				return null
			ref -= input_data[ip]
			ip += 1

			if ref < 0:
				return null

			var match_len := length + 2
			if ref + match_len <= op:
				out.append_array(out.slice(ref, ref + match_len))
			else:
				for i in range(match_len):
					if ref + i >= out.size():
						return null
					out.append(out[ref + i])

	if out.size() != expected_output_size:
		return null

	return out