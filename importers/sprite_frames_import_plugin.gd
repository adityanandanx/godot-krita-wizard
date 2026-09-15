@tool
extends EditorImportPlugin

##
## Animation importer.
## Imports a Krita document's timeline as a SpriteFrames resource: each
## top-level group becomes one named animation (its keyframe span, or a
## single frame when static); ungrouped layers are shared backdrop
## rendered into every animation. A document without top-level groups
## yields one "default" animation over the document range.
##
## Frames are composited with the regular group/mask/blend-aware
## compositor, packed into one PNG grid next to the source, imported
## through Godot's own texture pipeline, and referenced by the saved
## SpriteFrames via AtlasTexture regions. Drop the .res onto an
## AnimatedSprite2D to play it.
##

const result_codes = preload("../config/result_codes.gd")
const logger = preload("../config/logger.gd")
const KraParser = preload("../kra/kra_parser.gd")
const KraCompositor = preload("../kra/compositor.gd")
const animation = preload("../kra/animation.gd")

var config = preload("../config/config.gd").new()


func _get_importer_name():
	return "krita_wizard.plugin.sprite-frames"


func _get_visible_name():
	return "Krita Animation"


func _get_recognized_extensions():
	return ["kra"]


func _get_save_extension():
	return "res"


func _get_resource_type():
	return "SpriteFrames"


func _get_preset_count():
	return 1


func _get_preset_name(i):
	return "Default"


func _get_priority():
	return 2.0 if config.get_default_importer() == config.IMPORTER_ANIMATION_NAME else 1.0


func _get_import_order():
	return 1


func _get_import_options(_path, _i):
	return [
		{"name": "layer/exclude_layers_pattern", "default_value": config.get_default_exclusion_pattern()},
		{"name": "layer/only_visible_layers",    "default_value": config.get_default_only_visible_layers()},
		{"name": "sheet/trim", "default_value": false},
		{"name": "sheet/scale", "default_value": config.get_default_scale()},
		{"name": "sheet/sheet_columns", "default_value": 12},
		{"name": "animation/frame_range_from", "default_value": -1},
		{"name": "animation/frame_range_to", "default_value": -1},
		{"name": "animation/frame_step", "default_value": 1},
		{"name": "animation/loop", "default_value": true},
		{"name": "animation/round_fps", "default_value": true},
		{
			"name": "output/layers_resources_folder",
			"default_value": "",
			"property_hint": PROPERTY_HINT_DIR,
		},
	]


func _get_option_visibility(path, option, options):
	return true


func _import(source_file, save_path, options, platform_variants, gen_files):
	var parser = KraParser.new()
	var open_result = parser.open(source_file)
	if not open_result.is_ok:
		parser.close()
		logger.error("Could not open Krita file: %s" % result_codes.get_error_message(open_result.code), source_file)
		return FAILED

	var exception_pattern: String = options.get("layer/exclude_layers_pattern", "")
	var only_visible: bool = options.get("layer/only_visible_layers", false)
	var trim := bool(options.get("sheet/trim", false))
	var scale := maxf(0.01, float(options.get("sheet/scale", 1.0)))
	var columns := maxi(1, int(options.get("sheet/sheet_columns", 12)))
	var opt_from := int(options.get("animation/frame_range_from", -1))
	var opt_to := int(options.get("animation/frame_range_to", -1))
	var step := maxi(1, int(options.get("animation/frame_step", 1)))
	var loop := bool(options.get("animation/loop", true))
	var round_fps := bool(options.get("animation/round_fps", true))

	var output_folder: String = options.get("output/layers_resources_folder", "")
	if output_folder != "" and output_folder.is_relative_path():
		output_folder = source_file.get_base_dir().path_join(output_folder).simplify_path()
	if output_folder == "":
		output_folder = source_file.get_base_dir()
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(output_folder)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_folder))

	if not parser.has_animation_block():
		parser.close()
		logger.error("No animation in this Krita document: %s" % result_codes.get_error_message(result_codes.ERR_NOT_ANIMATED_DOCUMENT), source_file)
		return FAILED

	var kf_map := animation.collect_keyframes(parser)
	if kf_map.is_empty():
		parser.close()
		logger.error("No animated layers in this Krita document: %s" % result_codes.get_error_message(result_codes.ERR_NOT_ANIMATED_DOCUMENT), source_file)
		return FAILED

	var computed := animation.compute_clips(parser, kf_map, only_visible, exception_pattern, opt_from, opt_to)
	for warning in (computed.warnings as Array):
		logger.warn(str(warning), source_file)
	var clips: Array = computed.clips
	if clips.is_empty():
		parser.close()
		logger.error("No animation clips found (all groups excluded or out of range)", source_file)
		return FAILED

	var doc_stem: String = source_file.get_file().get_basename()
	var width: int = parser.get_width()
	var height: int = parser.get_height()
	var fps := float(parser.get_framerate())
	if round_fps:
		fps = ceili(fps)
	fps = maxf(1.0, fps)

	var compositor = KraCompositor.new()
	var compose_opts := {
		"only_visible": only_visible,
		"exception_pattern": exception_pattern,
		"trim": false,
		"scale": 1.0,
	}

	# Frame size: full canvas, or the content union across every clip
	# when trimming (so sprites never jitter). The union needs a bounds
	# pre-pass; untrimmed frames stream straight into the sheet.
	var union := Rect2i(0, 0, 0, 0)
	var union_found := false
	if trim:
		for clip in clips:
			for t in animation.clip_frame_list(clip, step):
				var nodes := animation.build_clip_nodes(parser, clip, t, kf_map)
				var bounds_result := compositor.compose_animation_frame(parser, nodes, compose_opts)
				if not bounds_result.is_ok:
					continue
				var used: Rect2i = bounds_result.content.used_rect
				if used.size.x <= 0 or used.size.y <= 0:
					continue
				union = used if not union_found else union.merge(used)
				union_found = true
		if not union_found:
			parser.close()
			logger.error("No animation content found: %s" % result_codes.get_error_message(result_codes.ERR_NO_VALID_LAYERS_FOUND), source_file)
			return FAILED

	var fw := maxi(1, int((union.size.x if trim else width) * scale + 0.5))
	var fh := maxi(1, int((union.size.y if trim else height) * scale + 0.5))

	var total := 0
	var clip_frames := []
	for clip in clips:
		var frames := animation.clip_frame_list(clip, step)
		clip_frames.push_back(frames)
		total += frames.size()

	# The packed grid must fit inside the GLES3 texture size limit
	# (16384 px per side), otherwise texture creation fails and every
	# frame renders black. The user's columns value caps the width;
	# when it would overflow we first widen the grid (more columns,
	# fewer rows) and then shrink to the width cap. Full-canvas frames
	# of a wide document can still exceed the limit — those error out
	# with a hint (trim or a smaller range fixes it).
	const MAX_TEXTURE_SIDE := 16384
	if fw > MAX_TEXTURE_SIDE or fh > MAX_TEXTURE_SIDE:
		parser.close()
		logger.error("Frame size %dx%d exceeds the %d px texture limit; use a scale below 1" % [fw, fh, MAX_TEXTURE_SIDE], source_file)
		return FAILED
	var max_cols := maxi(1, MAX_TEXTURE_SIDE / fw)
	var min_cols := maxi(1, ceili(float(total) * float(fh) / float(MAX_TEXTURE_SIDE)))
	if min_cols > max_cols:
		parser.close()
		logger.error("Animation sheet would exceed the %d px texture limit (%d frames at %dx%d); enable trim, lower the resolution/scale, or reduce the frame range/step" % [MAX_TEXTURE_SIDE, total, fw, fh], source_file)
		return FAILED
	var eff_columns := clampi(columns, min_cols, max_cols)
	var rows := maxi(1, ceili(float(total) / float(eff_columns)))
	if eff_columns * fw > MAX_TEXTURE_SIDE or rows * fh > MAX_TEXTURE_SIDE:
		parser.close()
		logger.error("Animation sheet would exceed the %d px texture limit (grid %dx%d for %d frames at %dx%d); enable trim or reduce the frame range/step" % [MAX_TEXTURE_SIDE, eff_columns * fw, rows * fh, total, fw, fh], source_file)
		return FAILED
	var sheet := Image.create_empty(eff_columns * fw, rows * fh, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))

	var sprite_frames := SpriteFrames.new()
	sprite_frames.remove_animation("default")
	sprite_frames.set_meta("imported_via_kw", true)

	var cell := 0
	var packed := []  # [{clip: int, cell: int}] in pack order
	var packed_per_clip := []
	for i in range(clips.size()):
		packed_per_clip.push_back(0)
		var clip: Dictionary = clips[i]
		sprite_frames.add_animation(str(clip.name))
		sprite_frames.set_animation_loop(str(clip.name), loop)
		sprite_frames.set_animation_speed(str(clip.name), fps)
		for t in (clip_frames[i] as Array):
			var nodes := animation.build_clip_nodes(parser, clip, int(t), kf_map)
			var frame_result := compositor.compose_animation_frame(parser, nodes, compose_opts)
			if not frame_result.is_ok:
				logger.warn("Skipping frame %d of '%s': %s" % [int(t), str(clip.name), result_codes.get_error_message(frame_result.code)], source_file)
				cell += 1
				continue
			var frame: Image = _finalize_frame(frame_result.content.image, union, trim, scale)
			sheet.blit_rect(frame, Rect2i(0, 0, fw, fh), Vector2i((cell % eff_columns) * fw, (cell / eff_columns) * fh))
			packed.push_back({"clip": i, "cell": cell})
			packed_per_clip[i] = int(packed_per_clip[i]) + 1
			cell += 1
	for i in range(clips.size()):
		if int(packed_per_clip[i]) == 0:
			sprite_frames.remove_animation(str(clips[i].name))
			logger.warn("Animation '%s' has no renderable frames, skipped" % str(clips[i].name), source_file)

	parser.close()

	if sprite_frames.get_animation_names().is_empty():
		logger.error("No animation frames could be rendered", source_file)
		return FAILED

	var png_path := "%s/%s_animation.png" % [output_folder, doc_stem]
	if not _write_png_if_changed(sheet, png_path, source_file):
		return FAILED

	# The filesystem cache doesn't know about the just-written file
	# yet; refresh it so the external import below can find it.
	EditorInterface.get_resource_filesystem().update_file(png_path)
	if append_import_external_resource(png_path) != OK:
		logger.error("Could not import generated PNG: %s" % png_path, source_file)
		return FAILED
	gen_files.push_back(png_path)

	var texture: Texture2D = ResourceLoader.load(png_path)
	if texture == null:
		logger.error("Could not load generated PNG: %s" % png_path, source_file)
		return FAILED

	# Second pass: attach the packed texture to every kept frame.
	# Skipped frames left blank cells behind and stay out.
	for entry in packed:
		var clip: Dictionary = clips[int(entry.clip)]
		if not sprite_frames.has_animation(str(clip.name)):
			continue
		var packed_cell := int(entry.cell)
		var atlas := AtlasTexture.new()
		atlas.atlas = texture
		atlas.region = Rect2i((packed_cell % eff_columns) * fw, (packed_cell / eff_columns) * fh, fw, fh)
		sprite_frames.add_frame(str(clip.name), atlas, 1.0)

	var resource_path := "%s.%s" % [save_path, _get_save_extension()]
	var exit_code = ResourceSaver.save(sprite_frames, resource_path)
	sprite_frames.take_over_path(resource_path)
	ResourceLoader.load(resource_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	if exit_code != OK:
		logger.error("Could not persist animation: %s" % result_codes.get_error_message(exit_code), source_file)
		return FAILED

	return OK


## Crops to the clip union (trim) and applies the scale factor with
## the same interpolation rules as the static compositor.
func _finalize_frame(image: Image, union: Rect2i, do_trim: bool, scale: float) -> Image:
	var out := image
	if do_trim:
		out = image.get_region(union)
	if not is_equal_approx(scale, 1.0):
		var new_width := maxi(1, int(out.get_width() * scale + 0.5))
		var new_height := maxi(1, int(out.get_height() * scale + 0.5))
		var interpolation := Image.INTERPOLATE_NEAREST if scale > 1.0 else Image.INTERPOLATE_BILINEAR
		out.resize(new_width, new_height, interpolation)
	return out


## Writes the PNG only when bytes differ, so untouched animations
## don't trigger texture reimports downstream.
func _write_png_if_changed(image: Image, png_path: String, source_file: String) -> bool:
	var buffer := image.save_png_to_buffer()
	if buffer.is_empty():
		logger.error("Could not encode PNG: %s" % png_path, source_file)
		return false
	if FileAccess.file_exists(png_path):
		var existing := FileAccess.open(png_path, FileAccess.READ)
		if existing != null:
			var same := existing.get_buffer(existing.get_length()) == buffer
			existing.close()
			if same:
				return true
	var out := FileAccess.open(png_path, FileAccess.WRITE)
	if out == null:
		logger.error("Could not write PNG: %s" % png_path, source_file)
		return false
	out.store_buffer(buffer)
	out.close()
	return true
