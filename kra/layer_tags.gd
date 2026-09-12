@tool
extends RefCounted

##
## Per-layer naming conventions.
##
## Special `@tag` tokens (whitespace-separated) inside a layer name
## override export options for that layer:
##
##    Hero@scale=0.5 @trim=false
##    Background @notrim
##    Sketch @exclude
##
## Supported tags (key matching is case-insensitive):
##    @trim=true|false|yes|no|on|off|1|0   - trim to content for this layer
##    @notrim                               - shorthand for @trim=false
##    @scale=<float>                        - resize factor, e.g. @scale=0.5
##    @exclude / @ignore                    - skip this layer entirely
##    @merge / @merge=true...               - merge this group into one file
##    @nomerge / @merge=false...            - never merge this group
##
## Tokens that do not match a known tag are left untouched. trim/scale
## tags only affect per-layer outputs (split import, wizard split export);
## in merged outputs they are ignored, while @exclude always applies.
## @merge/@nomerge only affect groups in split contexts; on paint layers
## they are ignored. A @merge tag defaults the wizard's Merge checkbox
## on (the checkbox still wins), and forces a merge in the split
## importer even when merge_groups is off (and vice versa).
##

const TAG_PREFIX = "@"


## Parses a layer name into export overrides.
## Returns { trim: Variant (bool or null), scale: Variant (float or null),
##             exclude: bool, merge: Variant (bool or null),
##             clean_name: String, tags: Array }
## A null trim/scale/merge means "no override, use the global option".
static func parse_layer_name(layer_name: String) -> Dictionary:
	var result := {
		"trim": null,
		"scale": null,
		"exclude": false,
		"merge": null,
		"clean_name": layer_name,
		"tags": [],
	}

	var kept_tokens := PackedStringArray()
	for token in layer_name.split(" ", false):
		var parsed = _parse_token(token)
		if parsed == null:
			kept_tokens.push_back(token)
			continue
		result.tags.push_back(token)
		match parsed[0]:
			"trim":
				result.trim = parsed[1]
			"scale":
				result.scale = parsed[1]
			"exclude":
				result.exclude = true
			"merge":
				result.merge = parsed[1]

	result.clean_name = " ".join(kept_tokens).strip_edges()
	if result.clean_name == "":
		result.clean_name = layer_name.strip_edges()

	return result


## Parses one @token into [kind, value] or null when it is not a tag.
static func _parse_token(token: String) -> Variant:
	if not token.begins_with(TAG_PREFIX) or token.length() < 2:
		return null

	var body := token.substr(1)
	var key := body
	var value := ""
	var eq := body.find("=")
	if eq >= 0:
		key = body.left(eq)
		value = body.substr(eq + 1)

	match key.to_lower():
		"trim":
			if value == "":
				return ["trim", true]
			return ["trim", _parse_bool(value)]
		"notrim":
			return ["trim", false]
		"scale":
			if not _is_valid_float(value):
				return null
			return ["scale", float(value)]
		"merge":
			if value == "":
				return ["merge", true]
			return ["merge", _parse_bool(value)]
		"nomerge":
			return ["merge", false]
		"exclude", "ignore":
			return ["exclude", true]
		_:
			return null


static func _parse_bool(value: String) -> Variant:
	match value.to_lower():
		"true", "yes", "on", "1":
			return true
		"false", "no", "off", "0":
			return false
		_:
			return null


static func _is_valid_float(value: String) -> bool:
	if value == "":
		return false
	return value.is_valid_float()