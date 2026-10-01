// Persistent Darwin sampler: Mach deltas, anonymous memory, swap and load.
// All filesystem operations stay relative to a verified, private directory fd.
#define _DARWIN_C_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static const char *sample_error = "CPU delta unavailable";
static void stop(int sig) { (void)sig; stopping = 1; }

static bool number(const char *text, unsigned long *value) {
    if (!*text || strspn(text, "0123456789") != strlen(text)) return false;
    errno = 0;
    char *end;
    *value = strtoul(text, &end, 10);
    return !errno && !*end;
}

static void pause_ms(unsigned long ms) {
    struct timespec duration = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000000};
    while (!stopping && nanosleep(&duration, &duration) && errno == EINTR) {}
}

static int private_dir(const char *path) {
    if (mkdir(path, 0700) && errno != EEXIST) return -1;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) || info.st_uid != getuid() || (info.st_mode & 0777) != 0700) {
        close(fd);
        errno = EPERM;
        return -1;
    }
    return fd;
}

static bool cpu_ticks(host_cpu_load_info_data_t *ticks) {
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t result = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)ticks, &count);
    mach_port_deallocate(mach_task_self(), host);
    return result == KERN_SUCCESS;
}

static unsigned percent(uint64_t used, uint64_t total) {
    if (!total) return 0;
    if (used >= total) return 100;
    return (unsigned)((double)used * 100.0 / (double)total);
}

static bool sample(host_cpu_load_info_data_t *previous, unsigned *cpu,
                   unsigned *ram, unsigned *swap, double *load) {
    host_cpu_load_info_data_t ticks;
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t result = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count);
    mach_port_deallocate(mach_task_self(), host);
    uint64_t memsize;
    size_t size = sizeof(memsize);
    struct xsw_usage usage;
    size_t swap_size = sizeof(usage);
    if (result != KERN_SUCCESS || !cpu_ticks(&ticks)) {
        sample_error = "Mach counters unavailable"; errno = EPERM;
        return false;
    }
    if (sysctlbyname("hw.memsize", &memsize, &size, NULL, 0) || !memsize) {
        sample_error = "hw.memsize"; return false;
    }
    if (sysctlbyname("vm.swapusage", &usage, &swap_size, NULL, 0)) {
        sample_error = "vm.swapusage"; return false;
    }
    if (getloadavg(load, 1) != 1 || !(*load >= 0.0 && *load <= 9999.99)) {
        sample_error = "load average"; return false;
    }
    uint64_t total = 0, idle = 0;
    for (unsigned i = 0; i < CPU_STATE_MAX; i++) {
        uint32_t delta = (uint32_t)(ticks.cpu_ticks[i] - previous->cpu_ticks[i]);
        total += delta;
        if (i == CPU_STATE_IDLE) idle = delta;
    }
    if (!total) { sample_error = "CPU delta unavailable"; errno = EAGAIN; return false; }
    uint64_t anonymous = vm.internal_page_count > vm.purgeable_count
        ? vm.internal_page_count - vm.purgeable_count : 0;
    uint64_t pages = anonymous + (uint64_t)vm.wire_count + vm.compressor_page_count;
    *cpu = percent(total - idle, total);
    *ram = percent(pages * (uint64_t)vm_kernel_page_size, memsize);
    *swap = percent(usage.xsu_used, usage.xsu_total);
    *previous = ticks;
    return true;
}

static bool publish(int dir, unsigned long sequence, unsigned cpu, unsigned ram,
                    unsigned swap, double load, unsigned long ncpu) {
    char name[80], record[128];
    snprintf(name, sizeof(name), ".snapshot.%ld.%lu", (long)getpid(), sequence);
    int length = snprintf(record, sizeof(record), "v1 %lld %u %u %u %.2f %lu\n",
                          (long long)time(NULL), cpu, ram, swap, load, ncpu);
    if (length < 0 || (size_t)length >= sizeof(record)) return false;
    int fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    ssize_t written = write(fd, record, (size_t)length);
    int closed = close(fd);
    bool success = written == length && closed == 0 && renameat(dir, name, dir, "snapshot") == 0;
    if (!success) unlinkat(dir, name, 0);
    return success;
}

int main(int argc, char **argv) {
    unsigned long interval, samples = 0;
    if (argc < 3 || argc > 4 || !number(argv[1], &interval) ||
        (argc == 4 && (!number(argv[3], &samples) || !samples))) {
        fprintf(stderr, "usage: stasysmo-daemon interval_ms private_directory [sample_count]\n");
        return 2;
    }
    if (interval < 500) interval = 500;
    if (interval > 60000) interval = 60000;
    long processors = sysconf(_SC_NPROCESSORS_ONLN);
    if (processors < 1 || processors > 9999) return 1;
    int dir = private_dir(argv[2]);
    if (dir < 0) { perror("stasysmo directory"); return 1; }
    signal(SIGTERM, stop);
    signal(SIGINT, stop);
    host_cpu_load_info_data_t previous;
    if (!cpu_ticks(&previous)) { close(dir); return 1; }
    pause_ms(100); // First CPU record is a real delta, never an invented zero.
    bool warned = false;
    unsigned long published = 0;
    for (unsigned long sequence = 0; !stopping; sequence++) {
        unsigned cpu, ram, swap;
        double load;
        if (sample(&previous, &cpu, &ram, &swap, &load)) {
            if (publish(dir, sequence, cpu, ram, swap, load, (unsigned long)processors)) {
                published++;
                warned = false;
            }
        } else if (!warned) {
            fprintf(stderr, "stasysmo: sample unavailable: %s (%s)\n", sample_error, strerror(errno));
            warned = true;
        }
        // Failed samples preserve the previous generation, which then goes stale.
        if (samples && sequence + 1 >= samples) break;
        pause_ms(interval);
    }
    close(dir);
    return samples && !published ? 1 : 0;
}
