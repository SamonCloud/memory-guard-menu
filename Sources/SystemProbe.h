#pragma once
#include <stdint.h>

typedef struct {
    int32_t pid;
    int32_t parent;
    uint64_t start_seconds;
    uint64_t footprint;
    int footprint_valid;
    char path[4096];
} MGProcess;

typedef struct {
    int pressure; /* 1 normal, 2 warning, 4 critical; -1 unavailable */
    int pressure_errno;
    uint64_t physical;
    uint64_t compressed;
    uint64_t swap;
    int vm_valid;
    int swap_valid;
} MGSystem;

MGSystem mg_system(void);
MGProcess *mg_processes(int *count, int *unreadable);
void mg_free_processes(MGProcess *processes);
