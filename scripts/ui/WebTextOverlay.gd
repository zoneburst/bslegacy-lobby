extends Node
class_name WebTextOverlay
## A real browser text box laid over a Godot TextEdit in the web build
## (0.24.0, R-135), so pasting works everywhere: Ctrl+V, right-click "Paste",
## and long-press "Paste" on phones and tablets -- also inside the itch.io
## page, where Godot itself cannot read the clipboard.
##
##   WebTextOverlay.attach(edit)     # does nothing outside the browser
##
## The browser box follows the TextEdit on screen every frame, copies what
## is typed or pasted into edit.text as it changes, and disappears with the
## TextEdit. The TextEdit itself stays underneath (invisible) so the layout
## and the code that reads edit.text do not change.

var _edit: TextEdit
var _id := ""
var _cb: JavaScriptObject = null
var _last := ""


static func attach(edit: TextEdit) -> WebTextOverlay:
	if not OS.has_feature("web") or edit == null:
		return null
	var n := WebTextOverlay.new()
	n._edit = edit
	edit.add_child(n)
	return n


func _ready() -> void:
	_id = "bsl_ta_%d" % get_instance_id()
	# the Godot box must not take focus: in the browser a focused Godot text
	# box pulls the keyboard focus back to itself ten times a second
	_edit.focus_mode = Control.FOCUS_NONE
	_edit.release_focus()
	_edit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edit.modulate.a = 0.0
	_cb = JavaScriptBridge.create_callback(_on_input)
	var win: JavaScriptObject = JavaScriptBridge.get_interface("window")
	win.set("bslTa_" + _id, _cb)
	JavaScriptBridge.eval("""
(function (id, ph, val) {
  var t = document.createElement('textarea');
  t.id = id; t.placeholder = ph; t.value = val; t.spellcheck = false;
  t.setAttribute('autocomplete', 'off');
  var s = t.style;
  s.position = 'fixed'; s.zIndex = 20; s.boxSizing = 'border-box'; s.resize = 'none';
  s.margin = '0'; s.padding = '10px 12px'; s.borderRadius = '6px';
  s.background = '#0b1222'; s.color = '#e9eef8'; s.border = '1px solid #3a4a6b';
  s.font = '15px/1.45 system-ui, -apple-system, Segoe UI, sans-serif'; s.outline = 'none';
  s.left = '-9999px'; s.top = '0px'; s.width = '10px'; s.height = '10px';
  t.addEventListener('input', function () { var f = window['bslTa_' + id]; if (f) { f(t.value); } });
  t.addEventListener('focus', function () { s.borderColor = '#d8a636'; });
  t.addEventListener('blur', function () { s.borderColor = '#3a4a6b'; });
  document.body.appendChild(t);
  setTimeout(function () { t.focus(); }, 60);
})(%s, %s, %s);
""" % [JSON.stringify(_id), JSON.stringify(_edit.placeholder_text), JSON.stringify(_edit.text)], true)


func _process(_delta: float) -> void:
	if _edit == null or not is_instance_valid(_edit):
		return
	var shown := _edit.is_visible_in_tree()
	var vt := _edit.get_viewport().get_final_transform()
	var r := _edit.get_global_rect()
	var p := vt * r.position
	var q := vt * r.end
	var key := "%d|%.0f|%.0f|%.0f|%.0f|%.2f" % [int(shown), p.x, p.y, q.x, q.y, _alpha()]
	if key == _last:
		return
	_last = key
	JavaScriptBridge.eval("""
(function (id, x, y, w, h, show, a) {
  var t = document.getElementById(id); var c = document.querySelector('canvas');
  if (!t || !c) { return; }
  var b = c.getBoundingClientRect(); var rw = c.width / b.width; var rh = c.height / b.height;
  t.style.left = (x / rw + b.x) + 'px'; t.style.top = (y / rh + b.y) + 'px';
  t.style.width = (w / rw) + 'px'; t.style.height = (h / rh) + 'px';
  t.style.display = show ? 'block' : 'none'; t.style.opacity = a;
})(%s, %f, %f, %f, %f, %s, %f);
""" % [JSON.stringify(_id), p.x, p.y, q.x - p.x, q.y - p.y, "true" if shown else "false", _alpha()], true)


## the modal fades in and out; the browser box follows
func _alpha() -> float:
	var a := 1.0
	var n: Node = _edit.get_parent()
	while n != null:
		if n is CanvasItem:
			a *= (n as CanvasItem).modulate.a
		n = n.get_parent()
	return clampf(a, 0.0, 1.0)


func _on_input(args: Array) -> void:
	if args.is_empty() or _edit == null or not is_instance_valid(_edit):
		return
	_edit.text = str(args[0]).replace("\r\n", "\n")


func _exit_tree() -> void:
	JavaScriptBridge.eval("""
(function (id) { var t = document.getElementById(id); if (t) { t.remove(); }
  try { delete window['bslTa_' + id]; } catch (e) {} var c = document.querySelector('canvas'); if (c) { c.focus(); } })(%s);
""" % JSON.stringify(_id), true)
