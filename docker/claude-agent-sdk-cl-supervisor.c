#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <signal.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int wait_for_child(pid_t child, int *status) {
  for (;;) {
    const pid_t result = waitpid(child, status, 0);
    if (result == child) return 0;
    if (result < 0 && errno == EINTR) continue;
    return -1;
  }
}

static void signal_cli_group(pid_t child) {
  const struct timespec grace = {.tv_sec = 0, .tv_nsec = 50000000L};
  /* CHILD remains the CLI group leader PID even after it has exited. */
  (void)kill(-child, SIGTERM);
  (void)nanosleep(&grace, NULL);
  (void)kill(-child, SIGKILL);
  /* Preserve bounded direct-child reaping even if group lookup failed. */
  (void)kill(child, SIGKILL);
}

static void reap_adopted_children_bounded(void) {
  const struct timespec pause = {.tv_sec = 0, .tv_nsec = 5000000L};
  int ignored_status = 0;
  /* Drain any number of exited descendants, but bound only idle polling so an
     escaped or uninterruptible child can never wedge SDK shutdown. */
  int idle_polls = 0;
  while (idle_polls < 20) {
    const pid_t result = waitpid(-1, &ignored_status, WNOHANG);
    if (result > 0 || (result < 0 && errno == EINTR)) continue;
    /* No adopted child remains: avoid adding latency to ordinary CLI exits. */
    if (result < 0 && errno == ECHILD) return;
    if (result == 0) {
      (void)nanosleep(&pause, NULL);
      ++idle_polls;
      continue;
    }
    return;
  }
}

static void terminate_group_and_reap(pid_t child, int *status) {
  signal_cli_group(child);
  (void)wait_for_child(child, status);
  reap_adopted_children_bounded();
}

int main(int argc, char **argv) {
  if (argc < 2) return 64;
  /* Adopt orphaned CLI descendants rather than leaving zombies to container init. */
  if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0) return 65;

  const int terminal_signals[] = {SIGTERM, SIGINT, SIGHUP};
  sigset_t terminal_set;
  sigemptyset(&terminal_set);
  for (size_t i = 0; i < sizeof(terminal_signals) / sizeof(terminal_signals[0]); ++i)
    sigaddset(&terminal_set, terminal_signals[i]);
  /* The parent consumes termination synchronously via sigtimedwait. */
  if (sigprocmask(SIG_BLOCK, &terminal_set, NULL) != 0) return 70;

  int ready[2];
  if (pipe(ready) != 0) return 71;
  const pid_t child = fork();
  if (child < 0) return 72;
  if (child == 0) {
    close(ready[0]);
    /* This child becomes both session and process-group leader before exec. */
    if (setsid() < 0) _exit(73);
    /* Never inherit non-default signal handlers from the hosting Lisp runtime. */
    struct sigaction defaults = {0};
    defaults.sa_handler = SIG_DFL;
    for (size_t i = 0; i < sizeof(terminal_signals) / sizeof(terminal_signals[0]); ++i)
      (void)sigaction(terminal_signals[i], &defaults, NULL);
    if (sigprocmask(SIG_UNBLOCK, &terminal_set, NULL) != 0) _exit(74);
    const char marker = 'R';
    if (write(ready[1], &marker, 1) != 1) _exit(75);
    close(ready[1]);
    execvp(argv[1], &argv[1]);
    _exit(errno == ENOENT ? 127 : 126);
  }

  close(ready[1]);
  char marker = 0;
  const ssize_t bytes = read(ready[0], &marker, 1);
  close(ready[0]);
  if (bytes != 1 || marker != 'R') {
    terminate_group_and_reap(child, &(int){0});
    return 76;
  }

  const struct timespec poll = {.tv_sec = 0, .tv_nsec = 50000000L};
  int status = 0;
  for (;;) {
    /* Observe the direct child without reaping it. Its PID remains reserved,
       so -CHILD cannot race with an unrelated recycled process group. */
    siginfo_t child_info = {0};
    if (waitid(P_PID, child, &child_info, WEXITED | WNOHANG | WNOWAIT) != 0) {
      if (errno != EINTR) return 78;
    } else if (child_info.si_pid == child) {
      signal_cli_group(child);
      if (wait_for_child(child, &status) != 0) return 79;
      reap_adopted_children_bounded();
      if (WIFEXITED(status)) return WEXITSTATUS(status);
      if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
      return 77;
    }

    const int received = sigtimedwait(&terminal_set, NULL, &poll);
    if (received == SIGTERM || received == SIGINT || received == SIGHUP) {
      terminate_group_and_reap(child, &status);
      return 143;
    }
    if (received < 0 && errno != EAGAIN && errno != EINTR) return 79;
  }
}
