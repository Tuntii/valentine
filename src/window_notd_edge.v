module main

import os
import pushpak_jaiswal.webview

#include "@VMODROOT/src/window.h"

fn C.valentine_maximize(hwnd voidptr)
fn C.valentine_window_init(hwnd voidptr)
fn C.valentine_window_op(hwnd voidptr, op int)
fn C.valentine_window_zoomed(hwnd voidptr) int
fn C.valentine_set_controller(ctrl voidptr)
fn C.webview_get_native_handle(w C.webview_t, kind int) voidptr

// open_window shows the UI in Valentine's own WebView2 window and returns when it closes.
// Without the WebView2 runtime it falls back to an Edge app window.
// The WebView2 profile goes to %APPDATA%\<exe name> (fixed by the webview library).
fn open_window(url string, data_dir string) {
	// Hidden in the tray, the page goes invisible (see vw_visible) and Chromium would then
	// slow its timers to once a minute: ask_agent and run_command poll with timers.
	os.setenv('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
		'--disable-background-timer-throttling --disable-features=IntensiveWakeUpThrottling', true)
	mut w := webview.create(debug: $d('devtools', false)) // `-d devtools`: F12 opens DevTools
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
	// The UI calls this once at startup, which is how the window learns its controller.
	ctrl := C.webview_get_native_handle(e.instance, 2) // WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER
	// Bound functions run on a worker thread; ReleaseCapture must run on the window's.
	e.dispatch(fn [hwnd, op, ctrl] () {
		C.valentine_set_controller(ctrl)
		if op != 0 {
			C.valentine_window_op(hwnd, op)
		}
	})
	return C.valentine_window_zoomed(hwnd)
}
