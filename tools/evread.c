// evread DEV SECONDS: print pen tool and touch key events from an evdev device
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int fd = open(argv[1], O_RDONLY | O_NONBLOCK);
    if (fd < 0) { perror(argv[1]); return 1; }
    time_t end = time(0) + atoi(argv[2]);
    struct input_event e;
    int n = 0;
    while (time(0) < end) {
        struct pollfd p = { fd, POLLIN, 0 };
        if (poll(&p, 1, 200) <= 0) continue;
        while (read(fd, &e, sizeof e) == sizeof e) {
            n++;
            if (e.type == EV_KEY) printf("key %d = %d\n", e.code, e.value);
        }
    }
    printf("%d events\n", n);
    return 0;
}
