module main

import pushpak_jaiswal.webview

#include "@VMODROOT/src/window.h"

fn C.valentine_maximize(hwnd voidptr)
fn C.valentine_window_init(hwnd voidptr)
fn C.valentine_window_op(hwnd voidptr, op int)
fn C.valentine_window_zoomed(hwnd voidptr) int

// open_window shows the UI in Valentine's own WebView2 window and returns when it closes.
// Without the WebView2 runtime it falls back to an Edge app window.
// The WebView2 profile goes to %APPDATA%\<exe name> (fixed by the webview library).
fn open_window(url string, data_dir string) {
	mut w := webview.create(debug: false)
	hwnd := w.get_window()
	if isnil(hwnd) {
		open_edge_window(url, data_dir)
		return
	}
	w.set_title('Valentine')
	w.set_size(1400, 900, .@none)
	C.valentine_window_init(hwnd)
	// The UI's title bar calls this; its presence tells the UI to draw window buttons.
	$if windows {
		w.bind_with_ctx[int]('valentine_window', window_op, hwnd)
	}
	C.valentine_maximize(hwnd)
	w.navigate(url)
	w.run()
	w.destroy()
}

// window_op runs a title-bar action (see valentine_window_op) and answers whether the
// window is maximized; op 0 only asks.
fn window_op(e &webview.Event, hwnd voidptr) int {
	op := e.get_arg[int](0) or { 0 }
	if op != 0 {
		// Bound functions run on a worker thread; ReleaseCapture must run on the window's.
		e.dispatch(fn [hwnd, op] () {
			C.valentine_window_op(hwnd, op)
		})
	}
	return C.valentine_window_zoomed(hwnd)
}
