@tool
extends RefCounted

const result_codes = preload("../config/result_codes.gd")
const logger = preload("../config/logger.gd")
const lzf = preload("./lzf.gd")
const layer_tags = preload("./layer_tags.gd")
const blend_modes = preload("./blend_modes.gd")

const BYTES_PER_PIXEL = 4

## Layers with fewer tiles than this decode inline; larger ones use
## worker threads (dispatch overhead is not worth it for tiny layers).
const _THREAD_TILE_THRESHOLD = 16

var _warned_modes := {}


##
## Merges layers into a single image.
##
## `layers` must be in paint order (bottom layer first, top layer last),
## as returned by KraParser.get_paint_layers().
##
## Options:
##    only_visible (bool)
##    exception_pattern (string) - layer names excluded if they match
##    trim (bool) - crop result to the used rect of non-transparent pixels
##    scale (float) - resize factor applied to the final Image (may be < 1 to downscale)
##
## Returns:
##    Dictionary with:
##      image: Image (straight RGBA8)
##      used_rect: Rect2i (in source pixel coords)
##
func compose(parser, layers: Array, options: Dictionary) -> Dictionary:
	var only_visible: bool = options.get("only_visible", false)
	var exception_pattern: String = options.get("exception_pattern", "")
	var width: int = parser.get_width()
	var height: int = parser.get_height()

	# Collect the layers that will contribute, in paint order (bottom to top).
	var contributing := []
	for layer in layers:
		if not _should_include(layer, only_visible, exception_pattern):
			continue
		contributing.push_back(layer)

	if contributing.is_empty():
		return result_codes.error(result_codes.ERR_NO_VALID_LAYERS_FOUND)

	var canvas := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0, 0, 0, 0))

	var bounds := _Bounds.new(width, height)

	for layer in contributing:
		var opacity: float = float(_effective_opacity(layer)) / 255.0
		var built: Dictionary = _build_layer_image(parser, layer, opacity, width, height)
		if not built.is_ok:
			logger.error("Could not decode layer: %s" % str(layer.name))
			return built
		if not built.content.has_content:
			continue
		_blend_built_layer(canvas, built.content.image, built.content.rect, layer, width, height, bool(built.content.get("fully_opaque", false)))
		bounds.include_rect(built.content.rect)

	if not bounds.found_any:
		return result_codes.error(result_codes.ERR_NO_VALID_LAYERS_FOUND)

	var image := canvas
	var used_rect: Rect2i = bounds.to_rect()
	if bool(options.get("trim", false)):
		image = canvas.get_region(used_rect)
		width = used_rect.size.x
		height = used_rect.size.y

	var scale := maxf(0.01, float(options.get("scale", 1.0)))
	_apply_scale(image, width, height, scale)

	return result_codes.result({
		"image": image,
		"used_rect": used_rect,
	})


##
## Full-document composite with group support.
##
## Top-level groups render isolated (own canvas) unless trivially simple,
## in which case their children blend flat exactly like before. Trivial
## means: effective opacity 255, normal/passthrough mode, no visible
## masks on the group, and all descendants normal and unmasked.
## Trivial documents produce byte-identical output to compose().
##
func compose_tree(parser, options: Dictionary) -> Dictionary:
	var nodes: Array = parser.get_layers().duplicate()
	nodes.reverse()
	return _compose_tree_nodes(parser, nodes, options)


## Composites one animation frame. `nodes_doc_order` is a document-order
## node array (like KraParser.get_layers(), e.g. built by the animation
## module with per-frame layer files swapped in); output shape matches
## compose_tree exactly.
func compose_animation_frame(parser, nodes_doc_order: Array, options: Dictionary) -> Dictionary:
	var nodes: Array = nodes_doc_order.duplicate()
	nodes.reverse()
	return _compose_tree_nodes(parser, nodes, options)


## `nodes` must be in paint order (bottom layer first, top layer last).
func _compose_tree_nodes(parser, nodes: Array, options: Dictionary) -> Dictionary:
	var only_visible: bool = options.get("only_visible", false)
	var exception_pattern: String = options.get("exception_pattern", "")
	var width: int = parser.get_width()
	var height: int = parser.get_height()

	if nodes.is_empty():
		return result_codes.error(result_codes.ERR_NO_VALID_LAYERS_FOUND)

	var canvas := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0, 0, 0, 0))

	var bounds := _Bounds.new(width, height)
	_compose_level(parser, nodes, canvas, bounds, width, height, 1.0, true, only_visible, exception_pattern)

	if not bounds.found_any:
		return result_codes.error(result_codes.ERR_NO_VALID_LAYERS_FOUND)

	var image := canvas
	var used_rect: Rect2i = bounds.to_rect()
	if bool(options.get("trim", false)):
		image = canvas.get_region(used_rect)
		width = used_rect.size.x
		height = used_rect.size.y

	var scale := maxf(0.01, float(options.get("scale", 1.0)))
	_apply_scale(image, width, height, scale)

	return result_codes.result({
		"image": image,
		"used_rect": used_rect,
	})


## Composites paint-ordered nodes (paint layers and/or groups) onto canvas.
## opacity_mult carries accumulated ancestor opacity; ancestors_visible
## carries the AND of ancestor visibility (only consulted in only_visible
## mode — otherwise hidden nodes still render).
func _compose_level(parser, nodes: Array, canvas: Image, bounds: _Bounds, width: int, height: int, opacity_mult: float, ancestors_visible: bool, only_visible: bool, exception_pattern: String) -> void:
	for node in nodes:
		if node.nodetype == "paintlayer":
			if not _include_node(node, ancestors_visible, only_visible, exception_pattern):
				continue
			var eff_op := opacity_mult * float(node.opacity) / 255.0
			var built: Dictionary = _build_layer_image(parser, node, eff_op, width, height)
			if not built.is_ok:
				logger.error("Could not decode layer: %s" % str(node.name))
				continue
			if not built.content.has_content:
				continue
			_blend_built_layer(canvas, built.content.image, built.content.rect, node, width, height, bool(built.content.get("fully_opaque", false)))
			bounds.include_rect(built.content.rect)
		elif node.nodetype == "grouplayer":
			_compose_group(parser, node, canvas, bounds, width, height, opacity_mult, ancestors_visible, only_visible, exception_pattern)


func _include_node(node: Dictionary, ancestors_visible: bool, only_visible: bool, exception_pattern: String) -> bool:
	if layer_tags.parse_layer_name(str(node.name)).exclude:
		return false
	if only_visible:
		if not bool(node.visible) or not ancestors_visible:
			return false
	if exception_pattern != "":
		if str(node.name).match(exception_pattern):
			return false
	return true


## Blends one built layer image with its blend mode resolved.
## Fully opaque normal layers are copied (exact and faster than blending).
func _blend_built_layer(canvas: Image, layer_image: Image, rect: Rect2i, node: Dictionary, width: int, height: int, fully_opaque: bool) -> void:
	var mode := _resolve_mode(node)
	if mode == blend_modes.MODE_NORMAL:
		if fully_opaque:
			canvas.blit_rect(layer_image, Rect2i(0, 0, width, height), Vector2i(0, 0))
		else:
			canvas.blend_rect(layer_image, Rect2i(0, 0, width, height), Vector2i(0, 0))
	else:
		_blend_layer_custom(canvas, layer_image, rect, mode)


## Composites a group: flat fast path for trivial groups, isolated
## render (own temp canvas + masks + opacity + group mode) otherwise.
func _compose_group(parser, group: Dictionary, canvas: Image, bounds: _Bounds, width: int, height: int, opacity_mult: float, ancestors_visible: bool, only_visible: bool, exception_pattern: String) -> void:
	if not _include_node(group, ancestors_visible, only_visible, exception_pattern):
		return

	var children := (group.children as Array).duplicate()
	children.reverse()

	var g_op := opacity_mult * float(group.opacity) / 255.0
	var g_vis := ancestors_visible and bool(group.visible)

	if _is_trivial_group(group):
		_compose_level(parser, children, canvas, bounds, width, height, g_op, g_vis, only_visible, exception_pattern)
		return

	var temp := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	temp.fill(Color(0, 0, 0, 0))
	var temp_bounds := _Bounds.new(width, height)
	_compose_level(parser, children, temp, temp_bounds, width, height, 1.0, g_vis, only_visible, exception_pattern)
	if not temp_bounds.found_any:
		return

	var content_rect: Rect2i = temp_bounds.to_rect()
	_apply_masks_to_image(parser, group.masks, temp, content_rect)
	if not is_equal_approx(g_op, 1.0):
		_bake_opacity_to_image(temp, content_rect, g_op)

	var mode := _resolve_group_mode(group)
	if mode == blend_modes.MODE_NORMAL:
		canvas.blend_rect(temp, Rect2i(0, 0, width, height), Vector2i(0, 0))
	else:
		_blend_layer_custom(canvas, temp, content_rect, mode)
	bounds.include_rect(content_rect)


## A group is trivial when flattening it is exactly equivalent to an
## isolated render: full opacity, pass-through-ish mode, no visible
## masks, and a fully simple subtree.
func _is_trivial_group(group: Dictionary) -> bool:
	if int(group.opacity) != 255:
		return false
	var mode := blend_modes.normalize_mode(str(group.get("blend_mode", "passthrough")))
	if mode != "" and mode != blend_modes.MODE_NORMAL and mode != "passthrough":
		return false
	for mask in group.masks:
		if bool(mask.visible):
			return false
	return _subtree_is_simple(group.children)


func _subtree_is_simple(nodes: Array) -> bool:
	for node in nodes:
		if node.nodetype == "paintlayer":
			if blend_modes.normalize_mode(str(node.get("blend_mode", "normal"))) != blend_modes.MODE_NORMAL:
				return false
			for mask in node.masks:
				if bool(mask.visible):
					return false
		elif node.nodetype == "grouplayer":
			if not _is_trivial_group(node):
				return false
	return true


func _resolve_group_mode(group: Dictionary) -> String:
	var raw := str(group.get("blend_mode", "passthrough"))
	if raw == "" or raw.to_lower() == "passthrough":
		return blend_modes.MODE_NORMAL
	var mode := blend_modes.normalize_mode(raw)
	if mode != "":
		return mode
	if not _warned_modes.has("group:" + raw):
		_warned_modes["group:" + raw] = true
		logger.warn("Unsupported group blend mode '%s' on group '%s', falling back to normal" % [raw, str(group.get("name", "?"))])
	return blend_modes.MODE_NORMAL


##
## Composites one group in isolation (for flatten export).
## paint_subset: explicit paint layers bottom-to-top, or [] for all
## descendants (collected bottom-to-top automatically).
## Group masks and opacity are baked in.
## Returns { image, rect } on the full canvas (untrimmed).
##
func compose_group_isolated(parser, group: Dictionary, paint_subset: Array, options: Dictionary) -> Dictionary:
	var width: int = parser.get_width()
	var height: int = parser.get_height()
	var only_visible: bool = options.get("only_visible", false)
	var exception_pattern: String = options.get("exception_pattern", "")

	var nodes: Array = paint_subset
	if nodes.is_empty():
		nodes = []
		_collect_group_paint(group.children, nodes)
		nodes.reverse()

	var temp := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	temp.fill(Color(0, 0, 0, 0))
	var temp_bounds := _Bounds.new(width, height)
	_compose_level(parser, nodes, temp, temp_bounds, width, height, 1.0, true, only_visible, exception_pattern)
	if not temp_bounds.found_any:
		return result_codes.error(result_codes.ERR_NO_VALID_LAYERS_FOUND)

	var content_rect: Rect2i = temp_bounds.to_rect()
	_apply_masks_to_image(parser, group.masks, temp, content_rect)
	var g_op := float(group.opacity) / 255.0
	if not is_equal_approx(g_op, 1.0):
		_bake_opacity_to_image(temp, content_rect, g_op)

	return result_codes.result({"image": temp, "rect": content_rect})


func _collect_group_paint(nodes: Array, out: Array) -> void:
	for node in nodes:
		if node.nodetype == "paintlayer":
			out.push_back(node)
		elif node.nodetype == "grouplayer":
			_collect_group_paint(node.children, out)


## Applies visible masks to an image, restricted to rect. Missing mask
## tiles count as 0 (fully masked out), matching the tile-decode default.
func _apply_masks_to_image(parser, masks: Array, image: Image, rect: Rect2i) -> void:
	var active := []
	for mask in masks:
		if bool(mask.visible):
			active.push_back(mask)
	if active.is_empty():
		return

	var area := rect.intersection(Rect2i(0, 0, image.get_width(), image.get_height()))
	if area.size.x <= 0 or area.size.y <= 0:
		return

	var mask_bufs := []
	for mask in active:
		var headers_result: Dictionary = parser.get_mask_tile_headers(mask)
		if not headers_result.is_ok:
			logger.warn("Could not read mask '%s', ignoring it" % str(mask.name))
			continue
		var tilemap := {}
		for header in (headers_result.content.tiles as Array):
			var decoded: Variant = lzf.decode_tile_payload(header.payload, 1.0, false, 0, 0, lzf.TILE_WIDTH - 1, lzf.TILE_HEIGHT - 1, 2)
			if decoded == null:
				continue
			tilemap[Vector2i(int(header.x), int(header.y))] = decoded.data
		mask_bufs.push_back(tilemap)
	if mask_bufs.is_empty():
		return

	var buf := image.get_data()
	var W := image.get_width()
	for y in range(area.position.y, area.end.y):
		var base := y * W * BYTES_PER_PIXEL
		for x in range(area.position.x, area.end.x):
			var offset := base + x * BYTES_PER_PIXEL
			var a := buf[offset + 3]
			if a == 0:
				continue
			var tx := (x / lzf.TILE_WIDTH) * lzf.TILE_WIDTH
			var ty := (y / lzf.TILE_HEIGHT) * lzf.TILE_HEIGHT
			var key := Vector2i(tx, ty)
			for tilemap in mask_bufs:
				if not tilemap.has(key):
					a = 0
					break
				var m: PackedByteArray = tilemap[key]
				var lx := x - tx
				var ly := y - ty
				var mv := m[(ly * lzf.TILE_WIDTH + lx) * 2]
				if mv < 255:
					a = int(float(a) * float(mv) / 255.0 + 0.5)
					if a == 0:
						break
			buf[offset + 3] = a
	image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, buf)


## Scales an image's alpha channel in place, restricted to rect.
func _bake_opacity_to_image(image: Image, rect: Rect2i, opacity: float) -> void:
	var area := rect.intersection(Rect2i(0, 0, image.get_width(), image.get_height()))
	if area.size.x <= 0 or area.size.y <= 0:
		return
	var buf := image.get_data()
	var W := image.get_width()
	for y in range(area.position.y, area.end.y):
		var base := y * W * BYTES_PER_PIXEL
		for x in range(area.position.x, area.end.x):
			var offset := base + x * BYTES_PER_PIXEL + 3
			buf[offset] = int(float(buf[offset]) * opacity)
	image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, buf)
func compose_layer(parser, layer: Dictionary, options: Dictionary) -> Dictionary:
	var width: int = parser.get_width()
	var height: int = parser.get_height()

	var opacity: float = float(_effective_opacity(layer)) / 255.0
	var built: Dictionary = _build_layer_image(parser, layer, opacity, width, height)
	if not built.is_ok:
		return built
	if not built.content.has_content:
		return result_codes.error(result_codes.ERR_NO_VALID_LAYERS_FOUND)

	var image: Image = built.content.image
	var used_rect: Rect2i = built.content.rect

	if bool(options.get("trim", false)):
		image = image.get_region(used_rect)
		width = used_rect.size.x
		height = used_rect.size.y

	var mode := _resolve_mode(layer)
	if mode == "erase":
		# An erase layer removes backdrop; alone over transparency it
		# contributes nothing.
		image.fill(Color(0, 0, 0, 0))

	var scale := maxf(0.01, float(options.get("scale", 1.0)))
	_apply_scale(image, width, height, scale)

	return result_codes.result({
		"image": image,
		"used_rect": used_rect,
	})


##
## Decodes one paint layer into a full-canvas Image using native blits.
## Tile LZF decoding stays in GDScript (content-proportional) but runs on
## worker threads; all canvas-sized work (fill, blit, blend) runs native.
##
## Returns { image, has_content, rect } where rect is the used Rect2i
## in canvas coordinates.
##
func _build_layer_image(parser, layer: Dictionary, opacity: float, width: int, height: int) -> Dictionary:
	var headers_result: Dictionary = parser.get_layer_tile_headers(layer)
	if not headers_result.is_ok:
		return headers_result

	var headers: Array = headers_result.content.tiles
	var decoded: Array = _decode_tile_headers(headers, opacity, width, height)
	for tile_data in decoded:
		if tile_data == null:
			return result_codes.error(result_codes.ERR_INVALID_KRA_FILE)

	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	var default_pixel: Variant = parser.get_layer_default_pixel(layer)
	# Default pixels are stored in native B,G,R,A order like tiles.
	var default_opaque := false
	if default_pixel != null and default_pixel.size() >= 4:
		image.fill(Color(default_pixel[2] / 255.0, default_pixel[1] / 255.0, default_pixel[0] / 255.0, default_pixel[3] / 255.0))
		default_opaque = default_pixel[3] == 255
	else:
		image.fill(Color(0, 0, 0, 0))

	# Transparency/selection masks multiply into the layer alpha.
	# Decoded once per mask (workers), baked per layer tile on the
	# main thread; bounds are re-tightened afterwards so fully
	# masked-out regions never affect trimming.
	var mask_tiles := _decode_layer_masks(parser, layer, width, height)
	if not mask_tiles.is_empty():
		for i in range(headers.size()):
			var tile: Dictionary = decoded[i]
			if not tile.has_content:
				continue
			var key := Vector2i(int(headers[i].x), int(headers[i].y))
			if not mask_tiles.has(key):
				# No mask tile here: mask value is 0, hide everything.
				tile.has_content = false
				tile.fully_opaque = false
				continue
			_apply_mask_to_tile(tile, mask_tiles[key])

	var bounds := _Bounds.new(width, height)
	var fully_opaque := true
	var grid_w := (width + lzf.TILE_WIDTH - 1) / lzf.TILE_WIDTH
	var grid_h := (height + lzf.TILE_HEIGHT - 1) / lzf.TILE_HEIGHT
	var covered_cells := 0

	for i in range(headers.size()):
		var tile: Dictionary = decoded[i]
		if not tile.has_content:
			fully_opaque = false
			continue
		var tx := int(headers[i].x)
		var ty := int(headers[i].y)
		# Skip tiles fully outside the canvas (they still count as
		# decoded, but contribute nothing).
		if tx + lzf.TILE_WIDTH <= 0 or ty + lzf.TILE_HEIGHT <= 0 or tx >= width or ty >= height:
			fully_opaque = false
			continue
		covered_cells += 1
		if not bool(tile.fully_opaque):
			fully_opaque = false
		var tile_data: PackedByteArray = tile.data
		# Canvas clip of this tile, in tile-local coordinates.
		var clip := Rect2i(
			maxi(0, -tx), maxi(0, -ty),
			mini(lzf.TILE_WIDTH, width - tx), mini(lzf.TILE_HEIGHT, height - ty)
		)
		# Visible content = tile content intersected with the canvas clip.
		# Content outside the canvas must not affect trimming.
		var content := Rect2i(
			int(tile.min_x), int(tile.min_y),
			int(tile.max_x) - int(tile.min_x) + 1, int(tile.max_y) - int(tile.min_y) + 1
		)
		var visible := content.intersection(clip)
		if visible.size.x <= 0 or visible.size.y <= 0:
			continue
		_blit_tile(image, tile_data, tx, ty, width, height)
		bounds.include_rect(Rect2i(
			tx + visible.position.x, ty + visible.position.y,
			visible.size.x, visible.size.y
		))

	if covered_cells < grid_w * grid_h and not default_opaque:
		fully_opaque = false

	return result_codes.result({
		"image": image,
		"has_content": bounds.found_any,
		"fully_opaque": fully_opaque and bounds.found_any,
		"rect": bounds.to_rect(),
	})


## Worker task: decodes one tile payload into an interleaved pixel buffer.
## Content bounds are restricted to the canvas-visible subrect so
## off-canvas content never affects trimming.
func _decode_tile_task(index: int, headers: Array, results: Array, mutex: Mutex, opacity: float, bake_alpha: bool, canvas_w: int, canvas_h: int, pixelsize: int) -> void:
	var tx := int(headers[index].x)
	var ty := int(headers[index].y)
	var decoded: Variant = lzf.decode_tile_payload(
		headers[index].payload, opacity, bake_alpha,
		maxi(0, -tx), maxi(0, -ty),
		mini(lzf.TILE_WIDTH - 1, canvas_w - tx - 1), mini(lzf.TILE_HEIGHT - 1, canvas_h - ty - 1),
		pixelsize
	)
	mutex.lock()
	results[index] = decoded
	mutex.unlock()


## Decodes all tile payloads, using worker threads for larger layers.
## Small layers decode inline to avoid dispatch overhead.
## pixelsize is 4 for RGBA layers, 2 for GrayA masks.
## Returns an Array of decode dicts (may contain null on failure).
func _decode_tile_headers(headers: Array, opacity: float, canvas_w: int, canvas_h: int, pixelsize: int = 4) -> Array:
	var results := []
	results.resize(headers.size())
	if headers.is_empty():
		return results

	var bake_alpha := not is_equal_approx(opacity, 1.0)

	if headers.size() < _THREAD_TILE_THRESHOLD:
		for i in range(headers.size()):
			var tx := int(headers[i].x)
			var ty := int(headers[i].y)
			results[i] = lzf.decode_tile_payload(
				headers[i].payload, opacity, bake_alpha,
				maxi(0, -tx), maxi(0, -ty),
				mini(lzf.TILE_WIDTH - 1, canvas_w - tx - 1), mini(lzf.TILE_HEIGHT - 1, canvas_h - ty - 1),
				pixelsize
			)
		return results

	var mutex := Mutex.new()
	var group := WorkerThreadPool.add_group_task(
		Callable(self, "_decode_tile_task").bind(headers, results, mutex, opacity, bake_alpha, canvas_w, canvas_h, pixelsize),
		headers.size()
	)
	WorkerThreadPool.wait_for_group_task_completion(group)
	return results


## Copies one 64x64 tile into the canvas image, clipping to bounds.
func _blit_tile(image: Image, tile_data: PackedByteArray, tile_x: int, tile_y: int, width: int, height: int) -> void:
	var src_x := maxi(0, -tile_x)
	var src_y := maxi(0, -tile_y)
	var copy_w := mini(lzf.TILE_WIDTH - src_x, width - tile_x - src_x)
	var copy_h := mini(lzf.TILE_HEIGHT - src_y, height - tile_y - src_y)
	if copy_w <= 0 or copy_h <= 0:
		return

	var tile_image := Image.create_from_data(lzf.TILE_WIDTH, lzf.TILE_HEIGHT, false, Image.FORMAT_RGBA8, tile_data)
	image.blit_rect(tile_image, Rect2i(src_x, src_y, copy_w, copy_h), Vector2i(tile_x + src_x, tile_y + src_y))


func _apply_scale(image: Image, width: int, height: int, scale: float) -> void:
	if is_equal_approx(scale, 1.0):
		return
	var new_width := maxi(1, int(width * scale + 0.5))
	var new_height := maxi(1, int(height * scale + 0.5))
	var interpolation := Image.INTERPOLATE_NEAREST if scale > 1.0 else Image.INTERPOLATE_BILINEAR
	image.resize(new_width, new_height, interpolation)


func _should_include(layer: Dictionary, only_visible: bool, exception_pattern: String) -> bool:
	if layer_tags.parse_layer_name(str(layer.name)).exclude:
		return false

	if only_visible:
		if not layer.visible:
			return false
		var parent = layer.parent_group
		while parent != null:
			if not parent.visible:
				return false
			parent = parent.parent_group

	if exception_pattern != "":
		if layer.name != null and str(layer.name).match(exception_pattern):
			return false

	return true


func _effective_opacity(layer: Dictionary) -> int:
	var opacity: int = layer.opacity
	var parent = layer.parent_group
	while parent != null:
		opacity = (opacity * parent.opacity) / 255
		parent = parent.parent_group
	return opacity


## Resolves a layer's Krita compositeop id to a supported mode id.
## Unknown modes warn once and fall back to normal.
func _resolve_mode(layer: Dictionary) -> String:
	var raw := str(layer.get("blend_mode", "normal"))
	var mode := blend_modes.normalize_mode(raw)
	if mode != "":
		return mode
	if not _warned_modes.has(raw):
		_warned_modes[raw] = true
		logger.warn("Unsupported blend mode '%s' on layer '%s', falling back to normal" % [raw, str(layer.get("name", "?"))])
	return blend_modes.MODE_NORMAL


## Blends one layer image onto the canvas with an explicit blend mode,
## restricted to the layer's used rect. Used for non-normal layers only;
## normal layers take the native blend_rect fast path.
func _blend_layer_custom(canvas: Image, layer_image: Image, rect: Rect2i, mode_id: String) -> void:
	var canvas_w := canvas.get_width()
	var canvas_h := canvas.get_height()
	var area := rect.intersection(Rect2i(0, 0, canvas_w, canvas_h))
	if area.size.x <= 0 or area.size.y <= 0:
		return

	var canvas_buf := canvas.get_data()
	var layer_buf := layer_image.get_data()

	for y in range(area.position.y, area.end.y):
		var base := y * canvas_w * BYTES_PER_PIXEL
		for x in range(area.position.x, area.end.x):
			var offset := base + x * BYTES_PER_PIXEL
			var src_a := layer_buf[offset + 3]
			if src_a == 0:
				continue
			blend_modes.blend_pixel(canvas_buf, offset, layer_buf, offset, src_a, mode_id)

	canvas.set_data(canvas_w, canvas_h, false, Image.FORMAT_RGBA8, canvas_buf)


##
## Decodes a layer's visible transparency/selection masks into
## {(tile_x, tile_y): GrayA-interleaved bytes}. Missing tiles mean
## mask value 0 (fully masked out). Returns {} when there is nothing
## to apply.
##
func _decode_layer_masks(parser, layer: Dictionary, width: int, height: int) -> Dictionary:
	var out := {}
	if layer.masks.is_empty():
		return out

	for mask in layer.masks:
		if not mask.visible:
			continue
		var headers_result: Dictionary = parser.get_mask_tile_headers(mask)
		if not headers_result.is_ok:
			logger.warn("Could not read mask '%s', ignoring it" % str(mask.name))
			continue
		var headers: Array = headers_result.content.tiles
		var decoded: Array = _decode_tile_headers(headers, 1.0, width, height, 2)
		for i in range(headers.size()):
			var tile: Variant = decoded[i]
			if tile == null:
				continue
			var key := Vector2i(int(headers[i].x), int(headers[i].y))
			if out.has(key):
				_multiply_mask_tile(out[key], tile.data)
			else:
				out[key] = (tile.data as PackedByteArray).duplicate()
	return out


## Multiplies GrayA mask buffers in place (gray channel only).
func _multiply_mask_tile(target: PackedByteArray, other: PackedByteArray) -> void:
	var i := 0
	while i < target.size() and i < other.size():
		target[i] = int(float(target[i]) * float(other[i]) / 255.0 + 0.5)
		i += 2


## Multiplies a layer tile's alpha channel by a GrayA mask tile
## (gray channel carries the mask value) and re-tightens its bounds.
func _apply_mask_to_tile(tile: Dictionary, mask_data: PackedByteArray) -> void:
	var layer_data: PackedByteArray = tile.data
	var count := mini(layer_data.size() / 4, mask_data.size() / 2)
	var min_x := lzf.TILE_WIDTH
	var min_y := lzf.TILE_HEIGHT
	var max_x := -1
	var max_y := -1
	var all_opaque := true

	for p in range(count):
		var m := mask_data[p * 2]
		var aoff := p * 4 + 3
		var a := layer_data[aoff]
		if m < 255:
			a = int(float(a) * float(m) / 255.0 + 0.5)
			layer_data[aoff] = a
		if a > 0:
			var col := p % lzf.TILE_WIDTH
			var row := p / lzf.TILE_WIDTH
			if col < min_x:
				min_x = col
			if col > max_x:
				max_x = col
			if row < min_y:
				min_y = row
			if row > max_y:
				max_y = row
			if a < 255:
				all_opaque = false
		else:
			all_opaque = false

	tile.has_content = max_x >= 0
	tile.fully_opaque = all_opaque and max_x >= 0
	tile.min_x = min_x
	tile.min_y = min_y
	tile.max_x = max_x
	tile.max_y = max_y


## Tracks the used rectangle over many tile blits without scanning pixels.
class _Bounds:
	extends RefCounted

	var min_x: int
	var min_y: int
	var max_x: int
	var max_y: int
	var found_any := false
	var _canvas_w: int
	var _canvas_h: int

	func _init(canvas_w: int, canvas_h: int) -> void:
		_canvas_w = canvas_w
		_canvas_h = canvas_h
		min_x = canvas_w
		min_y = canvas_h
		max_x = -1
		max_y = -1

	func include_point(x: int, y: int) -> void:
		found_any = true
		if x < min_x:
			min_x = x
		if x > max_x:
			max_x = x
		if y < min_y:
			min_y = y
		if y > max_y:
			max_y = y

	func include_rect(rect: Rect2i) -> void:
		var clipped := rect.intersection(Rect2i(0, 0, _canvas_w, _canvas_h))
		if clipped.size.x <= 0 or clipped.size.y <= 0:
			return
		include_point(clipped.position.x, clipped.position.y)
		include_point(clipped.end.x - 1, clipped.end.y - 1)

	func to_rect() -> Rect2i:
		if not found_any:
			return Rect2i(0, 0, 0, 0)
		return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)