@tool
extends RefCounted

##
## Krita timeline animation support.
##
## Krita stores animation as per-layer keyframes: an animated paint layer
## carries a `keyframes="<file>.keyframes.xml"` attribute, and that file
## maps timeline frames to tile files (`<keyframe time="2"
## frame="layer3.f1"/>`). Frame files use the same raw tile format as
## regular layers, so rendering frame t only means decoding a different
## file per layer and compositing exactly like a static document
## (hold semantics: the active keyframe is the last one with
## time <= t).
##
## Clips: each top-level group becomes one named SpriteFrames animation
## (the group's keyframe span, or a single frame when static);
## ungrouped layers are shared backdrop rendered into every clip. A
## document without top-level groups yields one "default" animation.
##

const layer_tags = preload("./layer_tags.gd")

const NODE_ELEMENT = 1
const NODE_ELEMENT_END = 2


## Reads every paint layer's keyframes file in the document.
## Returns { layer_filename: [{time: int, frame: String}] } sorted by
## time. Static layers (no keyframes attribute, missing file, or no
## parsable keys) are absent.
static func collect_keyframes(parser) -> Dictionary:
	var out := {}
	_collect_keyframes_recursive(parser, parser.get_layers(), out)
	return out


static func _collect_keyframes_recursive(parser, nodes: Array, out: Dictionary) -> void:
	for node in nodes:
		if node.nodetype == "paintlayer":
			var attr := str(node.get("keyframes", ""))
			if attr == "":
				continue
			var buf: PackedByteArray = parser.read_store_bytes(parser.get_keyframes_store_path(attr))
			if buf.is_empty():
				continue
			var keys := _parse_keyframes_xml(buf)
			if not keys.is_empty():
				out[str(node.filename)] = keys
		elif node.nodetype == "grouplayer":
			_collect_keyframes_recursive(parser, node.children, out)


## Parses a <doc>/layers/<name>.keyframes.xml buffer into a
## time-sorted Array of {time, frame}. Attribute order varies between
## files, so attributes are read by name. Only the "content" channel
## carries pixel keyframes; other channels are ignored.
static func _parse_keyframes_xml(buf: PackedByteArray) -> Array:
	var out := []
	var xp := XMLParser.new()
	if xp.open_buffer(buf) != OK:
		return out
	var in_content := false
	while true:
		if xp.read() != OK:
			break
		var node_type := xp.get_node_type()
		if node_type == NODE_ELEMENT:
			var node_name := xp.get_node_name()
			if node_name == "channel":
				in_content = xp.get_named_attribute_value("name") == "content"
			elif node_name == "keyframe" and in_content:
				var time_attr := xp.get_named_attribute_value("time")
				var frame_attr := xp.get_named_attribute_value("frame")
				if time_attr != "" and time_attr.is_valid_int() and frame_attr != "":
					out.push_back({"time": int(time_attr), "frame": frame_attr})
		elif node_type == NODE_ELEMENT_END:
			if xp.get_node_name() == "channel":
				in_content = false
		elif node_type == 0:
			break
	out.sort_custom(func(a, b): return int(a.time) < int(b.time))
	return out


## The tile file holding a layer's pixels at timeline frame `time`.
## Static layers (absent from kf_map) always use their base file.
static func active_frame(base_filename: String, keys: Array, time: int) -> String:
	if keys.is_empty():
		return base_filename
	var pick := str(keys[0].frame)
	for key in keys:
		if int(key.time) <= time:
			pick = str(key.frame)
		else:
			break
	return pick


## A top-level group becomes a clip unless it is @excluded, hidden
## (in only-visible mode), or matches the exclusion pattern. Mirrors
## the compositor's per-node inclusion with no ancestors.
static func is_clip_eligible(group: Dictionary, only_visible: bool, exception_pattern: String) -> bool:
	if layer_tags.parse_layer_name(str(group.get("name", ""))).exclude:
		return false
	if only_visible and not bool(group.get("visible", true)):
		return false
	if exception_pattern != "" and str(group.get("name", "")).match(exception_pattern):
		return false
	return true


## Computes the export clips for a document.
## Returns { clips: [{name, group (Dictionary or null), from, to}],
##             warnings: [String] }.
## opt_from/opt_to (< 0 = auto) clamp every clip; the auto range is the
## group's keyframe span, or the document range for the default clip.
static func compute_clips(parser, kf_map: Dictionary, only_visible: bool, exception_pattern: String, opt_from: int, opt_to: int) -> Dictionary:
	var doc_from: int = parser.get_anim_range_from()
	var doc_to: int = maxi(parser.get_anim_range_to(), doc_from)
	var lo := doc_from if opt_from < 0 else opt_from
	var hi := doc_to if opt_to < 0 else opt_to
	if lo > hi:
		var swap := lo
		lo = hi
		hi = swap

	var warnings := []
	var clips := []
	var top: Array = parser.get_layers()
	var eligible_groups := []
	for node in top:
		if node.nodetype == "grouplayer" and is_clip_eligible(node, only_visible, exception_pattern):
			eligible_groups.push_back(node)

	var used_names := {}
	if eligible_groups.is_empty():
		clips.push_back({"name": "default", "group": null, "from": lo, "to": hi})
	else:
		var index := 0
		for group in eligible_groups:
			index += 1
			var times := _collect_clip_times(group, kf_map)
			var f := 0
			var t := 0
			if not times.is_empty():
				f = times.min()
				t = times.max()
			f = clampi(f, lo, hi)
			t = clampi(t, lo, hi)
			if f > t:
				continue
			var base := str(layer_tags.parse_layer_name(str(group.get("name", ""))).clean_name).strip_edges()
			clips.push_back({
				"name": _unique_clip_name(base, index, used_names),
				"group": group,
				"from": f,
				"to": t,
			})
			if str(group.get("keyframes", "")) != "":
				warnings.push_back("Group '%s' has its own keyframes and is rendered static (animated groups are not supported)" % str(group.get("name", "?")))

	return {"clips": clips, "warnings": warnings}


## All keyframe times of a group's animated paint descendants.
static func _collect_clip_times(group: Dictionary, kf_map: Dictionary) -> Array:
	var times := []
	_collect_times_recursive(group.get("children", []), kf_map, times)
	return times


static func _collect_times_recursive(nodes: Array, kf_map: Dictionary, times: Array) -> void:
	for node in nodes:
		if node.nodetype == "paintlayer":
			if kf_map.has(str(node.filename)):
				for key in (kf_map[str(node.filename)] as Array):
					times.push_back(int(key.time))
		elif node.nodetype == "grouplayer":
			_collect_times_recursive(node.children, kf_map, times)


static func _unique_clip_name(base: String, index: int, used: Dictionary) -> String:
	var candidate := base.strip_edges()
	if candidate == "":
		candidate = "clip_%d" % index
	if not used.has(candidate):
		used[candidate] = true
		return candidate
	var counter := 1
	while used.has("%s_%d" % [candidate, counter]):
		counter += 1
	candidate = "%s_%d" % [candidate, counter]
	used[candidate] = true
	return candidate


## Timeline frames of one clip, honoring the frame step.
static func clip_frame_list(clip: Dictionary, step: int) -> Array:
	var out := []
	var s := maxi(1, step)
	var t := int(clip.from)
	while t <= int(clip.to):
		out.push_back(t)
		t += s
	return out


## Builds the layer tree (document order, like KraParser.get_layers())
## for one clip at one timeline frame: only the clip's group plus
## ungrouped layers survive, and every animated paint layer is a
## duplicate with `filename` swapped to its active keyframe file.
## Masks keep their own (static) filenames.
static func build_clip_nodes(parser, clip: Dictionary, time: int, kf_map: Dictionary) -> Array:
	var nodes := []
	var target = clip.group
	for node in parser.get_layers():
		if target != null and node.nodetype == "grouplayer" and str(node.filename) != str(target.filename):
			continue
		nodes.push_back(_materialize_node(node, time, kf_map))
	return nodes


static func _materialize_node(node: Dictionary, time: int, kf_map: Dictionary) -> Dictionary:
	var dup: Dictionary = node.duplicate(true)
	_swap_frames_recursive(dup, time, kf_map)
	return dup


static func _swap_frames_recursive(node: Dictionary, time: int, kf_map: Dictionary) -> void:
	if node.nodetype == "paintlayer":
		var filename := str(node.filename)
		if kf_map.has(filename):
			node.filename = active_frame(filename, kf_map[filename], time)
	elif node.nodetype == "grouplayer":
		for child in (node.children as Array):
			_swap_frames_recursive(child, time, kf_map)
