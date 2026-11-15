/* SV TCP bridge 的非阻塞 socket、认证与 MHPI Tcl 入口；listener 进程唯一，仅显式启动时创建，失败不发布半成品。
 * OS fd/auth 属于当前进程：live socket 的仿真快照不是可恢复的外部资源。 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <sys/time.h>
#include <pthread.h>
#include <dlfcn.h>
#include <stdint.h>
#include <time.h>

/* Define DEBUG_SOCKET explicitly when verbose transport diagnostics are needed. */
#define MAX_CLIENTS 64
#define MAX_CMD_LEN 1024

typedef struct {
    int fd;
    char recv_buff[MAX_CMD_LEN];
    int recv_pos;
    int active;
    int authenticated;
} client_t;

static client_t clients[MAX_CLIENTS];
static int listen_fd = -1;
static uint32_t auth_key;

/* The UCLI interpreter lives in libvcsucli and is resolved at runtime so the bridge still links/runs in a
 * plain simv without the UCLI entry point. The mutex guards against an accidental second caller; MHPI owns
 * its result storage, so the text is copied before unlocking. */
typedef char *(*aip_ucli_tcl_exec_fn)(const char *script);
static pthread_mutex_t aip_ucli_tcl_lock = PTHREAD_MUTEX_INITIALIZER;

/* 只匹配完整 aip_watch 名称；借公共求值器设置注册标记，从而保留原 DPI ABI（不增加第二个入口）。 */
static int aip_is_watch_registration(const char *script) {
    static const char name[] = "aip_watch";
    const char *p = script;
    size_t i;
    if (p == NULL) return 0;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    for (i = 0; name[i] != '\0'; i++) {
        if (p[i] != name[i]) return 0;
    }
    return p[i] == '\0' || p[i] == ' ' || p[i] == '\t' ||
           p[i] == '\r' || p[i] == '\n';
}

/* 返回值指向本模块缓冲区，下一次调用覆盖。 */
static const char *sv_socket_eval_tcl_common(const char *script,
                                             int watch_registration) {
    static _Thread_local char result[4096];
    aip_ucli_tcl_exec_fn exec_tcl;
    char *raw;
    char raw_copy[sizeof(result)];

    result[0] = '\0';
    if (script == NULL || script[0] == '\0') {
        snprintf(result, sizeof(result), "ERROR: empty Tcl script");
        return result;
    }

    exec_tcl = (aip_ucli_tcl_exec_fn)dlsym(RTLD_DEFAULT,
                                            "mhpi_ucliTclExecNoPrint");
    if (exec_tcl == NULL) {
        snprintf(result, sizeof(result),
                 "ERROR: VCS UCLI Tcl API is unavailable (start simv with UCLI support)");
        return result;
    }

    pthread_mutex_lock(&aip_ucli_tcl_lock);
    /* Never wrap user input in Tcl here (braces/quotes in ctx= would allow injection). Two fixed calls
     * bracket the original request and expose a marker read only by aip_watch; the request result is
     * copied before the cleanup call because MHPI owns a single result buffer. */
    if (watch_registration) {
        (void)exec_tcl("set ::_aip_watch_tcp_mode 1");
    }
    raw = exec_tcl(script);
    if (raw != NULL && raw[0] != '\0') {
        strncpy(raw_copy, raw, sizeof(raw_copy) - 1);
        raw_copy[sizeof(raw_copy) - 1] = '\0';
    } else {
        /* Most successful UCLI commands (for example `run`) have no result
         * text.  An empty MHPI result is therefore a successful command, not
         * a transport failure. */
        snprintf(raw_copy, sizeof(raw_copy), "OK");
    }
    if (watch_registration) {
        (void)exec_tcl("unset -nocomplain ::_aip_watch_tcp_mode");
    }
    strncpy(result, raw_copy, sizeof(result) - 1);
    result[sizeof(result) - 1] = '\0';
    pthread_mutex_unlock(&aip_ucli_tcl_lock);
    return result;
}

const char *sv_socket_eval_tcl(const char *script) {
    return sv_socket_eval_tcl_common(script, aip_is_watch_registration(script));
}

/* 仅在首次 listener 初始化成功后调用；不得对活动 listener 重复调用。 */
static void init_clients() {
    int i;
    for (i = 0; i < MAX_CLIENTS; i++) {
        clients[i].fd = -1;
        clients[i].recv_pos = 0;
        clients[i].active = 0;
        clients[i].authenticated = 0;
        memset(clients[i].recv_buff, 0, MAX_CMD_LEN);
    }
}

static int find_free_client() {
    int i;
    for (i = 0; i < MAX_CLIENTS; i++) {
        if (!clients[i].active) return i;
    }
    return -1;
}

/* 只查活动槽，避免命中断连遗留的旧记录。 */
static int find_client_by_fd(int fd) {
    int i;
    for (i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].active && clients[i].fd == fd) return i;
    }
    return -1;
}

/* 供 SV 在异步命令完成后判断是否还能回包。 */
int sv_socket_is_valid_fd(int fd) {
    return (find_client_by_fd(fd) != -1) ? 1 : 0;
}

/* 未知 fd 返回 -1，绝不视为已认证。 */
int sv_socket_is_authenticated(int fd) {
    int idx = find_client_by_fd(fd);
    return (idx == -1) ? -1 : clients[idx].authenticated;
}

/* 十进制 32 位 key，空串/尾随字符/越界均失败；成功只设置当前连接的认证位。 */
int sv_socket_authenticate(int fd, const char *key_text) {
    int idx = find_client_by_fd(fd);
    char *end = NULL;
    unsigned long long value;

    if (idx == -1 || key_text == NULL || key_text[0] == '\0') return 0;
    value = strtoull(key_text, &end, 10);
    if (end == key_text || *end != '\0' || value > 0xffffffffULL ||
        (uint32_t)value != auth_key)
        return 0;
    clients[idx].authenticated = 1;
    return 1;
}

/* listener 创建成功前为 0。 */
unsigned int sv_socket_get_auth_key(void) {
    return (unsigned int)auth_key;
}

/* 静态缓冲区，下次调用覆盖。 */
const char *sv_socket_get_auth_key_text(void) {
    static char text[16];
    snprintf(text, sizeof(text), "%u", (unsigned int)auth_key);
    return text;
}

/* 优先用系统随机源；失败时退化为时间/进程数据。 */
static uint32_t generate_auth_key(void) {
    uint32_t value = 0;
    FILE *random_file = fopen("/dev/urandom", "rb");
    if (random_file != NULL) {
        if (fread(&value, sizeof(value), 1, random_file) != 1) value = 0;
        fclose(random_file);
    }
    if (value == 0) {
        struct timeval now;
        gettimeofday(&now, NULL);
        value = (uint32_t)now.tv_sec ^ (uint32_t)now.tv_usec ^
                (uint32_t)getpid() ^ (uint32_t)(uintptr_t)&value;
    }
    return value == 0 ? 1U : value;
}

/* 已有 listener 时拒绝且不改 clients/auth；bind/listen 全部成功后才发布句柄与新 key，失败可安全重试。 */
int sv_socket_init(const char* ip, int port) {
    int candidate_fd;
    int opt = 1;
    int flags;
    struct sockaddr_in addr;

    if (listen_fd >= 0) {
        errno = EALREADY;
        perror("AIP socket listener already exists");
        return -1;
    }
    if (port < 0 || port > 65535) {
        errno = EINVAL;
        perror("AIP socket invalid port");
        return -1;
    }
    candidate_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (candidate_fd < 0) { perror("AIP socket create failed"); return -1; }
    if (setsockopt(candidate_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0)
        goto failed;
    flags = fcntl(candidate_fd, F_GETFL, 0);
    if (flags == -1 || fcntl(candidate_fd, F_SETFL, flags | O_NONBLOCK) == -1)
        goto failed;

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (ip == NULL || strlen(ip) == 0 || strcmp(ip, "0.0.0.0") == 0) {
        addr.sin_addr.s_addr = INADDR_ANY;
    } else if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
        errno = EINVAL;
        goto failed;
    }
    if (bind(candidate_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0 ||
        listen(candidate_fd, 5) < 0)
        goto failed;

    init_clients();
    auth_key = generate_auth_key();
    listen_fd = candidate_fd;
    return listen_fd;

failed:
    /* close 可能改变 errno；保留真正的初始化失败原因供宿主诊断。 */
    {
        int saved_errno = errno;
        close(candidate_fd);
        errno = saved_errno;
        perror("AIP socket init failed");
    }
    return -1;
}

/* 仅供 SV 在端口查询失败时回收刚创建的 listener：fd 必须匹配且无客户端，不是通用 stop/restart 接口。 */
void sv_socket_abort_listener(int fd) {
    int i;
    if (fd < 0 || fd != listen_fd) return;
    for (i = 0; i < MAX_CLIENTS; ++i) {
        if (clients[i].active) return;
    }
    close(listen_fd);
    listen_fd = -1;
    auth_key = 0;
}

/* 查询实际绑定端口（port=0 动态分配）；错误或非 IPv4 返回 -1。 */
int sv_socket_get_bound_port(int fd) {
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);

    memset(&addr, 0, sizeof(addr));
    if (fd < 0 || getsockname(fd, (struct sockaddr *)&addr, &addr_len) < 0) {
        return -1;
    }
    if (addr.sin_family != AF_INET) {
        return -1;
    }
    return (int)ntohs(addr.sin_port);
}

/* 返回 -2 暂无连接、-3 表满（新 fd 立即关闭）、-1 系统错误；成功后客户端表持有该 fd。 */
int sv_socket_accept_nonblock(int listen_fd) {
    struct sockaddr_in client_addr;
    socklen_t len = sizeof(client_addr);
    int conn_fd = accept(listen_fd, (struct sockaddr*)&client_addr, &len);
    
    if (conn_fd < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -2;
        else {
            perror("accept failed");
            return -1;
        }
    }
    int flags = fcntl(conn_fd, F_GETFL, 0);
    fcntl(conn_fd, F_SETFL, flags | O_NONBLOCK);
    
    int idx = find_free_client();
    if (idx == -1) {
        close(conn_fd);
#ifdef DEBUG_SOCKET
        printf("[DPI DEBUG] no free client slot, close fd=%d\n", conn_fd);
#endif
        return -3;
    }
    clients[idx].fd = conn_fd;
    clients[idx].recv_pos = 0;
    clients[idx].active = 1;
    clients[idx].authenticated = 0;
    memset(clients[idx].recv_buff, 0, MAX_CMD_LEN);
#ifdef DEBUG_SOCKET
    printf("[DPI DEBUG] new client connect, fd=%d, idx=%d\n", conn_fd, idx);
#endif
    return conn_fd;
}

/* 提取一行，剩余数据留给后续调用；0 = 命令未完整，-1 = 参数错误/未知连接/断连（调用方回收客户端）。 */
int sv_socket_recv_nonblock(int fd, char* buff, int maxlen) {
    if (buff == NULL || maxlen <= 0) {
        printf("[DPI ERROR] invalid param: buff=%p, maxlen=%d\n", buff, maxlen);
        return -1;
    }
    int idx = find_client_by_fd(fd);
    if (idx == -1) {
        printf("[DPI ERROR] client fd=%d not found\n", fd);
        return -1;
    }
    client_t *c = &clients[idx];
    int avail = MAX_CMD_LEN - c->recv_pos - 1;
    if (avail <= 0) {
#ifdef DEBUG_SOCKET
        printf("[DPI DEBUG] client fd=%d buff full, reset pos\n", fd);
#endif
        c->recv_pos = 0;
        memset(c->recv_buff, 0, MAX_CMD_LEN);
        return 0;
    }

    int n = recv(fd, c->recv_buff + c->recv_pos, avail, 0);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return 0;
        } else {
            perror("[DPI ERROR] recv failed");
            close(fd);
            c->active = 0;
            c->fd = -1;
            c->authenticated = 0;
            c->recv_pos = 0;
            memset(c->recv_buff, 0, MAX_CMD_LEN);
            return -1;
        }
    } else if (n == 0) {
#ifdef DEBUG_SOCKET
        printf("[DPI DEBUG] client fd=%d closed connection\n", fd);
#endif
        close(fd);
        c->active = 0;
        c->fd = -1;
        c->authenticated = 0;
        c->recv_pos = 0;
        memset(c->recv_buff, 0, MAX_CMD_LEN);
        return -1;
    }

    c->recv_pos += n;
#ifdef DEBUG_SOCKET
    printf("[DPI DEBUG] client fd=%d recv %d bytes, total pos=%d, buff=%.*s\n", 
           fd, n, c->recv_pos, c->recv_pos, c->recv_buff); // 仅打印有效数据
#endif

    // 只在已接收的 recv_pos 字节内查找换行。
    char *newline = memchr(c->recv_buff, '\n', c->recv_pos);
    if (newline == NULL) {
        return 0;
    }

    *newline = '\0';
    int cmd_len = strlen(c->recv_buff);
    if (cmd_len == 0) {
        c->recv_pos = 0;
        memset(c->recv_buff, 0, MAX_CMD_LEN);
        return 0;
    }

    strncpy(buff, c->recv_buff, maxlen - 1);
    buff[maxlen - 1] = '\0';
#ifdef DEBUG_SOCKET
    printf("[DPI DEBUG] client fd=%d get full cmd: %s (copied to SV buff)\n", fd, buff);
#endif

    int newline_pos = newline - c->recv_buff;
    int remain = c->recv_pos - newline_pos - 1;
    if (remain > 0) {
        memmove(c->recv_buff, newline + 1, remain);
        // 清零尾部，避免残留
        memset(c->recv_buff + remain, 0, MAX_CMD_LEN - remain);
        c->recv_pos = remain;
#ifdef DEBUG_SOCKET
        printf("[DPI DEBUG] client fd=%d remain data len=%d, buff=%.*s\n", 
               fd, remain, remain, c->recv_buff);
#endif
    } else {
        c->recv_pos = 0;
        memset(c->recv_buff, 0, MAX_CMD_LEN);
    }

    return cmd_len;
}

static int is_fd_writable(int fd, int timeout_ms) {
    fd_set writefds;
    FD_ZERO(&writefds);
    FD_SET(fd, &writefds);

    struct timeval timeout;
    timeout.tv_sec = timeout_ms / 1000;
    timeout.tv_usec = (timeout_ms % 1000) * 1000;

    int ret = select(fd + 1, NULL, &writefds, NULL, &timeout);
    if (ret < 0) {
        perror("[DPI ERROR] select for writable failed");
        return 0;
    } else if (ret == 0) {
        printf("[DPI DEBUG] fd=%d writable timeout (%dms)\n", fd, timeout_ms);
        return 0;
    }
    return FD_ISSET(fd, &writefds) ? 1 : 0;
}

/* 附加换行后有限重试发送；返回已发送字节数或 -1。重试耗尽时保留连接，由上层决定。 */
int sv_socket_send(int fd, const char* msg) {
    if (msg == NULL || strlen(msg) == 0) {
        printf("[DPI ERROR] invalid send msg: %p\n", msg);
        return -1;
    }

    int idx = find_client_by_fd(fd);
    if (idx == -1) {
        printf("[DPI ERROR] client fd=%d not found (send failed)\n", fd);
        return -1;
    }

    size_t len = strlen(msg);
    char *buff = malloc(len + 2); // 保留len+2，兼容\n和\0
    if (!buff) {
        perror("[DPI ERROR] malloc failed");
        return -1;
    }
    snprintf(buff, len + 2, "%s\n", msg);
    size_t total_len = strlen(buff); // 实际要发送的长度（含\n）

#ifdef DEBUG_SOCKET
    printf("[DPI DEBUG] Preparing to send to fd=%d: %s (len=%zu)\n", fd, buff, total_len);
#endif

    size_t total_sent = 0;
    const int MAX_RETRY = 50;
    const int RETRY_INTERVAL = 10; // 每次重试间隔10ms（总超时50*10=500ms）
    int retry = 0;

    while (total_sent < total_len && retry < MAX_RETRY) {
        // 先确认可写，避免盲目 send 得到 EAGAIN。
        if (!is_fd_writable(fd, RETRY_INTERVAL)) {
            retry++;
            continue;
        }

        ssize_t n = send(fd, buff + total_sent, total_len - total_sent, MSG_NOSIGNAL);
        if (n < 0) {
            // EAGAIN 为暂时失败，其余为永久失败。
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                printf("[DPI DEBUG] fd=%d send EAGAIN, retry=%d/%d\n", fd, retry, MAX_RETRY);
                retry++;
                usleep(RETRY_INTERVAL * 1000);
                continue;
            } else {
                // 真错误（如客户端主动断开：ECONNRESET），才关fd
                perror("[DPI ERROR] send failed (fatal)");
                free(buff);
                close(fd);
                clients[idx].active = 0;
                clients[idx].fd = -1;
                clients[idx].authenticated = 0;
                clients[idx].recv_pos = 0;
                memset(clients[idx].recv_buff, 0, MAX_CMD_LEN);
                return -1;
            }
        } else if (n == 0) {
            retry++;
            usleep(RETRY_INTERVAL * 1000);
#ifdef DEBUG_SOCKET
            printf("[DPI DEBUG] fd=%d send EAGAIN, retry=%d/%d, elapsed=%dms\n", 
                fd, retry, MAX_RETRY, retry*RETRY_INTERVAL);
#endif
            continue;
        }

        total_sent += n;
        retry = 0;
#ifdef DEBUG_SOCKET
        printf("[DPI DEBUG] fd=%d sent %zd bytes, total_sent=%zu/%zu\n", fd, n, total_sent, total_len);
        printf("[DPI DEBUG] fd=%d send success, total_retry=%d, total_elapsed=%dms\n", 
            fd, retry, retry*RETRY_INTERVAL);
#endif
    }

    free(buff);

    // 重试耗尽：仅警告，不关闭 fd。
    if (retry >= MAX_RETRY) {
        printf("[DPI WARNING] fd=%d send retry exhausted (%d times), sent %zu/%zu bytes (not close fd)\n",
               fd, MAX_RETRY, total_sent, total_len);
        return (int)total_sent; // 返回已发送的字节数，而非-1
    }

    return (int)total_sent;
}

/* 关闭表内活动客户端并清空接收/认证状态；未知 fd 不操作，避免误关宿主资源。 */
void sv_socket_close(int fd) {
    int idx = find_client_by_fd(fd);
    if (idx != -1) {
#ifdef DEBUG_SOCKET
        printf("[DPI DEBUG] close client fd=%d\n", fd);
#endif
        close(fd);
        clients[idx].active = 0;
        clients[idx].fd = -1;
        clients[idx].authenticated = 0;
        clients[idx].recv_pos = 0;
        memset(clients[idx].recv_buff, 0, MAX_CMD_LEN);
    }
}
