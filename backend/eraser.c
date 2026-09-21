// Folio's AppLoad backend: tells the QML which end of the Marker is in use,
// and which of xochitl's log lines are Folio's own.
//
// xochitl hands apps the pen as a plain mouse, the same for the tip and the
// eraser end, so the QML cannot tell them apart. The digitizer can: it sets
// BTN_TOOL_RUBBER when the eraser end comes into range, before it touches.
// This reads the pen device alongside xochitl (no grab) and sends message 101
// with "rubber" or "pen" on each change, and again to each new frontend.
//
// QML cannot read the journal, and Folio's errors (a TypeError, a version
// that failed to load, a crash) end up only there. This follows
// `journalctl -u xochitl` from a day back and sends each of Folio's lines as
// message 102, the last ones again to each new frontend. `entry --filter`
// reads log lines on stdin and prints the ones it would send, for testing.
//
// AppLoad starts it with argv[1] = a SOCK_SEQPACKET socket to connect to.
// A message is two packets: {int32 type, int32 length}, then the bytes.
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define PEN_DEVICE "/dev/input/event2"
#define MSG_TOOL 101
#define MSG_LOG 102
#define MSG_TERMINATE -1
#define MSG_NEW_COORDINATOR -2
#define KEEP 30
#define LINE_MAX_LEN 480

struct header {
    int32_t type;
    int32_t length;
};

static int send_msg(int sock, int type, const char *text) {
    struct header h = { type, (int32_t)strlen(text) };
    if (send(sock, &h, sizeof h, MSG_NOSIGNAL) != sizeof h) return -1;
    if (h.length > 0 && send(sock, text, h.length, MSG_NOSIGNAL) != h.length) return -1;
    return 0;
}

// Folio's lines: its files (claude-app/code/…, or the built-in copy in the
// rcc, qrc:/…/ui/), the app's own "Folio: " lines, and xochitl crashes,
// which an app can cause. Not the binding-loop warnings nor their second
// lines (a bare "file:///…" message): harmless, and many.
static int wanted(const char *line) {
    if (strstr(line, "Binding loop") || strstr(line, "qmldiff") || strstr(line, "[AppLoad]: Loading")) return 0;
    const char *msg = strstr(line, "]: ");
    if (msg && strncmp(msg + 3, "file:", 5) == 0) return 0;
    return strstr(line, "claude-app") || strstr(line, "Folio: ") ||
           (strstr(line, "qrc:/") && strstr(line, "/ui/")) ||
           strstr(line, "Main process exited") || strstr(line, "corrupted") ||
           strstr(line, "Layers are not supported");
}

static int filter(void) {
    char line[4096];
    while (fgets(line, sizeof line, stdin))
        if (wanted(line)) fputs(line, stdout);
    return 0;
}

static char kept[KEEP][LINE_MAX_LEN + 1];
static int nkept;

static void keep(const char *line) {
    if (nkept == KEEP) {
        memmove(kept[0], kept[1], sizeof kept[0] * (KEEP - 1));
        nkept--;
    }
    snprintf(kept[nkept++], sizeof kept[0], "%.*s", LINE_MAX_LEN, line);
}

static pid_t journal(int *fd) {
    int p[2];
    if (pipe(p) != 0) return -1;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(p[1], 1);
        close(p[0]);
        close(p[1]);
        // a day, not a line count: binding-loop warnings fill any short tail
        execlp("journalctl", "journalctl", "-u", "xochitl", "-f", "--since", "-24h", "-o", "short-iso", "--no-pager", (char *)0);
        _exit(127);
    }
    close(p[1]);
    if (pid < 0) {
        close(p[0]);
        return -1;
    }
    fcntl(p[0], F_SETFL, O_NONBLOCK);
    *fd = p[0];
    return pid;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--filter") == 0) return filter();
    if (argc < 2) return 2;
    int sock = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strncpy(addr.sun_path, argv[1], sizeof addr.sun_path - 1);
    if (sock < 0 || connect(sock, (struct sockaddr *)&addr, sizeof addr) != 0) return 1;

    int pen = open(PEN_DEVICE, O_RDONLY | O_NONBLOCK);
    int rubber = 0;
    send_msg(sock, MSG_TOOL, "pen");

    int log = -1;
    pid_t jpid = journal(&log);
    char buf[8192];
    size_t used = 0;
    int ret = 0;

    for (;;) {
        struct pollfd fds[3] = { { sock, POLLIN, 0 }, { pen, POLLIN, 0 }, { log, POLLIN, 0 } };
        if (poll(fds, 3, -1) < 0) { ret = 1; break; }

        if (fds[0].revents & (POLLHUP | POLLERR)) break;
        if (fds[0].revents & POLLIN) {
            struct header h;
            if (recv(sock, &h, sizeof h, 0) < (ssize_t)sizeof h) break;
            if (h.length > 0) {
                char msg[4096];
                if (recv(sock, msg, sizeof msg, 0) < 1) break;
            }
            if (h.type == MSG_TERMINATE) break;
            if (h.type == MSG_NEW_COORDINATOR) {
                send_msg(sock, MSG_TOOL, rubber ? "rubber" : "pen");
                for (int i = 0; i < nkept; i++) send_msg(sock, MSG_LOG, kept[i]);
            }
        }

        if (pen >= 0 && (fds[1].revents & POLLIN)) {
            struct input_event e;
            int gone = 0;
            while (read(pen, &e, sizeof e) == sizeof e) {
                if (e.type != EV_KEY || (e.code != BTN_TOOL_RUBBER && e.code != BTN_TOOL_PEN)) continue;
                int now = e.code == BTN_TOOL_RUBBER ? e.value != 0 : (e.value ? 0 : rubber);
                if (now != rubber) {
                    rubber = now;
                    if (send_msg(sock, MSG_TOOL, rubber ? "rubber" : "pen") != 0) { gone = 1; break; }
                }
            }
            if (gone) break;
        }

        if (log >= 0 && (fds[2].revents & (POLLIN | POLLHUP))) {
            ssize_t n = read(log, buf + used, sizeof buf - 1 - used);
            if (n <= 0) {
                close(log);
                log = -1;
                continue;
            }
            used += n;
            buf[used] = 0;
            char *start = buf, *nl;
            while ((nl = strchr(start, '\n'))) {
                *nl = 0;
                if (wanted(start)) {
                    keep(start);
                    if (send_msg(sock, MSG_LOG, kept[nkept - 1]) != 0) { ret = 0; goto out; }
                }
                start = nl + 1;
            }
            used = buf + used - start;
            memmove(buf, start, used);
            // a line longer than the buffer: drop it
            if (used == sizeof buf - 1) used = 0;
        }
    }
out:
    if (jpid > 0) {
        kill(jpid, SIGTERM);
        waitpid(jpid, NULL, 0);
    }
    return ret;
}
