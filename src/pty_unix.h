// Pseudo terminals and process helpers for macOS and Linux; the counterpart of conpty.h.
#ifndef VALENTINE_PTY_UNIX_H
#define VALENTINE_PTY_UNIX_H

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

// The child runs `/bin/sh -c cmdline` in cwd. Between fork and exec only async-signal-safe
// calls: other threads may hold locks (malloc) that the child would wait on forever.
static int valentine_pty_open(int cols, int rows, const char *cmdline, const char *cwd, int *fd, int *pid) {
	struct winsize ws = {0};
	ws.ws_col = (unsigned short)cols;
	ws.ws_row = (unsigned short)rows;
	int master = -1;
	pid_t p = forkpty(&master, NULL, NULL, &ws);
	if (p < 0) return errno;
	if (p == 0) {
		// Our listening sockets must not outlive us in the shells, or a restarted
		// Valentine could not bind its ports.
		for (int i = 3; i < 4096; i++) close(i);
		if (chdir(cwd) != 0 && chdir("/") != 0) _exit(126);
		// Ignored signals and the signal mask survive exec; V ignores SIGPIPE for its sockets.
		sigset_t none;
		sigemptyset(&none);
		sigprocmask(SIG_SETMASK, &none, NULL);
		signal(SIGPIPE, SIG_DFL);
		execl("/bin/sh", "sh", "-c", cmdline, (char *)NULL);
		_exit(127);
	}
	*fd = master;
	*pid = (int)p;
	return 0;
}

static int valentine_pty_resize(int fd, int cols, int rows) {
	struct winsize ws = {0};
	ws.ws_col = (unsigned short)cols;
	ws.ws_row = (unsigned short)rows;
	return ioctl(fd, TIOCSWINSZ, &ws); // the kernel sends SIGWINCH to the foreground job
}

// Returns bytes read, 0 when nothing arrived within 200 ms, -1 at EOF. Polling lets the
// reader notice the shell's exit even when a background job still holds the terminal.
// Bytes already waiting on the pty, so the reader can batch them into one message.
static int valentine_pty_available(int fd) {
	int n = 0;
	return ioctl(fd, FIONREAD, &n) == 0 ? n : 0;
}

static int valentine_pty_read(int fd, void *buf, int len) {
	struct pollfd pfd = {fd, POLLIN, 0};
	int r = poll(&pfd, 1, 200);
	if (r == 0 || (r < 0 && errno == EINTR)) return 0;
	if (r < 0) return -1;
	ssize_t n = read(fd, buf, (size_t)len);
	if (n < 0 && (errno == EINTR || errno == EAGAIN)) return 0;
	return n > 0 ? (int)n : -1; // Linux reports EIO once the shell is gone
}

static int valentine_pty_write(int fd, const void *buf, int len) {
	const char *p = (const char *)buf;
	while (len > 0) {
		ssize_t n = write(fd, p, (size_t)len);
		if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
		if (n <= 0) return -1;
		p += n;
		len -= (int)n;
	}
	return 0;
}

// Exit code as a shell reports it: 128 + signal for a killed process.
static int valentine_pty_wait(int pid) {
	int status = 0;
	while (waitpid((pid_t)pid, &status, 0) < 0) {
		if (errno != EINTR) return -1;
	}
	if (WIFEXITED(status)) return WEXITSTATUS(status);
	if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
	return -1;
}

// SIGHUP, like closing a terminal window: shells save their history and hang up their jobs.
static void valentine_pty_kill(int pid) { kill((pid_t)pid, SIGHUP); }
static void valentine_close_fd(int fd) { close(fd); }

static int valentine_std_read(void *buf, int len) {
	ssize_t n;
	do n = read(0, buf, (size_t)len); while (n < 0 && errno == EINTR);
	return (int)n;
}

static int valentine_std_write(const void *buf, int len) {
	return valentine_pty_write(1, buf, len) == 0 ? len : -1;
}

// Held until the process exits; the kernel drops the lock even after a crash.
static int valentine_single_instance(const char *lock_path) {
	int fd = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
	if (fd < 0) return 1; // cannot tell: run anyway rather than refuse to start
	return flock(fd, LOCK_EX | LOCK_NB) == 0 ? 1 : 0;
}

#endif
