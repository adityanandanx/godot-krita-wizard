@tool
extends EditorImportPlugin

##
## Static texture importer (Split By Layer).
## Imports a Krita document as one texture per paint layer: writes a
## `.kra_layer_tex` sidecar per layer plus a PackedDataContainer manifest.
## Each sidecar is then imported by the layer texture importer.
##

const result_codes = preload("../config/result_codes.gd")
const logger = preload("../config/logger.gd")
const KraParser = preload("../kra/kra_parser.gd")
const layer_tags = preload("../kra/layer_tags.gd")

var config = preload("../config/config.gd").new()

var file_system_helper


func _init(fs_helper = null) -> void:
	file_system_helper = fs_helper


func _get_importer_name():
	return "krita_wizard.plugin.static-texture-split"


func _get_visible_name():
	return "Krita Texture (Split By Layer)"


func _get_recognized_extensions():
	return ["kra"]


func _get_save_extension():
	return "res"


func _get_resource_type():
	return "PackedDataContainer"


func _get_preset_count():
	return 1


func _get_preset_name(i):
	return "Default"


func _get_priority():
	return 2.0 if config.get_default_importer() == config.IMPORTER_STATIC_TEXTURE_SPLIT_NAME else 1.0


func _get_import_order():
	return 1


func _get_import_options(_path, _i):
	return [
		{"name": "layer/exclude_layers_pattern", "default_value": config.get_default_exclusion_pattern()},
		{"name": "layer/only_visible_layers", "default_value": config.get_default_only_visible_layers()},
		{"name": "layer/merge_groups", "default_value": false},
		{"name": "sheet/trim", "default_value": false},
		{"name": "sheet/scale", "default_value": config.get_default_scale()},
		{
			"name": "texture/compression",
			"default_value": config.get_default_compression(),
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": "Lossless,VRAM - S3TC (Desktop),VRAM - BPTC (Desktop HQ),VRAM - ETC2 (Mobile),VRAM - ASTC (Mobile HQ)",
		},
		{"name": "texture/mipmaps", "default_value": config.get_default_mipmaps()},
		{
			"name": "output/layers_resources_folder",
			"default_value": "",
			"property_hint": PROPERTY_HINT_DIR,
		},
	]


func _get_option_visibility(path, option, options):
	return true


func _layer_extension() -> String:
	return "kra_layer_tex"


func _import(source_file, save_path, options, platform_variants, gen_files):
	var old_data = _load_old_data(source_file)

	var parser = KraParser.new()
	var open_result = parser.open(source_file)
	if not open_result.is_ok:
		parser.close()
		logger.error("Could not open Krita file: %s" % result_codes.get_error_message(open_result.code), source_file)
		return FAILED

	var exception_pattern: String = options.get("layer/exclude_layers_pattern", "")
	var only_visible: bool = options.get("layer/only_visible_layers", false)

	var jobs := []
	var merge_groups: bool = options.get("layer/merge_groups", false)
	# Parser lists top-level nodes top-first; the collector reverses each
	# level into paint order (bottom first) itself.
	_collect_split_jobs(parser.get_layers(), merge_groups, only_visible, exception_pattern, true, jobs)

	var layers_resources_folder: String = options.get("output/layers_resources_folder", "")
	if layers_resources_folder != "" and layers_resources_folder.is_relative_path():
		layers_resources_folder = source_file.get_base_dir().path_join(layers_resources_folder).simplify_path()

	var import_options := {
		"trim": options.get("sheet/trim", false),
		"scale": float(options.get("sheet/scale", 1.0)),
		"compression": int(options.get("texture/compression", config.get_default_compression())),
		"mipmaps": bool(options.get("texture/mipmaps", config.get_default_mipmaps())),
		"only_visible": only_visible,
		"exception_pattern": exception_pattern,
		"source": source_file,
	}

	var base_name = source_file.get_basename()
	if layers_resources_folder != "":
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(layers_resources_folder)):
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(layers_resources_folder))
		base_name = "%s/%s" % [layers_resources_folder, base_name.get_file()]

	# Sidecar file names are stable and human-readable: <doc>_<LayerName>.
	# No sequence numbers (renumbering on hide/show used to orphan files
	# and break attached texture references). Stems persist in the manifest
	# so genuine duplicates keep their suffixes across reimports.
	var stems := _assign_stems(jobs, old_data)

	var data_to_save := {"layers": {}}
	var current_paths := []

	for job in jobs:
		var node: Dictionary = job.node
		var node_filename: String = node.filename
		var manifest_key := "%s:%s" % [job.kind, node_filename]
		var stem: String = stems[manifest_key]
		var layer_save_path := "%s_%s.%s" % [base_name, stem, _layer_extension()]
		var tile_hash := parser.get_node_tile_hash(node)

		var sidecar_json := JSON.stringify({
			"kind": job.kind,
			"layer_filename": node_filename,
			"layer_name": str(node.name),
			"import_options": import_options,
			# Tile content hash: the ONLY thing that makes pixel edits
			# propagate. Godot reimports this sidecar (and only this one)
			# when these bytes change, since the file content changes.
			"tile_hash": tile_hash,
		})

		if _sidecar_up_to_date(layer_save_path, sidecar_json):
			# Nothing relevant changed (same options, same pixels):
			# keep the file untouched so its texture is NOT reimported.
			data_to_save.layers[manifest_key] = {"path": layer_save_path, "stem": stem}
			current_paths.push_back(layer_save_path)
			continue

		var file := FileAccess.open(layer_save_path, FileAccess.WRITE)
		if file == null:
			logger.error("Could not write layer file: %s" % layer_save_path, source_file)
			continue
		file.store_string(sidecar_json)
		file.close()
		data_to_save.layers[manifest_key] = {"path": layer_save_path, "stem": stem}
		current_paths.push_back(layer_save_path)

	parser.close()

	var packed := PackedDataContainer.new()
	packed.pack(data_to_save)

	var exit_code = ResourceSaver.save(packed, "%s.%s" % [save_path, _get_save_extension()])

	_cleanup_stale_sidecars(old_data, current_paths, base_name, source_file)

	if file_system_helper != null:
		file_system_helper.schedule_file_system_scan()

	return exit_code


## Assigns a stable filename stem per job key. Reuses the previously
## assigned stem when it still fits (same clean base, still unique),
## so renames/deletes elsewhere never reshuffle existing files.
func _assign_stems(jobs: Array, old_data: Dictionary) -> Dictionary:
	var old_stems := {}
	for key in old_data.keys():
		var entry := _normalize_entry(old_data[key])
		if not entry.is_empty() and entry.has("stem"):
			old_stems[key] = str(entry.stem)

	var taken := {}
	var result := {}
	for job in jobs:
		var node: Dictionary = job.node
		var manifest_key := "%s:%s" % [job.kind, str(node.filename)]
		var clean := _sanitize_layer_name(str(layer_tags.parse_layer_name(str(node.name)).clean_name))
		var stem := ""
		if old_stems.has(manifest_key):
			var prev: String = old_stems[manifest_key]
			if (prev == clean or prev.begins_with(clean + "_")) and not taken.has(prev):
				stem = prev
		if stem == "":
			stem = clean
			var counter := 0
			while taken.has(stem):
				counter += 1
				stem = "%s_%d" % [clean, counter]
		taken[stem] = true
		result[manifest_key] = stem
	return result


## Normalizes a manifest entry across formats: legacy entries are bare
## path strings, current ones are {path, stem, hash} dicts.
func _normalize_entry(value: Variant) -> Dictionary:
	if value is String:
		return {"path": value}
	if value is Dictionary:
		return value
	return {}


## True when the sidecar file exists with exactly this content.
func _sidecar_up_to_date(path: String, content: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var existing := file.get_as_text()
	file.close()
	return existing == content


func _should_include(layer: Dictionary, only_visible: bool, exception_pattern: String, ancestors_visible: bool = true) -> bool:
	if layer_tags.parse_layer_name(str(layer.name)).exclude:
		return false

	if only_visible:
		if not layer.visible or not ancestors_visible:
			return false
		# Paint copies from get_paint_layers carry the chain; tree nodes
		# rely on the ancestors_visible parameter instead.
		var parent = layer.get("parent_group")
		while parent != null:
			if not parent.visible:
				return false
			parent = parent.get("parent_group")

	if exception_pattern != "":
		if layer.name != null and str(layer.name).match(exception_pattern):
			return false

	return true


## Collects split jobs bottom-to-top, recursing into groups. A group
## becomes one merged job when the global merge_groups option is on or
## its name carries @merge (an explicit @merge=false/@nomerge forces
## expansion). @exclude on a group prunes its whole subtree; the name
## pattern only ever filters paint layers, never groups.
func _collect_split_jobs(nodes: Array, merge_groups: bool, only_visible: bool, exception_pattern: String, ancestors_visible: bool, jobs: Array) -> void:
	var ordered := nodes.duplicate()
	ordered.reverse()
	for node in ordered:
		if node.nodetype == "grouplayer":
			if layer_tags.parse_layer_name(str(node.name)).exclude:
				continue
			if only_visible and (not bool(node.visible) or not ancestors_visible):
				continue
			var tags: Dictionary = layer_tags.parse_layer_name(str(node.name))
			var do_merge := merge_groups
			if tags.merge != null:
				do_merge = bool(tags.merge)
			if do_merge:
				jobs.push_back({"kind": "group", "node": node})
			else:
				_collect_split_jobs(node.children, merge_groups, only_visible, exception_pattern, ancestors_visible and bool(node.visible), jobs)
		elif _should_include(node, only_visible, exception_pattern, ancestors_visible):
			jobs.push_back({"kind": "layer", "node": node})


func _sanitize_layer_name(layer_name: String) -> String:
	var out := layer_name.strip_edges().replace("/", "_").replace("\\", "_")
	while out.contains("  "):
		out = out.replace("  ", " ")
	out = out.replace(" ", "_")
	if out == "":
		out = "layer"
	return out


func _load_old_data(source_file: String):
	var old_data := {}

	if ResourceLoader.exists(source_file):
		var loaded = ResourceLoader.load(source_file)
		if loaded is PackedDataContainer:
			if loaded["layers"] != null:
				old_data = _packed_container_to_dictionary(loaded["layers"])

	return old_data


func _packed_container_to_dictionary(packed):
	var dic := {}
	for k in packed:
		if packed[k] is PackedDataContainerRef:
			dic[k] = _packed_container_to_dictionary(packed[k])
		else:
			dic[k] = packed[k]
	return dic


func _cleanup_stale_sidecars(old_data: Dictionary, current_paths: Array, base_name: String, source_file: String) -> void:
	var keep := {}
	for path in current_paths:
		keep[path] = true

	# 1. Entries the manifest knows about but this import dropped
	#    (deleted/renamed/excluded layers, naming migrations).
	for key in old_data.keys():
		var entry := _normalize_entry(old_data[key])
		if entry.is_empty() or not entry.has("path"):
			continue
		if not keep.has(entry.path):
			_remove_sidecar_files(str(entry.path), source_file)

	# 2. Directory reconciliation: our-namespace sidecars nobody claims.
	#    Heals orphans from crashed runs, older naming schemes (sequence
	#    numbers), or hand-deleted manifests. Only touches files matching
	#    <docstem>_*.kra_layer_tex in the sidecar/source directories.
	var doc_stem := base_name.get_file()
	var scan_dirs := {}
	scan_dirs[base_name.get_base_dir()] = true
	scan_dirs[source_file.get_base_dir()] = true
	for dir_path in scan_dirs.keys():
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.begins_with(doc_stem + "_") and file_name.ends_with("." + _layer_extension()):
				var full: String = dir_path.path_join(file_name)
				if not keep.has(full):
					_remove_sidecar_files(full, source_file)
			file_name = dir.get_next()
		dir.list_dir_end()


func _remove_sidecar_files(res_path: String, source_file: String) -> void:
	# Collect first: the sidecar's own .import file records where the
	# imported texture artifacts (.res/.md5) live.
	var doomed := [res_path, res_path + ".import"]
	var import_meta := res_path + ".import"
	if FileAccess.file_exists(import_meta):
		var cfg := ConfigFile.new()
		if cfg.load(import_meta) == OK and cfg.has_section_key("remap", "path"):
			var dest: String = cfg.get_value("remap", "path", "")
			if dest != "":
				doomed.push_back(dest)
				doomed.push_back(dest.get_basename() + ".md5")
	for candidate in doomed:
		if FileAccess.file_exists(candidate):
			var abs_path := ProjectSettings.globalize_path(candidate)
			if DirAccess.remove_absolute(abs_path) != OK:
				logger.warn("Could not remove stale file: %s" % candidate, source_file)