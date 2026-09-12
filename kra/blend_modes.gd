@tool
extends RefCounted

##
## Krita compositeop (blend mode) math on straight RGBA.
##
## IDs match Krita's KoCompositeOpRegistry (e.g. "multiply", "screen",
## "overlay", "soft_light"). Only "normal" is handled natively by the
## compositor; every mode here is evaluated per-pixel for layers that
## opt out of the fast path.
##
## Formulas are the standard SDR definitions applied per channel to
## straight (non-premultiplied) colors, then composited with rounded
## source-over using the effective source alpha. This matches Krita's
## projection closely (integer rounding may differ by ~1 level).
##
## Modes Krita offers that are NOT implemented fall back to "normal"
## (with a one-time warning per id): penumbra/interpolation/hard-mix
## family, IFS-illusion variants, color spaces ops (hue/saturation/...),
## arithmetic exotica (arc_tangent, modulo, ...), and Porter-Duff extras
## beyond behind/erase.
##

const MODE_NORMAL = "normal"

const _SUPPORTED := [
	"normal",
	"multiply",
	"screen",
	"overlay",
	"hard_light",
	"soft_light",
	"darken",
	"lighten",
	"dodge",
	"burn",
	"add",
	"linear_dodge",
	"subtract",
	"divide",
	"diff",
	"exclusion",
	"behind",
	"erase",
]


static func is_supported(mode_id: String) -> bool:
	return mode_id in _SUPPORTED


static func normalize_mode(mode_id: String) -> String:
	var mode := mode_id.strip_edges().to_lower()
	if mode == "" or mode == "over":
		return MODE_NORMAL
	if mode in _SUPPORTED:
		return mode
	return ""


## Blends one channel pair. s = source/top, d = destination/bottom,
## both 0..255 ints. Returns the blended channel as float 0..1.
static func blend_channel(mode_id: String, s: int, d: int) -> float:
	var fs := float(s) / 255.0
	var fd := float(d) / 255.0

	match mode_id:
		"multiply":
			return fs * fd
		"screen":
			return 1.0 - (1.0 - fs) * (1.0 - fd)
		"overlay":
			if fd <= 0.5:
				return 2.0 * fs * fd
			return 1.0 - 2.0 * (1.0 - fs) * (1.0 - fd)
		"hard_light":
			if fs <= 0.5:
				return 2.0 * fs * fd
			return 1.0 - 2.0 * (1.0 - fs) * (1.0 - fd)
		"soft_light":
			if fs <= 0.5:
				return fd - (1.0 - 2.0 * fs) * fd * (1.0 - fd)
			return fd + (2.0 * fs - 1.0) * (sqrt(maxf(fd, 0.0)) - fd)
		"darken":
			return minf(fs, fd)
		"lighten":
			return maxf(fs, fd)
		"dodge":
			if fs >= 1.0:
				return 1.0
			return minf(1.0, fd / (1.0 - fs))
		"burn":
			if fs <= 0.0:
				return 0.0
			return 1.0 - minf(1.0, (1.0 - fd) / fs)
		"add", "linear_dodge":
			return minf(1.0, fs + fd)
		"subtract":
			return maxf(0.0, fd - fs)
		"divide":
			if fs <= 0.0:
				return 1.0
			return minf(1.0, fd / fs)
		"diff":
			return absf(fd - fs)
		"exclusion":
			return fs + fd - 2.0 * fs * fd
		_:
			return fs


## Full source-over composite of one straight-RGBA pixel pair with an
## explicit blend mode. Writes the result into canvas at dst_offset.
## The normal mode uses pure integer math (identical to the verified
## normal path); other modes evaluate the blend in float. Rounding may
## differ from Krita's integer pipeline by ~1 level.
static func blend_pixel(canvas: PackedByteArray, dst_offset: int, src_buf: PackedByteArray, src_offset: int, src_a: int, mode_id: String) -> void:
	if mode_id == "behind":
		_blend_behind(canvas, dst_offset, src_buf, src_offset, src_a)
		return

	if mode_id == "erase":
		_blend_erase(canvas, dst_offset, src_a)
		return

	if mode_id == "normal":
		_blend_normal(canvas, dst_offset, src_buf, src_offset, src_a)
		return

	var src_r := src_buf[src_offset]
	var src_g := src_buf[src_offset + 1]
	var src_b := src_buf[src_offset + 2]

	var dst_a := canvas[dst_offset + 3]
	if dst_a == 0:
		canvas[dst_offset] = src_r
		canvas[dst_offset + 1] = src_g
		canvas[dst_offset + 2] = src_b
		canvas[dst_offset + 3] = src_a
		return

	var dst_r := canvas[dst_offset]
	var dst_g := canvas[dst_offset + 1]
	var dst_b := canvas[dst_offset + 2]

	var inv_a := 255 - src_a
	var out_a := src_a + int((dst_a * inv_a + 127) / 255)
	if out_a == 0:
		canvas[dst_offset] = 0
		canvas[dst_offset + 1] = 0
		canvas[dst_offset + 2] = 0
		canvas[dst_offset + 3] = 0
		return

	# out_c = (B_c * sa + D_c * da * (1-sa)) / out_a, B in 0..255 float.
	var out_r := mini(255, int((blend_channel(mode_id, src_r, dst_r) * 255.0 * float(src_a) + float(dst_r * dst_a * inv_a) / 255.0 + float(out_a) * 0.5) / float(out_a)))
	var out_g := mini(255, int((blend_channel(mode_id, src_g, dst_g) * 255.0 * float(src_a) + float(dst_g * dst_a * inv_a) / 255.0 + float(out_a) * 0.5) / float(out_a)))
	var out_b := mini(255, int((blend_channel(mode_id, src_b, dst_b) * 255.0 * float(src_a) + float(dst_b * dst_a * inv_a) / 255.0 + float(out_a) * 0.5) / float(out_a)))

	canvas[dst_offset] = out_r
	canvas[dst_offset + 1] = out_g
	canvas[dst_offset + 2] = out_b
	canvas[dst_offset + 3] = out_a


## Integer normal blend. Bit-identical to the verified normal path.
static func _blend_normal(canvas: PackedByteArray, dst_offset: int, src_buf: PackedByteArray, src_offset: int, src_a: int) -> void:
	var src_r := src_buf[src_offset]
	var src_g := src_buf[src_offset + 1]
	var src_b := src_buf[src_offset + 2]

	var dst_a := canvas[dst_offset + 3]
	if dst_a == 0:
		canvas[dst_offset] = src_r
		canvas[dst_offset + 1] = src_g
		canvas[dst_offset + 2] = src_b
		canvas[dst_offset + 3] = src_a
		return

	var inv_a := 255 - src_a
	var out_a := src_a + int((dst_a * inv_a + 127) / 255)
	if out_a == 0:
		canvas[dst_offset] = 0
		canvas[dst_offset + 1] = 0
		canvas[dst_offset + 2] = 0
		canvas[dst_offset + 3] = 0
		return

	var dst_r := int(src_r * src_a + (canvas[dst_offset] * dst_a * inv_a + 127) / 255)
	var dst_g := int(src_g * src_a + (canvas[dst_offset + 1] * dst_a * inv_a + 127) / 255)
	var dst_b := int(src_b * src_a + (canvas[dst_offset + 2] * dst_a * inv_a + 127) / 255)

	canvas[dst_offset] = int((dst_r + out_a / 2) / out_a)
	canvas[dst_offset + 1] = int((dst_g + out_a / 2) / out_a)
	canvas[dst_offset + 2] = int((dst_b + out_a / 2) / out_a)
	canvas[dst_offset + 3] = out_a


## Porter-Duff "behind": source shows only through transparent dst.
static func _blend_behind(canvas: PackedByteArray, dst_offset: int, src_buf: PackedByteArray, src_offset: int, src_a: int) -> void:
	var dst_a := canvas[dst_offset + 3]
	if dst_a >= 255:
		return

	var inv_da := 255 - dst_a
	var out_a := dst_a + int((src_a * inv_da + 127) / 255)
	if out_a == 0:
		return
	var dst_r := int(canvas[dst_offset] * dst_a + (src_buf[src_offset] * src_a * inv_da + 127) / 255)
	var dst_g := int(canvas[dst_offset + 1] * dst_a + (src_buf[src_offset + 1] * src_a * inv_da + 127) / 255)
	var dst_b := int(canvas[dst_offset + 2] * dst_a + (src_buf[src_offset + 2] * src_a * inv_da + 127) / 255)

	canvas[dst_offset] = int((dst_r + out_a / 2) / out_a)
	canvas[dst_offset + 1] = int((dst_g + out_a / 2) / out_a)
	canvas[dst_offset + 2] = int((dst_b + out_a / 2) / out_a)
	canvas[dst_offset + 3] = out_a


## Erase: source alpha cuts destination alpha, RGB untouched.
static func _blend_erase(canvas: PackedByteArray, dst_offset: int, src_a: int) -> void:
	var dst_a := canvas[dst_offset + 3]
	if dst_a == 0 or src_a == 0:
		return
	canvas[dst_offset + 3] = int((dst_a * (255 - src_a) + 127) / 255)