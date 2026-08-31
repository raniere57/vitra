#include "include/vitra_spawn.h"

#include <errno.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>

/// Where the child tells the parent why it never reached execve.
static int child_report_fd = -1;

/// Reports `errno` up the pipe and leaves. Only async-signal-safe calls.
static void child_failed(void) {
    int failure = errno;
    if (child_report_fd >= 0) {
        ssize_t ignored = write(child_report_fd, &failure, sizeof(failure));
        (void)ignored;
    }
    _exit(127);
}

pid_t vitra_spawn_on_tty(
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *tty_path,
    const char *working_directory
) {
    // The child cannot report a failure by returning: it reports through a
    // close-on-exec pipe, which stays open exactly until execve succeeds.
    int report[2];
    if (pipe(report) != 0) return -1;
    fcntl(report[0], F_SETFD, FD_CLOEXEC);
    fcntl(report[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        int failure = errno;
        close(report[0]);
        close(report[1]);
        errno = failure;
        return -1;
    }

    if (pid > 0) {
        close(report[1]);
        int child_errno = 0;
        ssize_t got = read(report[0], &child_errno, sizeof(child_errno));
        close(report[0]);
        if (got == sizeof(child_errno)) {
            // The child died before exec: reap it so it leaves no zombie, and
            // report what stopped it as if this call had failed outright.
            int status = 0;
            waitpid(pid, &status, 0);
            errno = child_errno;
            return -1;
        }
        return pid;
    }

    child_report_fd = report[1];
    close(report[0]);

    // Everything below runs in the child, before execve, and is
    // async-signal-safe by construction.
    if (setsid() < 0) child_failed();

    int fd = open(tty_path, O_RDWR);
    if (fd < 0) child_failed();
    // The line that was missing: on macOS this, and only this, is what makes a
    // tty the controlling terminal of a session.
    if (ioctl(fd, TIOCSCTTY, 0) < 0) child_failed();

    if (dup2(fd, 0) < 0 || dup2(fd, 1) < 0 || dup2(fd, 2) < 0) child_failed();
    if (fd > 2) close(fd);

    // Nothing the app had open belongs to the shell - the pty's own master
    // above all, which a shell would otherwise hand to everything it runs.
    // The loop is bounded rather than run to getdtablesize(): a GUI process on
    // macOS carries a file limit of about a million, and closing a million
    // descriptors one by one is most of a second of the shell's startup.
    // Descriptors are handed out lowest-first, so a few hundred open files
    // never reach four figures - and this app's own are close-on-exec anyway.
    // (Darwin has no closefrom.)
    int limit = getdtablesize();
    if (limit > 4096 || limit < 0) limit = 4096;
    for (int i = 3; i < limit; i++) {
        if (i != child_report_fd) close(i);
    }

    if (working_directory != 0 && chdir(working_directory) < 0) child_failed();

    // A GUI process ignores SIGPIPE and may block signals; a shell expects
    // default dispositions and an empty mask.
    for (int signal_number = 1; signal_number < NSIG; signal_number++) {
        signal(signal_number, SIG_DFL);
    }
    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, 0);

    execve(path, argv, envp);
    child_failed();
    _exit(127);
}
