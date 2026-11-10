extends RefCounted
class_name WebFilePicker
## Choosing a file from the player's computer in the web build (0.21.1).
##
## A browser game cannot open the computer's folders the way FileDialog does
## on the desktop. Instead the page shows the browser's own "open file"
## window (an <input type="file">); the chosen file is read in the page and
## handed to the game, which saves it under user:// -- in the web build that
## is the browser's own storage for this site (IndexedDB), on this computer
## only. Nothing is uploaded anywhere.
##
##   WebFilePicker.pick(".xlsx", func(path: String, file_name: String): ...)
##
## The page shows a small dialog with a "Choose file" button (browsers open
## their file window only for a click that lands on the page itself, which a
## click inside the game is not, reliably). The callback gets the user:// path
## the file was saved to, "" if it could not be read, or "" with an empty
## file name when the player pressed Cancel.

const JS_DEFINE := """
if (!window.bslPickFile) {
  window.bslPickFile = function (accept, title, cb) {
    var old = document.getElementById('bsl-pick'); if (old) old.remove();
    // A small dialog over the game with its own button: browsers open their
    // file window only for a click that lands on the page itself, so this
    // works everywhere (Safari included) however busy the game is.
    var box = document.createElement('div');
    box.id = 'bsl-pick';
    box.setAttribute('style', 'position:fixed;inset:0;display:flex;align-items:center;justify-content:center;' +
      'background:rgba(5,4,9,.62);z-index:9999;font-family:system-ui,sans-serif');
    box.innerHTML = '<div style="background:#16131f;border:2px solid #d8b25a;border-radius:16px;padding:26px 30px;' +
      'max-width:520px;color:#ece6d6;text-align:center;box-shadow:0 20px 60px rgba(0,0,0,.6)">' +
      '<div style="font-size:20px;font-weight:700;margin-bottom:10px" id="bsl-pick-title"></div>' +
      '<div style="font-size:14px;color:#b9b0c9;margin-bottom:18px">The file stays in this browser on this computer; it is not uploaded.</div>' +
      '<label id="bsl-pick-btn" style="display:inline-block;background:#d8b25a;color:#0a0910;font-weight:700;' +
      'padding:12px 26px;border-radius:10px;cursor:pointer;font-size:16px">Choose file<input id="bsl-file-input" type="file" ' +
      'style="display:none"></label>' +
      '<div><button id="bsl-pick-cancel" style="margin-top:14px;background:none;border:none;color:#b9b0c9;' +
      'font-size:14px;cursor:pointer;text-decoration:underline">Cancel</button></div></div>';
    document.body.appendChild(box);
    document.getElementById('bsl-pick-title').textContent = title;
    var i = document.getElementById('bsl-file-input');
    i.accept = accept;
    var done = function () { box.remove(); };
    document.getElementById('bsl-pick-cancel').onclick = function () { done(); cb('', ''); };
    i.onchange = function () {
      var f = i.files && i.files[0];
      if (!f) return;
      document.getElementById('bsl-pick-title').textContent = 'Reading ' + f.name + '…';
      var r = new FileReader();
      r.onload = function () {
        var b = new Uint8Array(r.result), s = '', CH = 0x8000;
        for (var k = 0; k < b.length; k += CH) {
          s += String.fromCharCode.apply(null, b.subarray(k, k + CH));
        }
        done();
        cb(f.name, btoa(s));
      };
      r.onerror = function () { done(); cb(f.name, ''); };
      r.readAsArrayBuffer(f);
    };
  };
}
"""

const INCOMING := "user://incoming"

## The JavaScript callback must stay referenced until it fires.
static var _pending: Array = []


static func available() -> bool:
	return OS.has_feature("web")


## Opens the browser's file window; `on_done(path, file_name)` runs when the
## file has been read and saved (path "" when reading failed).
static func pick(accept: String, on_done: Callable, title: String = "Choose a file") -> void:
	if not available():
		return
	JavaScriptBridge.eval(JS_DEFINE, true)
	var holder := {}
	var cb := JavaScriptBridge.create_callback(func(args: Array) -> void:
		_pending.erase(holder)
		var file_name := str(args[0]) if args.size() > 0 else "file"
		var b64 := str(args[1]) if args.size() > 1 else ""
		on_done.call(_save(file_name, b64), file_name))
	holder["cb"] = cb
	_pending.append(holder)
	var w: JavaScriptObject = JavaScriptBridge.get_interface("window")
	w.bslPickFile(accept, title, cb)


static func _save(file_name: String, b64: String) -> String:
	if b64.is_empty():
		return ""
	var bytes := Marshalls.base64_to_raw(b64)
	DirAccess.make_dir_recursive_absolute(INCOMING)
	var safe := file_name.get_file().replace("/", "_").replace("\\", "_")
	var path := INCOMING.path_join(safe if not safe.is_empty() else "file")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(bytes)
	f.close()
	return path
