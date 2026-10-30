// Thin Win32 shim for ConPTY. The pseudo-console and proc-thread-attribute APIs are
// resolved at runtime, so the build does not depend on how complete the C compiler's
// Windows headers are (tcc and older mingw lack the ConPTY declarations).
//
// The pseudo console comes from conpty.dll next to the exe when it is there (Microsoft's
// current ConPTY, the one Windows Terminal and VS Code ship; it runs OpenConsole.exe from
// the same folder), else from kernel32. Windows 10's built-in ConPTY is years behind and
// garbles TUIs such as Claude Code: stray cursors, repeated or misplaced redraws.
#ifndef VALENTINE_CONPTY_H
#define VALENTINE_CONPTY_H

#include <windows.h>
#include <string.h>
#include <wchar.h>

#define VALENTINE_EXTENDED_STARTUPINFO_PRESENT 0x00080000
#define VALENTINE_ATTR_PSEUDOCONSOLE 0x00020016
// ConPTY asks the terminal for its cursor (DSR) and starts drawing there, so restored
// scrollback above the cursor is not overwritten by the new session's first frame.
#define VALENTINE_PSEUDOCONSOLE_INHERIT_CURSOR 0x1

typedef HRESULT (WINAPI *valentine_create_pc_t)(COORD, HANDLE, HANDLE, DWORD, void **);
typedef HRESULT (WINAPI *valentine_resize_pc_t)(void *, COORD);
typedef void (WINAPI *valentine_close_pc_t)(void *);
typedef BOOL (WINAPI *valentine_init_attr_t)(void *, DWORD, DWORD, SIZE_T *);
typedef BOOL (WINAPI *valentine_update_attr_t)(void *, DWORD, DWORD_PTR, void *, SIZE_T, void *, SIZE_T *);
typedef void (WINAPI *valentine_delete_attr_t)(void *);

// Same layout as STARTUPINFOEXW.
typedef struct {
	STARTUPINFOW StartupInfo;
	void *lpAttributeList;
} valentine_startupinfoex;

static void *valentine_k32(const char *name) {
	return (void *)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), name);
}

typedef struct {
	valentine_create_pc_t create;
	valentine_resize_pc_t resize;
	valentine_close_pc_t close;
	int bundled; // 1: conpty.dll next to the exe, 0: the system's kernel32 ConPTY
} valentine_conpty_api;

static valentine_conpty_api valentine_conpty;
static INIT_ONCE valentine_conpty_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK valentine_conpty_init(PINIT_ONCE once, PVOID param, PVOID *ctx) {
	(void)once; (void)param; (void)ctx;
	wchar_t dir[MAX_PATH], path[MAX_PATH + 32];
	DWORD n = GetModuleFileNameW(NULL, dir, MAX_PATH);
	while (n > 0 && dir[n - 1] != L'\\') n--;
	dir[n] = 0;
	// Both files must be there: conpty.dll starts OpenConsole.exe from its own folder.
	lstrcpyW(path, dir);
	lstrcatW(path, L"OpenConsole.exe");
	HMODULE mod = NULL;
	if (n > 0 && GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES) {
		lstrcpyW(path, dir);
		lstrcatW(path, L"conpty.dll");
		mod = LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
	}
	if (mod) {
		valentine_conpty.create = (valentine_create_pc_t)(void *)GetProcAddress(mod, "ConptyCreatePseudoConsole");
		valentine_conpty.resize = (valentine_resize_pc_t)(void *)GetProcAddress(mod, "ConptyResizePseudoConsole");
		valentine_conpty.close = (valentine_close_pc_t)(void *)GetProcAddress(mod, "ConptyClosePseudoConsole");
		valentine_conpty.bundled = 1;
	}
	// All three must come from one module: a handle from one is garbage to the other.
	if (!valentine_conpty.create || !valentine_conpty.resize || !valentine_conpty.close) {
		valentine_conpty.create = (valentine_create_pc_t)valentine_k32("CreatePseudoConsole");
		valentine_conpty.resize = (valentine_resize_pc_t)valentine_k32("ResizePseudoConsole");
		valentine_conpty.close = (valentine_close_pc_t)valentine_k32("ClosePseudoConsole");
		valentine_conpty.bundled = 0;
	}
	return TRUE;
}

static valentine_conpty_api *valentine_conpty_get(void) {
	InitOnceExecuteOnce(&valentine_conpty_once, valentine_conpty_init, NULL, NULL);
	return &valentine_conpty;
}

// 1 when the bundled conpty.dll is in use.
static int valentine_conpty_bundled(void) {
	return valentine_conpty_get()->bundled;
}

static COORD valentine_coord(int cols, int rows) {
	COORD c;
	c.X = (SHORT)cols;
	c.Y = (SHORT)rows;
	return c;
}

static wchar_t *valentine_wcsdup(const wchar_t *s) {
	size_t n = (wcslen(s) + 1) * sizeof(wchar_t);
	wchar_t *d = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, n);
	if (d) memcpy(d, s, n);
	return d;
}

// Creates a pseudo console of cols x rows and starts cmdline attached to it in cwd.
// Returns 0 on success, otherwise a Win32 error code or HRESULT.
static int valentine_pty_open(int cols, int rows, const wchar_t *cmdline, const wchar_t *cwd,
		void **out_hpc, void **out_in_w, void **out_out_r, void **out_process) {
	valentine_create_pc_t create_pc = valentine_conpty_get()->create;
	valentine_close_pc_t close_pc = valentine_conpty_get()->close;
	valentine_init_attr_t init_attr = (valentine_init_attr_t)valentine_k32("InitializeProcThreadAttributeList");
	valentine_update_attr_t update_attr = (valentine_update_attr_t)valentine_k32("UpdateProcThreadAttribute");
	valentine_delete_attr_t delete_attr = (valentine_delete_attr_t)valentine_k32("DeleteProcThreadAttributeList");
	if (!create_pc || !close_pc || !init_attr || !update_attr || !delete_attr) {
		return ERROR_PROC_NOT_FOUND; // Windows older than 10 1809
	}

	HANDLE pty_in = NULL, in_w = NULL, out_r = NULL, pty_out = NULL;
	if (!CreatePipe(&pty_in, &in_w, NULL, 0)) return (int)GetLastError();
	if (!CreatePipe(&out_r, &pty_out, NULL, 0)) {
		int e = (int)GetLastError();
		CloseHandle(pty_in);
		CloseHandle(in_w);
		return e;
	}
	void *hpc = NULL;
	HRESULT hr = create_pc(valentine_coord(cols, rows), pty_in, pty_out, VALENTINE_PSEUDOCONSOLE_INHERIT_CURSOR, &hpc);
	// ConPTY duplicates its pipe ends; ours must go so EOF reaches the reader.
	CloseHandle(pty_in);
	CloseHandle(pty_out);
	if (FAILED(hr)) {
		CloseHandle(in_w);
		CloseHandle(out_r);
		return (int)hr;
	}

	int err = 0;
	int attrs_ready = 0;
	SIZE_T attr_size = 0;
	void *attrs = NULL;
	wchar_t *cmd = valentine_wcsdup(cmdline); // CreateProcessW may write into the command line
	valentine_startupinfoex si;
	PROCESS_INFORMATION pi;
	ZeroMemory(&si, sizeof(si));
	ZeroMemory(&pi, sizeof(pi));
	si.StartupInfo.cb = sizeof(si);
	// NULL std handles: without this the child inherits our stdio when it is redirected
	// (pipe, file) and writes there instead of into the pseudo console.
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;

	init_attr(NULL, 1, 0, &attr_size); // fails by design, reports the size
	attrs = HeapAlloc(GetProcessHeap(), 0, attr_size);
	if (!cmd || !attrs) {
		err = ERROR_NOT_ENOUGH_MEMORY;
		goto done;
	}
	if (!init_attr(attrs, 1, 0, &attr_size)) {
		err = (int)GetLastError();
		goto done;
	}
	attrs_ready = 1;
	if (!update_attr(attrs, 0, VALENTINE_ATTR_PSEUDOCONSOLE, hpc, sizeof(hpc), NULL, NULL)) {
		err = (int)GetLastError();
		goto done;
	}
	si.lpAttributeList = attrs;
	if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, VALENTINE_EXTENDED_STARTUPINFO_PRESENT, NULL,
			(cwd && cwd[0]) ? cwd : NULL, &si.StartupInfo, &pi)) {
		err = (int)GetLastError();
		goto done;
	}
	CloseHandle(pi.hThread);

done:
	if (attrs_ready) delete_attr(attrs);
	if (attrs) HeapFree(GetProcessHeap(), 0, attrs);
	if (cmd) HeapFree(GetProcessHeap(), 0, cmd);
	if (err) {
		close_pc(hpc);
		CloseHandle(in_w);
		CloseHandle(out_r);
		return err;
	}
	*out_hpc = hpc;
	*out_in_w = in_w;
	*out_out_r = out_r;
	*out_process = pi.hProcess;
	return 0;
}

static int valentine_pty_resize(void *hpc, int cols, int rows) {
	valentine_resize_pc_t resize_pc = valentine_conpty_get()->resize;
	if (!hpc || !resize_pc) return -1;
	return (int)resize_pc(hpc, valentine_coord(cols, rows));
}

// Closing the pseudo console ends the attached shell and makes the output pipe hit EOF.
static void valentine_pty_close(void *hpc) {
	valentine_close_pc_t close_pc = valentine_conpty_get()->close;
	if (hpc && close_pc) close_pc(hpc);
}

// Blocking read. Returns bytes read (may be 0) or -1 once the pipe is closed.
static int valentine_pty_read(void *h, void *buf, int len) {
	DWORD n = 0;
	if (!ReadFile(h, buf, (DWORD)len, &n, NULL)) return -1;
	return (int)n;
}

static int valentine_pty_write(void *h, const void *buf, int len) {
	const char *p = (const char *)buf;
	DWORD n = 0;
	while (len > 0) {
		if (!WriteFile(h, p, (DWORD)len, &n, NULL)) return -1;
		p += n;
		len -= (int)n;
	}
	return 0;
}

// The stdio pipes our parent (Claude Code) gave us. V's GUI-subsystem startup reopens
// stdout on NUL, which closes the original handle (and NUL may even reuse its value), so
// copies are taken in a constructor that runs before V's startup code.
static HANDLE valentine_saved_in, valentine_saved_out;

__attribute__((constructor)) static void valentine_save_std(void) {
	HANDLE self = GetCurrentProcess();
	DuplicateHandle(self, GetStdHandle(STD_INPUT_HANDLE), self, &valentine_saved_in, 0, FALSE, DUPLICATE_SAME_ACCESS);
	DuplicateHandle(self, GetStdHandle(STD_OUTPUT_HANDLE), self, &valentine_saved_out, 0, FALSE, DUPLICATE_SAME_ACCESS);
}

static int valentine_std_read(void *buf, int len) {
	DWORD n = 0;
	if (!valentine_saved_in || !ReadFile(valentine_saved_in, buf, (DWORD)len, &n, NULL)) return -1;
	return (int)n;
}

static int valentine_std_write(const void *buf, int len) {
	return valentine_saved_out ? valentine_pty_write(valentine_saved_out, buf, len) : -1;
}

static void valentine_pty_wait(void *process) { WaitForSingleObject(process, INFINITE); }
static void valentine_pty_kill(void *process) { TerminateProcess(process, 1); }

static int valentine_pty_exit_code(void *process) {
	DWORD code = 0;
	GetExitCodeProcess(process, &code);
	return (int)code;
}

static void valentine_close_handle(void *h) {
	if (h) CloseHandle(h);
}

// Runs cmdline (already quoted) and waits for it to exit. Returns 0 or a Win32 error.
static int valentine_run_and_wait(const wchar_t *cmdline) {
	STARTUPINFOW si;
	PROCESS_INFORMATION pi;
	ZeroMemory(&si, sizeof(si));
	ZeroMemory(&pi, sizeof(pi));
	si.cb = sizeof(si);
	wchar_t *cmd = valentine_wcsdup(cmdline);
	if (!cmd) return ERROR_NOT_ENOUGH_MEMORY;
	BOOL ok = CreateProcessW(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi);
	HeapFree(GetProcessHeap(), 0, cmd);
	if (!ok) return (int)GetLastError();
	WaitForSingleObject(pi.hProcess, INFINITE);
	CloseHandle(pi.hThread);
	CloseHandle(pi.hProcess);
	return 0;
}

// Real Windows build number (GetVersionEx lies without a manifest; RtlGetVersion does not).
static int valentine_windows_build(void) {
	typedef LONG (WINAPI *rtl_get_version_t)(OSVERSIONINFOW *);
	rtl_get_version_t get = (rtl_get_version_t)(void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
	OSVERSIONINFOW v;
	ZeroMemory(&v, sizeof(v));
	v.dwOSVersionInfoSize = sizeof(v);
	return (get && get(&v) == 0) ? (int)v.dwBuildNumber : 0;
}

#define VALENTINE_RUN_KEY L"Software\\Microsoft\\Windows\\CurrentVersion\\Run"

// Start-with-Windows lives in the per-user Run key, value "Valentine".
static int valentine_autostart_enabled(void) {
	HKEY k;
	if (RegOpenKeyExW(HKEY_CURRENT_USER, VALENTINE_RUN_KEY, 0, KEY_QUERY_VALUE, &k) != ERROR_SUCCESS) return 0;
	LONG r = RegQueryValueExW(k, L"Valentine", NULL, NULL, NULL, NULL);
	RegCloseKey(k);
	return r == ERROR_SUCCESS;
}

// Sets the Run value to cmdline, or removes it when cmdline is NULL. Returns 0 or a Win32 error.
static int valentine_autostart_set(const wchar_t *cmdline) {
	HKEY k;
	LONG r = RegCreateKeyExW(HKEY_CURRENT_USER, VALENTINE_RUN_KEY, 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL);
	if (r != ERROR_SUCCESS) return (int)r;
	if (cmdline) {
		r = RegSetValueExW(k, L"Valentine", 0, REG_SZ, (const BYTE *)cmdline, (DWORD)((wcslen(cmdline) + 1) * sizeof(wchar_t)));
	} else {
		r = RegDeleteValueW(k, L"Valentine");
		if (r == ERROR_FILE_NOT_FOUND) r = ERROR_SUCCESS;
	}
	RegCloseKey(k);
	return (int)r;
}

static void valentine_maximize(void *hwnd) {
	if (hwnd) ShowWindow((HWND)hwnd, SW_MAXIMIZE);
}

// Returns 1 if this is the only running Valentine. The mutex lives as long as the process.
static int valentine_single_instance(void) {
	HANDLE m = CreateMutexW(NULL, FALSE, L"Local\\ValentineTerminalMultiplexer");
	return m != NULL && GetLastError() != ERROR_ALREADY_EXISTS;
}

#endif
