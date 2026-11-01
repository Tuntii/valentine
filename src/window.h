// Valentine's own window chrome and tray icon, on top of the webview library's window.
// The UI draws the title bar itself; this file drops the native caption (keeping the
// resize borders and Aero Snap), carries out the bar's buttons, and makes closing the
// window hide it to the tray. Quit from the tray menu really exits.
#ifndef VALENTINE_WINDOW_H
#define VALENTINE_WINDOW_H

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#include "conpty.h"
#define COBJMACROS
#include "WebView2.h" /* on the include path via the webview module */

#define VW_TRAY_MSG (WM_APP + 1)
#define VW_MENU_SHOW 1
#define VW_MENU_QUIT 2

static WNDPROC vw_prev;
static NOTIFYICONDATAW vw_nid;
static UINT vw_taskbar_created;
static int vw_quitting;
static ICoreWebView2Controller *vw_ctrl;

// vw_visible tells WebView2 whether it can be seen. The webview library never says it is
// hidden, so without this the page keeps rendering while it sits in the tray or minimized.
static void vw_visible(BOOL on) {
	if (vw_ctrl) ICoreWebView2Controller_put_IsVisible(vw_ctrl, on);
}

static void vw_show(HWND h) {
	ShowWindow(h, IsIconic(h) ? SW_RESTORE : SW_SHOW); // SW_SHOW keeps a hidden window maximized
	vw_visible(TRUE);
	SetForegroundWindow(h);
}

static void vw_quit(HWND h) {
	vw_quitting = 1;
	PostMessageW(h, WM_CLOSE, 0, 0);
}

static void vw_menu(HWND h) {
	HMENU menu = CreatePopupMenu();
	AppendMenuW(menu, MF_STRING, VW_MENU_SHOW, L"Show Valentine");
	AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
	AppendMenuW(menu, MF_STRING, VW_MENU_QUIT, L"Quit");
	SetForegroundWindow(h); // without it the menu stays open after clicking elsewhere
	POINT pt;
	GetCursorPos(&pt);
	int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, h, NULL);
	DestroyMenu(menu);
	if (cmd == VW_MENU_SHOW) vw_show(h);
	else if (cmd == VW_MENU_QUIT) vw_quit(h);
}

static LRESULT CALLBACK vw_proc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
	switch (m) {
	case WM_NCCALCSIZE:
		if (wp) {
			// Keep the side and bottom borders Windows computes; the client starts at the
			// window's top edge, where the UI draws its own bar.
			NCCALCSIZE_PARAMS *p = (NCCALCSIZE_PARAMS *)lp;
			LONG top = p->rgrc[0].top;
			LRESULT r = CallWindowProcW(vw_prev, h, m, wp, lp);
			p->rgrc[0].top = top;
			if (IsZoomed(h)) { // a maximized window overhangs the screen by its frame
				MONITORINFO mi = { sizeof(mi) };
				if (GetMonitorInfoW(MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST), &mi) && mi.rcWork.top > top)
					p->rgrc[0].top = mi.rcWork.top;
			}
			return r;
		}
		break;
	case WM_CLOSE:
		if (!vw_quitting) {
			ShowWindow(h, SW_HIDE);
			vw_visible(FALSE);
			return 0;
		}
		break;
	case WM_SIZE:
		vw_visible(wp != SIZE_MINIMIZED);
		break;
	case WM_DESTROY:
		Shell_NotifyIconW(NIM_DELETE, &vw_nid);
		break;
	case VALENTINE_SHOW_MSG:
		vw_show(h);
		return 0;
	case VW_TRAY_MSG:
		if (lp == WM_LBUTTONUP) vw_show(h);
		else if (lp == WM_RBUTTONUP) vw_menu(h);
		return 0;
	default:
		if (m == vw_taskbar_created && m) Shell_NotifyIconW(NIM_ADD, &vw_nid); // Explorer restarted
	}
	return CallWindowProcW(vw_prev, h, m, wp, lp);
}

// valentine_window_init takes over the webview window: own title bar, tray icon,
// close-to-tray. Call on the window's thread before it is shown.
static void valentine_window_init(void *hwnd) {
	HWND h = (HWND)hwnd;
	vw_prev = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)vw_proc);
	vw_taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
	vw_nid.cbSize = sizeof(vw_nid);
	vw_nid.hWnd = h;
	vw_nid.uID = 1;
	vw_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
	vw_nid.uCallbackMessage = VW_TRAY_MSG;
	// 32512 is the icon in assets/valentine.rc.
	vw_nid.hIcon = (HICON)LoadImageW(GetModuleHandleW(NULL), MAKEINTRESOURCEW(32512), IMAGE_ICON,
		GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
	wcscpy(vw_nid.szTip, L"Valentine");
	Shell_NotifyIconW(NIM_ADD, &vw_nid);
	SetWindowPos(h, NULL, 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

// valentine_window_op carries out a title-bar action from the UI, on the window's thread:
// 1 minimize, 2 maximize/restore, 3 close (to the tray), 4 drag, 5-7 resize from the
// top edge, top-left or top-right corner.
static void valentine_window_op(void *hwnd, int op) {
	HWND h = (HWND)hwnd;
	if (op == 1) ShowWindow(h, SW_MINIMIZE);
	else if (op == 2) ShowWindow(h, IsZoomed(h) ? SW_RESTORE : SW_MAXIMIZE);
	else if (op == 3) PostMessageW(h, WM_CLOSE, 0, 0);
	else if (op >= 4 && op <= 7) {
		// Hand the press to Windows' own move/size loop: Aero Snap and drag-to-restore work.
		static const WPARAM hit[] = { HTCAPTION, HTTOP, HTTOPLEFT, HTTOPRIGHT };
		POINT pt;
		GetCursorPos(&pt);
		ReleaseCapture();
		PostMessageW(h, WM_NCLBUTTONDOWN, hit[op - 4], MAKELPARAM(pt.x, pt.y));
	}
}

// valentine_set_controller hands over the ICoreWebView2Controller; call on the window's thread.
static void valentine_set_controller(void *ctrl) {
	vw_ctrl = (ICoreWebView2Controller *)ctrl;
}

static int valentine_window_zoomed(void *hwnd) {
	return IsZoomed((HWND)hwnd) != 0;
}

#else
// macOS and Linux keep the native title bar; the UI draws no window buttons there.
static void valentine_maximize(void *w) { (void)w; }
static void valentine_window_init(void *w) { (void)w; }
static void valentine_window_op(void *w, int op) { (void)w; (void)op; }
static int valentine_window_zoomed(void *w) { (void)w; return 0; }
static void valentine_set_controller(void *c) { (void)c; }
#endif

#endif
