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

#define DEBUG_SOCKET
#define MAX_CLIENTS 64
#define MAX_CMD_LEN 1024

typedef struct {
    int fd;
    char recv_buff[MAX_CMD_LEN];
    int recv_pos;
    int active;
} client_t;

static client_t clients[MAX_CLIENTS];
static int listen_fd = -1;

static void init_clients() {
    int i;
    for (i = 0; i < MAX_CLIENTS; i++) {
        clients[i].fd = -1;
        clients[i].recv_pos = 0;
        clients[i].active = 0;
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

static int find_client_by_fd(int fd) {
    int i;
    for (i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].active && clients[i].fd == fd) return i;
    }
    return -1;
}

// ========== 新增：校验fd是否有效（供SV调用） ==========
int sv_socket_is_valid_fd(int fd) {
    return (find_client_by_fd(fd) != -1) ? 1 : 0;
}

int sv_socket_init(const char* ip, int port) {
    init_clients();
    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        perror("socket init failed");
        return -1;
    }
    int opt = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    // 设置listen_fd为非阻塞
    int flags = fcntl(listen_fd, F_GETFL, 0);
    if (flags == -1) {
        perror("fcntl get listen_fd flags failed");
        close(listen_fd);
        return -1;
    }
    if (fcntl(listen_fd, F_SETFL, flags | O_NONBLOCK) == -1) {
        perror("fcntl set listen_fd nonblock failed");
        close(listen_fd);
        return -1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (ip == NULL || strlen(ip) == 0 || strcmp(ip, "0.0.0.0") == 0) {
        addr.sin_addr.s_addr = INADDR_ANY;
    } else {
        if (inet_pton(AF_INET, ip, &addr.sin_addr) <= 0) {
            perror("inet_pton failed");
            close(listen_fd);
            return -1;
        }
    }
    if (bind(listen_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind failed");
        close(listen_fd);
        return -1;
    }
    if (listen(listen_fd, 5) < 0) {
        perror("listen failed");
        close(listen_fd);
        return -1;
    }
#ifdef DEBUG_SOCKET
    printf("[DPI DEBUG] socket init success, listen fd=%d (nonblock enabled)\n", listen_fd);
#endif
    return listen_fd;
}

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
    memset(clients[idx].recv_buff, 0, MAX_CMD_LEN);
#ifdef DEBUG_SOCKET
    printf("[DPI DEBUG] new client connect, fd=%d, idx=%d\n", conn_fd, idx);
#endif
    return conn_fd;
}

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

// 优化后的非阻塞send逻辑
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

    int len = strlen(msg);
    char *buff = malloc(len + 2); // 保留len+2，兼容\n和\0
    if (!buff) {
        perror("[DPI ERROR] malloc failed");
        return -1;
    }
    snprintf(buff, len + 2, "%s\n", msg);
    int total_len = strlen(buff); // 实际要发送的长度（含\n）

#ifdef DEBUG_SOCKET
    printf("[DPI DEBUG] Preparing to send to fd=%d: %s (len=%d)\n", fd, buff, total_len);
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
        printf("[DPI DEBUG] fd=%d sent %zd bytes, total_sent=%zu/%d\n", fd, n, total_sent, total_len);
        // 发送成功后：
        printf("[DPI DEBUG] fd=%d send success, total_retry=%d, total_elapsed=%dms\n", 
            fd, retry, retry*RETRY_INTERVAL);
#endif
    }

    free(buff);

    // 重试耗尽仍未发送完成：仅警告，不关闭fd（留给后续处理）
    if (retry >= MAX_RETRY) {
        printf("[DPI WARNING] fd=%d send retry exhausted (%d times), sent %zu/%d bytes (not close fd)\n", 
               fd, MAX_RETRY, total_sent, total_len);
        return total_sent; // 返回已发送的字节数，而非-1
    }

    return total_sent;
}

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
        clients[idx].recv_pos = 0;
        memset(clients[idx].recv_buff, 0, MAX_CMD_LEN);
    }
}
