extends TextureRect
class_name SharpCardArt
## A card face drawn at the exact size it takes on screen (0.24.0, R-154).
##
## Every card picture is the lossless bssdb.dev picture (about 600 x 838).
## Drawn smaller than that by the GPU it is filtered -- with mipmaps it is
## blended with a half-size copy and the card text goes soft. So once the
## card takes `MIN_SHARP_PX` screen pixels or more, the face is resampled
## ONCE, with Lanczos, to exactly the pixels it covers (window scaling
## included) and drawn 1:1. Smaller cards keep the mipmapped picture.
##
## In the browser build the full pictures are fetched per set when first
## needed (CardDB); until then the bundled small picture is shown.

const MIN_SHARP_PX := 140.0

var card_id := ""
var _base: Texture2D = null
var _key := ""


func _ready() -> void:
	resized.connect(_update)
	visibility_changed.connect(_update)
	get_viewport().size_changed.connect(_update)
	CardDB.full_art_ready.connect(_on_full_art)


## Show card `id` (an empty id clears the sharp copy: a card back, say).
func show_card(id: String, base: Texture2D) -> void:
	card_id = id
	_base = base
	_key = ""
	texture = base
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_update.call_deferred()


func _on_full_art(id: String) -> void:
	if id == card_id:
		_key = ""
		_update()


func _update() -> void:
	if card_id == "" or _base == null or not is_inside_tree() or not is_visible_in_tree():
		return
	var px := _screen_px()
	if px.x < MIN_SHARP_PX:
		if texture != _base:
			texture = _base
			texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_key = ""
		return
	var want := Vector2i(roundi(px.x), roundi(px.y))
	var k := "%s@%dx%d" % [card_id, want.x, want.y]
	if k == _key:
		return
	var sharp := CardDB.sharp_texture(card_id, want)
	if sharp == null:
		return                       # not here yet (browser): full_art_ready retries
	_key = k
	texture = sharp
	# exactly screen-sized: drawn texel for pixel. Linear filtering would
	# blend neighbours wherever the card sits at a fractional pixel position
	# (most places, with window scaling) and soften it again.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


## The picture's size on screen, in real pixels: the fitted rectangle times
## the canvas and window scale.
func _screen_px() -> Vector2:
	var tw := float(_base.get_width())
	var th := float(_base.get_height())
	if tw <= 0.0 or th <= 0.0 or size.x <= 0.0 or size.y <= 0.0:
		return Vector2.ZERO
	var f := 1.0
	if stretch_mode == STRETCH_KEEP_ASPECT_COVERED:
		f = maxf(size.x / tw, size.y / th)
	else:
		f = minf(size.x / tw, size.y / th)
	var xf := get_viewport().get_final_transform() * get_global_transform_with_canvas()
	var s := xf.get_scale().abs()
	return Vector2(tw * f * s.x, th * f * s.y)
