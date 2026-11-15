/* src/c/runtime：SV TCP bridge 的非阻塞 socket、认证及 MHPI Tcl 入口。
 * 本模块拥有进程唯一 listener 和客户端表；仅显式启动时创建 listener，失败不发布半成品。
 * OS fd/auth 属于当前进程，不能把 live socket 的仿真快照当作可恢复外部资源。
 * 客户端由 close/断连路径回收；abort_listener 只回收尚未接受连接的启动失败资源。
 */
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

/*
 * The VCS UCLI interpreter is embedded in libvcsucli. It is intentionally
 * resolved at runtime: the socket bridge must still link/run in a plain
 * simv that does not expose the UCLI entry point. Only the single SV socket
 * executor calls this function in production, but the mutex also serializes
 * an accidental second control caller. The returned text is copied before
 * releasing the lock because the MHPI API owns its result storage.
 */
typedef char *(*aip_ucli_tcl_exec_fn)(const char *script);
static pthread_mutex_t aip_ucli_tcl_lock = PTHREAD_MUTEX_INITIALIZER;

/* 只匹配完整 aip_watch 名称，让公共求值器在原始脚本两侧设置注册标记；
 * 保留原 DPI ABI，不增加会破坏旧 C 对象兼容性的第二个入口。空指针不匹配。 */
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

/* 在互斥锁内调用宿主 MHPI 并复制结果；返回线程持有的缓冲区，下一次调用覆盖。
 * 空脚本/缺少 UCLI API 返回明确错误；watch 注册标记独立于用户脚本文本，避免拼接转义。 */
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
    /*
     * Do not construct a Tcl wrapper around user input here: braces/quotes in
     * ctx= content would make that an injection and escaping it portably is
     * error-prone.  The two fixed Tcl calls bracket the original request and
     * expose a marker consumed only by aip_watch.  Copy the request result
     * before the cleanup call because MHPI owns a single result buffer.
     */
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

/* 对外 DPI 求值入口：识别 watch 注册后转交公共求值器，返回值生命周期同上。 */
const char *sv_socket_eval_tcl(const char *script) {
    return sv_socket_eval_tcl_common(script, aip_is_watch_registration(script));
}

/* 仅在首次 listener 完整初始化成功后清空客户端槽；不得对活动 listener 重复调用。 */
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

/* 查找尚未占用的槽，表满返回 -1；不改变槽状态，调用者负责初始化。 */
static int find_free_client() {
    int i;
    for (i = 0; i < MAX_CLIENTS; i++) {
        if (!clients[i].active) return i;
    }
    return -1;
}

/* 只查找活动槽，失效或未知 fd 返回 -1，避免使用断开连接留下的旧记录。 */
static int find_client_by_fd(int fd) {
    int i;
    for (i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].active && clients[i].fd == fd) return i;
    }
    return -1;
}

/* 检查 fd 是否仍在活动客户端表中，供 SV 在异步命令完成后决定是否可以回包。 */
int sv_socket_is_valid_fd(int fd) {
    return (find_client_by_fd(fd) != -1) ? 1 : 0;
}

/* 返回当前连接认证位；未知 fd 返回 -1，绝不视为已认证。 */
int sv_socket_is_authenticated(int fd) {
    int idx = find_client_by_fd(fd);
    return (idx == -1) ? -1 : clients[idx].authenticated;
}

/* 解析十进制 32 位 key 并与进程 key 比较；未知连接、空串、尾随字符或越界值失败。
 * SV 已剥离外围空白；成功只设置当前连接认证位，不影响其它客户端。 */
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

/* 读取当前进程 key 的数值表示；listener 成功创建前为零。 */
unsigned int sv_socket_get_auth_key(void) {
    return (unsigned int)auth_key;
}

/* 以十进制供 SV 展示认证 key；静态缓冲区由本模块持有，下次调用覆盖。 */
const char *sv_socket_get_auth_key_text(void) {
    static char text[16];
    snprintf(text, sizeof(text), "%u", (unsigned int)auth_key);
    return text;
}

/* 优先从系统随机源生成非零 key；读取失败时以时间/进程数据退化生成，不持有文件。 */
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

/* 显式创建进程唯一 listener。已存在时拒绝且不改 clients/auth；失败关闭本次局部 fd。
 * 完整 bind/listen 成功后才发布全局句柄和新认证 key，允许未成功的调用安全重试。
 */
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

/* 仅供 SV 启动后端口查询失败回收。必须匹配本进程刚创建的 listener，
 * 不能拿任意数字关闭其它资源；已有客户端则拒绝，避免变成通用 stop/restart 接口。
 */
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

/* 查询实际绑定端口，尤其供 port=0 的动态分配使用；错误/非 IPv4 返回 -1。
 * 调用者必须在发布 endpoint 前查询成功，失败则回收本次尚未使用的 listener。 */
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

/* 非阻塞接受连接并分配未认证客户端槽；-2 表示暂无连接，-3 表满，-1 系统错误。
 * 表满立即关闭本次新 fd；成功后客户端表持有该 fd，直到断连/显式 close。 */
int sv_socket_accept_nonblock(int listen_fd) {
    struct sockaddr_in client_addr;
    socklen_t len = sizeof(client_addr);
    int conn_fd = accept(listen_fd, (struct sockaddr*)&client_addr, &len);
    
    if (conn_fd < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -2; // 无新连接
        else {
            perror("accept failed");
            return -1; // 错误
        }
    }
    // 设置客户端fd为非阻塞
    int flags = fcntl(conn_fd, F_GETFL, 0);
    fcntl(conn_fd, F_SETFL, flags | O_NONBLOCK);
    
    int idx = find_free_client();
    if (idx == -1) {
        close(conn_fd);
#ifdef DEBUG_SOCKET
        printf("[DPI DEBUG] no free client slot, close fd=%d\n", conn_fd);
#endif
        return -3; // 客户端满
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

/* 从客户端接收缓冲提取一行，剩余数据保留给后续调用；0 表示命令尚不完整。
 * 参数错误、未知连接或断连返回 -1；调用方负责结束 handler 并回收客户端。 */
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
            // 清理客户端状态（关键修复）
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
        // 清理客户端状态（关键修复）
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

    // ========== 核心修复：用memchr限定查找范围为已接收的字节数 ==========
    char *newline = memchr(c->recv_buff, '\n', c->recv_pos);
    if (newline == NULL) {
        return 0;
    }

    *newline = '\0';
    int cmd_len = strlen(c->recv_buff);
    if (cmd_len == 0) {
        // 空指令，重置缓冲区
        c->recv_pos = 0;
        memset(c->recv_buff, 0, MAX_CMD_LEN);
        return 0;
    }

    // 安全拷贝指令到输出缓冲区
    strncpy(buff, c->recv_buff, maxlen - 1);
    buff[maxlen - 1] = '\0';
#ifdef DEBUG_SOCKET
    printf("[DPI DEBUG] client fd=%d get full cmd: %s (copied to SV buff)\n", fd, buff);
#endif

    // 计算剩余未处理的字节数，并移动到缓冲区头部
    int newline_pos = newline - c->recv_buff; // 换行符的索引位置
    int remain = c->recv_pos - newline_pos - 1;
    if (remain > 0) {
        // 移动剩余数据到缓冲区开头
        memmove(c->recv_buff, newline + 1, remain);
        // 清空剩余区域，避免残留
        memset(c->recv_buff + remain, 0, MAX_CMD_LEN - remain);
        c->recv_pos = remain;
#ifdef DEBUG_SOCKET
        printf("[DPI DEBUG] client fd=%d remain data len=%d, buff=%.*s\n", 
               fd, remain, remain, c->recv_buff);
#endif
    } else {
        // 无剩余数据，完全重置缓冲区
        c->recv_pos = 0;
        memset(c->recv_buff, 0, MAX_CMD_LEN);
    }

    return cmd_len;
}

// 封装：检测fd是否可写（非阻塞send前必备）
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
        return 0; // 错误，不可写
    } else if (ret == 0) {
        printf("[DPI DEBUG] fd=%d writable timeout (%dms)\n", fd, timeout_ms);
        return 0; // 超时，不可写
    }
    return FD_ISSET(fd, &writefds) ? 1 : 0; // 可写返回1
}

/* 为回复附加换行并有限重试发送；本函数持有临时缓冲，所有退出路径释放。
 * 返回已发送字节数或 -1；重试耗尽保留连接，由上层决定后续处理。 */
int sv_socket_send(int fd, const char* msg) {
    if (msg == NULL || strlen(msg) == 0) {
        printf("[DPI ERROR] invalid send msg: %p\n", msg);
        return -1;
    }

    // 先校验fd是否有效
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
    const int MAX_RETRY = 50;    // 最多重试50次
    const int RETRY_INTERVAL = 10; // 每次重试间隔10ms（总超时50*10=500ms）
    int retry = 0;

    while (total_sent < total_len && retry < MAX_RETRY) {
        // 第一步：检测fd是否可写（避免盲目send导致EAGAIN）
        if (!is_fd_writable(fd, RETRY_INTERVAL)) {
            retry++;
            continue;
        }

        // 第二步：可写时调用send
        ssize_t n = send(fd, buff + total_sent, total_len - total_sent, MSG_NOSIGNAL);
        if (n < 0) {
            // 区分EAGAIN（暂时失败）和真错误（永久失败）
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                printf("[DPI DEBUG] fd=%d send EAGAIN, retry=%d/%d\n", fd, retry, MAX_RETRY);
                retry++;
                usleep(RETRY_INTERVAL * 1000); // 等待10ms重试
                continue;
            } else {
                // 真错误（如客户端主动断开：ECONNRESET），才关fd
                perror("[DPI ERROR] send failed (fatal)");
                free(buff);
                close(fd);
                // 清理状态
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
            // 优化后的日志：记录每次重试和最终耗时
#ifdef DEBUG_SOCKET
            printf("[DPI DEBUG] fd=%d send EAGAIN, retry=%d/%d, elapsed=%dms\n", 
                fd, retry, MAX_RETRY, retry*RETRY_INTERVAL);
#endif
            continue;
        }

        // 发送成功，累计字节数
        total_sent += n;
        retry = 0; // 重置重试次数
#ifdef DEBUG_SOCKET
        printf("[DPI DEBUG] fd=%d sent %zd bytes, total_sent=%zu/%zu\n", fd, n, total_sent, total_len);
        // 发送成功后：
        printf("[DPI DEBUG] fd=%d send success, total_retry=%d, total_elapsed=%dms\n", 
            fd, retry, retry*RETRY_INTERVAL);
#endif
    }

    free(buff);

    // 重试耗尽仍未发送完成：仅警告，不关闭fd（留给后续处理）
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
        // 确保状态清理
        clients[idx].active = 0;
        clients[idx].fd = -1;
        clients[idx].authenticated = 0;
        clients[idx].recv_pos = 0;
        memset(clients[idx].recv_buff, 0, MAX_CMD_LEN);
    }
}
