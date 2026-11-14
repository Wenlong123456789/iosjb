#include "../Sources/IOSJB-Bridging-Header.h"

#include <stdio.h>
#include <unistd.h>

void iosjb_swift_log(const char *message) {
    if (message != NULL) {
        puts(message);
    }
}

int main(void) {
    if (iosjb_start(IOSJB_MODE_ORACLE, 5, 6, 8, 100) != 0) {
        fputs("iosjb_start failed\n", stderr);
        return 1;
    }

    int waited_ms = 0;
    while (iosjb_is_running() && waited_ms < 15000) {
        usleep(10000);
        waited_ms += 10;
    }
    if (iosjb_is_running()) {
        iosjb_stop();
        fputs("host smoke: timeout\n", stderr);
        return 2;
    }
    puts("host smoke: PASS");
    return 0;
}

