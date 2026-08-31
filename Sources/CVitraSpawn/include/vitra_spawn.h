#ifndef VITRA_SPAWN_H
#define VITRA_SPAWN_H

#include <sys/types.h>

/// Starts `path` on the tty at `tty_path` with that tty as its controlling
/// terminal, and returns the child's pid, or -1 with errno set.
///
/// This exists because macOS does not hand out a controlling terminal on open:
/// it takes an explicit TIOCSCTTY, which posix_spawn has no file action for. A
/// child spawned without one has no session on its tty, so the shell never
/// turns on job control: Ctrl-C reaches nobody, and the terminal cannot tell
/// whether a program is running in it.
///
/// Written in C on purpose. Between fork() and execve() only async-signal-safe
/// calls are allowed, and Swift's runtime takes locks another thread may hold
/// at fork time — which is what crashed this app when it used forkpty().
pid_t vitra_spawn_on_tty(
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *tty_path,
    const char *working_directory
);

#endif
