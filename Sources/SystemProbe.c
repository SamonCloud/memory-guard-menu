#include "SystemProbe.h"
#include <libproc.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>

MGSystem mg_system(void) {
    MGSystem result = { .pressure = -1 };
    int pressure = 0;
    size_t size = sizeof(pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, NULL, 0) == 0)
        result.pressure = pressure;
    else result.pressure_errno = errno;
    size = sizeof(result.physical);
    sysctlbyname("hw.memsize", &result.physical, &size, NULL, 0);
    struct xsw_usage swap = {0};
    size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) {
        result.swap = swap.xsu_used;
        result.swap_valid = 1;
    }
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    mach_port_t host = mach_host_self();
    vm_size_t page_size = 0;
    if (host_page_size(host, &page_size) == KERN_SUCCESS &&
        host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS) {
        result.compressed = (uint64_t)vm.compressor_page_count * page_size;
        result.vm_valid = 1;
    }
    mach_port_deallocate(mach_task_self(), host);
    return result;
}

MGProcess *mg_processes(int *count, int *unreadable) {
    *count = 0;
    *unreadable = 0;
    int capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0) { *unreadable = -1; return NULL; }
    capacity += 256;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    MGProcess *items = calloc((size_t)capacity, sizeof(MGProcess));
    if (!pids || !items) { free(pids); free(items); *unreadable = -1; return NULL; }
    int length = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    if (length <= 0) { free(pids); free(items); *unreadable = -1; return NULL; }
    if (length > capacity) length = capacity;
    for (int i = 0; i < length; i++) {
        struct proc_bsdinfo info = {0};
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) continue;
        if (info.pbi_uid != getuid()) continue;
        MGProcess *item = &items[(*count)++];
        item->pid = pids[i];
        item->parent = (int32_t)info.pbi_ppid;
        item->start_seconds = info.pbi_start_tvsec;
        proc_pidpath(pids[i], item->path, sizeof(item->path));
        struct rusage_info_v2 usage = {0};
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&usage) == 0) {
            item->footprint = usage.ri_phys_footprint;
            item->footprint_valid = 1;
        } else (*unreadable)++;
    }
    free(pids);
    return items;
}

void mg_free_processes(MGProcess *processes) { free(processes); }
