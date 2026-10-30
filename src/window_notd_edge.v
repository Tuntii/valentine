module main

import os
import pushpak_jaiswal.webview

fn C.valentine_maximize(hwnd voidptr)

// open_window shows the UI in Valentine's own WebView2 window and returns when it closes.
// Without the WebView2 runtime it falls back to an Edge app window.
fn open_window(url string, data_dir string) {
	// WebView2 keeps its profile next to the exe unless told otherwise.
	os.setenv('WEBVIEW2_USER_DATA_FOLDER', os.join_path(data_dir, 'webview2'), true)
	mut w := webview.create(debug: false)
	hwnd := w.get_window()
	if isnil(hwnd) {
		open_edge_window(url, data_dir)
		return
	}
	w.set_title('Valentine')
	w.set_size(1400, 900, .@none)
	C.valentine_maximize(hwnd)
	w.navigate(url)
	w.run()
	w.destroy()
}
