#ifndef IOSJB_BRIDGING_HEADER_H
#define IOSJB_BRIDGING_HEADER_H

#include <stdint.h>

enum {
    IOSJB_MODE_ORACLE = 0,
    IOSJB_MODE_RECLAIM = 1,
    IOSJB_MODE_COMBO = 2
};

int32_t iosjb_start(int32_t mode,
                    int32_t iterations,
                    int32_t senders,
                    int32_t spray_count,
                    int32_t close_delay_us);

void iosjb_stop(void);
int32_t iosjb_is_running(void);
const char *iosjb_version(void);

#endif

