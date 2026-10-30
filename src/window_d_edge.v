module main

// Built with `-d edge`: no WebView2 binding needed, the UI opens in Edge's app mode.
fn open_window(url string, data_dir string) {
	open_edge_window(url, data_dir)
}
