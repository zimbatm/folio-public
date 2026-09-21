// fbgrab OUT.raw: copy xochitl's 960x1696 RGBA framebuffer out of its heap.
// The buffer sits in a heap mapping right after a /dev/dri/card0 mapping; which
// one varies (xovi, restarts). The walk over malloc chunk headers is
// goMarkableStream's.
#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int find_pid(void) {
    DIR *d = opendir("/proc");
    struct dirent *e;
    while ((e = readdir(d))) {
        char p[300], comm[64] = {0};
        snprintf(p, sizeof p, "/proc/%s/comm", e->d_name);
        FILE *f = fopen(p, "r");
        if (!f) continue;
        fgets(comm, sizeof comm, f);
        fclose(f);
        if (!strcmp(comm, "xochitl\n")) return atoi(e->d_name);
    }
    return -1;
}

// candidates: each anonymous rw-p mapping right after a /dev/dri/card0 one
static int find_heaps(int pid, uint64_t *out, int max) {
    char p[64], line[512];
    snprintf(p, sizeof p, "/proc/%d/maps", pid);
    FILE *f = fopen(p, "r");
    int after_card = 0, n = 0;
    while (n < max && fgets(line, sizeof line, f)) {
        int card = strstr(line, "/dev/dri/card0") != NULL;
        if (!card && after_card && strstr(line, "rw-p 00000000 00:00 0"))
            out[n++] = strtoull(line, 0, 16);
        after_card = card;
    }
    fclose(f);
    return n;
}

static uint64_t walk(int fd, uint64_t start, uint64_t size) {
    uint64_t off = 0, len = 2;
    while (len < size) {
        off += len - 2;
        uint8_t h[8];
        if (pread(fd, h, 8, start + off + 8) != 8) return 0;
        len = h[0] | h[1] << 8 | h[2] << 16 | (uint64_t)h[3] << 24;
        if (len < 2) return 0;
    }
    return start + off;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: fbgrab OUT.raw\n"); return 2; }
    int pid = find_pid();
    if (pid < 0) { fprintf(stderr, "xochitl not running\n"); return 1; }
    char p[64]; snprintf(p, sizeof p, "/proc/%d/mem", pid);
    int fd = open(p, O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    const uint64_t size = 960ull * 1696 * 4;
    uint64_t heaps[16], fb = 0;
    int n = find_heaps(pid, heaps, 16);
    for (int i = 0; i < n && !fb; i++) fb = walk(fd, heaps[i], size);
    if (!fb) { fprintf(stderr, "framebuffer not found in %d candidate mappings\n", n); return 1; }
    uint8_t *buf = malloc(size);
    if (pread(fd, buf, size, fb) != (ssize_t)size) { perror("read fb"); return 1; }
    FILE *o = fopen(argv[1], "wb");
    fwrite(buf, 1, size, o);
    fclose(o);
    return 0;
}
