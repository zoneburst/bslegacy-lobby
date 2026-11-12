extends Node
## Pasting text in the browser build (0.24.0, R-135).
##
## Godot's web build cannot paste inside an itch.io page. Its key handler
## swallows Ctrl+V (it calls preventDefault, so the browser never pastes), and
## its own clipboard read (navigator.clipboard.readText) is refused inside an
## iframe that was not given "clipboard-read" -- which is how itch.io embeds
## games. Both Ctrl+V and the right-click "Paste" did nothing (the decklist
## import in the 0.23.1 video).
##
## The fix uses the browser's ordinary paste, which needs no permission:
##   * a capture listener lets Ctrl+V / Cmd+V / Shift+Insert through to the
##     browser instead of Godot, so the browser fires a "paste" event;
##   * the "paste" listener hands the text to the game, which types it into
##     whatever text box has focus;
##   * long text boxes (the decklist import) get a real browser text box laid
##     over them (WebTextOverlay), so right-click Paste and paste on phones
##     work too.
## On the desktop none of this runs.

signal pasted(text: String)

var _cb: JavaScriptObject = null


func _ready() -> void:
	if not OS.has_feature("web"):
		return
	_cb = JavaScriptBridge.create_callback(_on_paste)
	var win: JavaScriptObject = JavaScriptBridge.get_interface("window")
	if win == null:
		return
	win.set("bslOnPaste", _cb)
	JavaScriptBridge.eval("""
(function () {
  if (window.__bslPaste) { return; }
  window.__bslPaste = true;
  function ours(el) { return el && (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT'); }
  window.addEventListener('keydown', function (e) {
    var isV = (e.code === 'KeyV' || e.key === 'v' || e.key === 'V');
    var paste = (isV && (e.ctrlKey || e.metaKey) && !e.altKey) || (e.key === 'Insert' && e.shiftKey);
    if (!paste || ours(document.activeElement)) { return; }
    // keep the keys away from Godot, which would cancel the browser's paste
    e.stopImmediatePropagation();
  }, true);
  document.addEventListener('paste', function (e) {
    if (ours(document.activeElement)) { return; }
    var data = e.clipboardData || window.clipboardData;
    var text = data ? data.getData('text') : '';
    e.preventDefault();
    if (text && window.bslOnPaste) { window.bslOnPaste(text); }
  }, true);
})();
""", true)


func _on_paste(args: Array) -> void:
	if args.is_empty():
		return
	var text := str(args[0]).replace("\r\n", "\n").replace("\r", "\n")
	paste_into_focus(text)


## Types `text` into the focused text box (also used by the tests).
func paste_into_focus(text: String) -> void:
	var f := get_viewport().gui_get_focus_owner()
	if f is TextEdit and (f as TextEdit).editable:
		(f as TextEdit).insert_text_at_caret(text)
	elif f is LineEdit and (f as LineEdit).editable:
		(f as LineEdit).insert_text_at_caret(text.replace("\n", " ").strip_edges())
	pasted.emit(text)
