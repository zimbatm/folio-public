// rmin: inject input on the Paper Pro Move, in framebuffer pixels (960x1696).
//   rmin power
//   rmin tap X Y
//   rmin swipe X1 Y1 X2 Y2
//   rmin pen X1 Y1 X2 Y2 [X Y ...]     one stroke through the points
//   rmin rubber X1 Y1 X2 Y2 [X Y ...]  the same with the pen's eraser end
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#define FB_W 960
#define FB_H 1696
#define TOUCH_W 1248
#define TOUCH_H 2208
#define PEN_W 6760
#define PEN_H 11960

static int fd;

static void ev(int type, int code, int val) {
    struct input_event e = {0};
    e.type = type; e.code = code; e.value = val;
    if (write(fd, &e, sizeof e) != sizeof e) { perror("write"); exit(1); }
}
static void syn(void) { ev(EV_SYN, SYN_REPORT, 0); }
static void dev(const char *p) { fd = open(p, O_WRONLY); if (fd < 0) { perror(p); exit(1); } }

static void touch(int x, int y, int down) {
    ev(EV_ABS, ABS_MT_SLOT, 0);
    if (!down) { ev(EV_ABS, ABS_MT_TRACKING_ID, -1); syn(); return; }
    ev(EV_ABS, ABS_MT_TRACKING_ID, 1);
    ev(EV_ABS, ABS_MT_POSITION_X, x * TOUCH_W / FB_W);
    ev(EV_ABS, ABS_MT_POSITION_Y, y * TOUCH_H / FB_H);
    ev(EV_ABS, ABS_MT_PRESSURE, 100);
    ev(EV_ABS, ABS_MT_TOUCH_MAJOR, 17);
    ev(EV_ABS, ABS_MT_TOUCH_MINOR, 17);
    syn();
}

static void penxy(int x, int y) {
    ev(EV_ABS, ABS_X, x * PEN_W / FB_W);
    ev(EV_ABS, ABS_Y, y * PEN_H / FB_H);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: rmin power|tap|swipe|pen ...\n"); return 2; }
    const char *cmd = argv[1];
    int n = argc - 2;
    int *v = calloc(n + 1, sizeof *v);
    for (int i = 0; i < n; i++) v[i] = atoi(argv[i + 2]);

    if (!strcmp(cmd, "power")) {
        dev("/dev/input/event0");
        ev(EV_KEY, KEY_POWER, 1); syn(); usleep(150000);
        ev(EV_KEY, KEY_POWER, 0); syn();
    } else if (!strcmp(cmd, "tap") && n == 2) {
        dev("/dev/input/event3");
        touch(v[0], v[1], 1); usleep(80000); touch(0, 0, 0);
    } else if (!strcmp(cmd, "swipe") && n == 4) {
        dev("/dev/input/event3");
        for (int s = 0; s <= 20; s++) {
            touch(v[0] + (v[2] - v[0]) * s / 20, v[1] + (v[3] - v[1]) * s / 20, 1);
            usleep(15000);
        }
        touch(0, 0, 0);
    } else if ((!strcmp(cmd, "pen") || !strcmp(cmd, "rubber")) && n >= 4 && n % 2 == 0) {
        int tool = !strcmp(cmd, "rubber") ? BTN_TOOL_RUBBER : BTN_TOOL_PEN;
        dev("/dev/input/event2");
        penxy(v[0], v[1]);
        ev(EV_KEY, tool, 1); ev(EV_ABS, ABS_DISTANCE, 100); syn(); usleep(20000);
        ev(EV_KEY, BTN_TOUCH, 1); ev(EV_ABS, ABS_PRESSURE, 2000); ev(EV_ABS, ABS_DISTANCE, 0); syn();
        struct timeval tv; gettimeofday(&tv, 0);
        fprintf(stderr, "pen-down@%lld\n", (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000);
        for (int i = 2; i + 1 < n; i += 2) {
            int x0 = v[i - 2], y0 = v[i - 1], x1 = v[i], y1 = v[i + 1];
            int steps = (abs(x1 - x0) + abs(y1 - y0)) / 4 + 1;
            for (int s = 1; s <= steps; s++) {
                penxy(x0 + (x1 - x0) * s / steps, y0 + (y1 - y0) * s / steps);
                syn(); usleep(4000);
            }
        }
        ev(EV_ABS, ABS_PRESSURE, 0); ev(EV_ABS, ABS_DISTANCE, 100); ev(EV_KEY, BTN_TOUCH, 0); syn();
        ev(EV_KEY, tool, 0); syn();
    } else {
        fprintf(stderr, "bad arguments\n"); return 2;
    }
    return 0;
}
