// vramtemp.c — read the GDDR6/GDDR6X memory temperature and GPU hotspot of NVIDIA GeForce cards (read-only).
//
// NVML does not expose memory-junction temperature on GeForce. The driver keeps it in BAR0 registers, which we
// read through /dev/mem. Register offsets and decoding come from two maintained open-source projects:
//   ThomasBaruzier/gddr6-core-junction-vram-temps (Apache-2.0)  src/sensor.c
//   olealgoritme/gddr6                                            lib/src/gddr6.c (device table)
// Unknown cards print NA — the caller must then fall back to the NVML core temperature. Never guess an offset.
//
// Needs root and a kernel that allows /dev/mem access to PCI MMIO: works when CONFIG_IO_STRICT_DEVMEM is not set
// (Ubuntu default), or with the boot option iomem=relaxed. Secure Boot / kernel lockdown blocks it (prints NA).
//
//   build:  gcc -O2 -o vramtemp vramtemp.c
//   once:   sudo ./vramtemp 0000:07:00.0 [...]      → "0000:07:00.0 vram=58 hotspot=61"
//   loop:   sudo ./vramtemp -l FILE -i SECS -p PID BDF [...]
//           rewrites FILE (atomically) every SECS with the same lines; exits when process PID is gone.
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <unistd.h>

// Memory-temperature register by PCI device ID. Decoding for all of these: bits[11:0] / 32 = °C.
// Source: olealgoritme/gddr6 device table (GA10x / AD10x). Add a card only with a verified source.
static const struct { uint16_t dev; uint32_t off; const char *name; } VRAM_TABLE[] = {
    {0x2684, 0xE2A8, "RTX 4090"},        {0x2685, 0xE2A8, "RTX 4090 D"},     {0x2702, 0xE2A8, "RTX 4080 Super"},
    {0x2704, 0xE2A8, "RTX 4080"},        {0x2705, 0xE2A8, "RTX 4070 Ti Super"},
    {0x2782, 0xE2A8, "RTX 4070 Ti"},     {0x2783, 0xE2A8, "RTX 4070 Super"}, {0x2786, 0xE2A8, "RTX 4070"},
    {0x2860, 0xE2A8, "RTX 4070 Mobile"}, {0x28e0, 0xE2A8, "RTX 4060 Mobile"}, {0x28a0, 0xE2A8, "RTX 4060 Laptop"},
    {0x2203, 0xE2A8, "RTX 3090 Ti"},     {0x2204, 0xE2A8, "RTX 3090"},       {0x2208, 0xE2A8, "RTX 3080 Ti"},
    {0x2206, 0xE2A8, "RTX 3080"},        {0x2216, 0xE2A8, "RTX 3080 LHR"},
    {0x2484, 0xEE50, "RTX 3070"},        {0x2488, 0xEE50, "RTX 3070 LHR"},
    {0x2531, 0xE2A8, "RTX A2000"},       {0x2571, 0xE2A8, "RTX A2000"},      {0x24b0, 0xE2A8, "RTX A4000"},
    {0x2232, 0xE2A8, "RTX A4500"},       {0x2231, 0xE2A8, "RTX A5000"},      {0x26B1, 0xE2A8, "RTX 6000 Ada"},
    {0x27b8, 0xE2A8, "L4"},              {0x26b9, 0xE2A8, "L40S"},           {0x2236, 0xE2A8, "A10"},
};
// GPU hotspot: BAR0 + 0x2046C, bits[15:8] = °C, on pre-Blackwell cards (ThomasBaruzier sensor.c, GDDR6 profile).
// Blackwell (device IDs 0x2Bxx-0x2Dxx) uses different registers — not implemented, prints NA.
#define HOTSPOT_OFF 0x2046Cu

static int read_reg(int fd, uint64_t bar0, uint32_t off, uint32_t *out) {
    long pg = sysconf(_SC_PAGESIZE);
    uint64_t phys = bar0 + off, base = phys & ~(uint64_t)(pg - 1);
    void *m = mmap(NULL, pg, PROT_READ, MAP_SHARED, fd, (off_t)base);
    if (m == MAP_FAILED) return -1;
    *out = *(volatile uint32_t *)((char *)m + (phys - base));
    munmap(m, pg);
    return 0;
}

static int read_hex(const char *bdf, const char *file, unsigned long long *v) {
    char p[256]; snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/%s", bdf, file);
    FILE *f = fopen(p, "r"); if (!f) return -1;
    int ok = fscanf(f, "%llx", v) == 1; fclose(f); return ok ? 0 : -1;
}

static void one(FILE *out, int fd, const char *bdf) {
    unsigned long long vendor = 0, dev = 0, bar0 = 0;
    if (read_hex(bdf, "vendor", &vendor) || vendor != 0x10de || read_hex(bdf, "device", &dev) ||
        read_hex(bdf, "resource", &bar0) || !bar0) {
        fprintf(out, "%s vram=NA hotspot=NA\n", bdf); return;
    }
    int vram = -1, hot = -1; uint32_t raw;
    for (size_t i = 0; i < sizeof VRAM_TABLE / sizeof VRAM_TABLE[0]; i++)
        if (VRAM_TABLE[i].dev == dev && read_reg(fd, bar0, VRAM_TABLE[i].off, &raw) == 0 && raw != 0xFFFFFFFFu)
            vram = (int)((raw & 0xFFFu) / 32);
    int blackwell = dev >= 0x2B00 && dev < 0x2E00;
    if (!blackwell && read_reg(fd, bar0, HOTSPOT_OFF, &raw) == 0 && raw != 0xFFFFFFFFu) hot = (int)((raw >> 8) & 0xFFu);
    // plausibility: 0 or >= 127 means "not populated / invalid"
    if (vram <= 0 || vram >= 127) vram = -1;
    if (hot <= 0 || hot >= 127) hot = -1;
    fprintf(out, "%s", bdf);
    if (vram >= 0) fprintf(out, " vram=%d", vram); else fprintf(out, " vram=NA");
    if (hot >= 0) fprintf(out, " hotspot=%d\n", hot); else fprintf(out, " hotspot=NA\n");
}

int main(int argc, char **argv) {
    const char *loopfile = NULL; int secs = 2; pid_t watch = 0, c;
    while ((c = getopt(argc, argv, "l:i:p:")) != -1) {
        if (c == 'l') loopfile = optarg; else if (c == 'i') secs = atoi(optarg); else if (c == 'p') watch = atoi(optarg);
        else { fprintf(stderr, "usage: %s [-l FILE -i SECS -p PID] <pci-bdf> [...]\n", argv[0]); return 2; }
    }
    if (optind >= argc) { fprintf(stderr, "usage: %s [-l FILE -i SECS -p PID] <pci-bdf> [...]\n", argv[0]); return 2; }
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { for (int i = optind; i < argc; i++) printf("%s vram=NA hotspot=NA\n", argv[i]); perror("/dev/mem"); return 1; }
    if (!loopfile) { for (int i = optind; i < argc; i++) one(stdout, fd, argv[i]); return 0; }
    char tmp[4096]; snprintf(tmp, sizeof tmp, "%s.tmp", loopfile);
    for (;;) {
        if (watch && kill(watch, 0) != 0) break;
        // runs as root, writing into a folder the user owns: never follow a planted symlink
        unlink(tmp);
        int wfd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
        if (wfd < 0) return 1;
        FILE *f = fdopen(wfd, "w"); if (!f) { close(wfd); return 1; }
        for (int i = optind; i < argc; i++) one(f, fd, argv[i]);
        fclose(f); rename(tmp, loopfile);
        sleep(secs > 0 ? secs : 2);
    }
    return 0;
}
