#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <readline/readline.h>
#include <readline/history.h>
#include <pwd.h>

// ========== 配置项 ==========
#define MAX_CMD_LEN    1024
#define RECONNECT_MAX  3
#define RECONNECT_DELAY 1000000
#define HISTORY_FILE   ".client_history"
#define MAX_HISTORY    100
#define CONNECT_TIMEOUT 3          // 非阻塞connect超时时间（秒）
#define SELECT_TIMEOUT_MS 200      // select 超时（毫秒），用于强制打印不完整回复

// 颜色宏
#define COLOR_RED     "\033[31m"
#define COLOR_GREEN   "\033[32m"
#define COLOR_YELLOW  "\033[33m"
#define COLOR_BLUE    "\033[34m"
#define COLOR_RESET   "\033[0m"

// 全局变量
static char g_server_ip[64] = {0};
static int  g_server_port = 0;
static char g_auth_key[64] = {0};
static int  sock = -1;               // 当前连接的socket
static volatile int running = 1;      // 控制主循环
static const char *completion_cmds[] = {"quit", "exec", "help", "status", NULL};

// 用于累积未打印回复的静态缓冲区
static char accum_buf[4096];
static size_t accum_len = 0;

static int authenticate_socket(int fd);

// ========== 工具函数 ==========
static int set_socket_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

ssize_t send_all(int sock, const char *buf, size_t len) {
    size_t total_sent = 0;
    while (total_sent < len) {
        ssize_t n = send(sock, buf + total_sent, len - total_sent, 0);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(1000);
                continue;
            }
            fprintf(stderr, COLOR_RED "[Client ERROR] send failed: %s" COLOR_RESET "\n", strerror(errno));
            return -1;
        }
        total_sent += n;
    }
    return total_sent;
}

static void trim_space(char *str) {
    if (str == NULL || strlen(str) == 0) return;
    char *start = str;
    char *end = str + strlen(str) - 1;
    while (start <= end && (*start == ' ' || *start == '\t')) start++;
    while (end >= start && (*end == ' ' || *end == '\t')) end--;
    if (start > end) str[0] = '\0';
    else {
        memmove(str, start, end - start + 1);
        str[end - start + 1] = '\0';
    }
}

static char* get_history_file_path() {
    static char path[256];
    char *home = getenv("HOME");
    if (home == NULL) home = getpwuid(getuid())->pw_dir;
    snprintf(path, sizeof(path), "%s/%s", home, HISTORY_FILE);
    return path;
}

// ========== 非阻塞connect（带超时） ==========
static int nonblock_connect(const char *ip, int port, int timeout_sec) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        fprintf(stderr, COLOR_RED "[Client ERROR] Create socket failed: %s" COLOR_RESET "\n", strerror(errno));
        return -1;
    }
    if (set_socket_nonblock(sock) < 0) {
        close(sock);
        return -1;
    }

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, ip, &addr.sin_addr) <= 0) {
        fprintf(stderr, COLOR_RED "[Client ERROR] Invalid IP: %s" COLOR_RESET "\n", ip);
        close(sock);
        return -1;
    }

    int ret = connect(sock, (struct sockaddr*)&addr, sizeof(addr));
    if (ret == 0) {
        return sock;
    } else if (errno != EINPROGRESS) {
        fprintf(stderr, COLOR_RED "[Client ERROR] Connect failed: %s" COLOR_RESET "\n", strerror(errno));
        close(sock);
        return -1;
    }

    fd_set writefds;
    FD_ZERO(&writefds);
    FD_SET(sock, &writefds);
    struct timeval timeout = {timeout_sec, 0};

    ret = select(sock + 1, NULL, &writefds, NULL, &timeout);
    if (ret <= 0) {
        fprintf(stderr, COLOR_RED "[Client ERROR] Connect timeout (%ds) / select failed" COLOR_RESET "\n", timeout_sec);
        close(sock);
        return -1;
    }

    int so_error = 0;
    socklen_t len = sizeof(so_error);
    getsockopt(sock, SOL_SOCKET, SO_ERROR, &so_error, &len);
    if (so_error != 0) {
        fprintf(stderr, COLOR_RED "[Client ERROR] Connect failed (SO_ERROR): %s" COLOR_RESET "\n", strerror(so_error));
        close(sock);
        return -1;
    }

    return sock;
}

// ========== 重连 ==========
int reconnect_server() {
    int retry = 0;
    while (retry < RECONNECT_MAX) {
        retry++;
        printf(COLOR_YELLOW "[Client RECONNECT] Retry %d/%d to %s:%d..." COLOR_RESET "\n",
               retry, RECONNECT_MAX, g_server_ip, g_server_port);

        int new_sock = nonblock_connect(g_server_ip, g_server_port, CONNECT_TIMEOUT);
        if (new_sock >= 0 && authenticate_socket(new_sock) == 0) {
            printf(COLOR_GREEN "[Client RECONNECT] Success! Continue entering commands." COLOR_RESET "\n");
            return new_sock;
        }
        if (new_sock >= 0) close(new_sock);

        usleep(RECONNECT_DELAY);
    }
    printf(COLOR_RED "[Client ERROR] Reconnect failed after %d tries" COLOR_RESET "\n", RECONNECT_MAX);
    return -1;
}

/* Wait for the one-line authentication response before readline starts.  The
 * bridge handles auth directly in the client handler, so this handshake does
 * not depend on SV simulation time advancing. */
static int authenticate_socket(int fd) {
    char send_buf[96];
    char recv_buf[256];
    size_t used = 0;
    struct timeval timeout;
    fd_set readfds;
    int ret;

    if (g_auth_key[0] == '\0') {
        fprintf(stderr, COLOR_RED "[Client ERROR] No auth key configured" COLOR_RESET "\n");
        return -1;
    }
    snprintf(send_buf, sizeof(send_buf), "auth %s\n", g_auth_key);
    if (send_all(fd, send_buf, strlen(send_buf)) < 0) return -1;

    while (used < sizeof(recv_buf) - 1) {
        FD_ZERO(&readfds);
        FD_SET(fd, &readfds);
        timeout.tv_sec = CONNECT_TIMEOUT;
        timeout.tv_usec = 0;
        ret = select(fd + 1, &readfds, NULL, NULL, &timeout);
        if (ret <= 0) {
            fprintf(stderr, COLOR_RED "[Client ERROR] Auth response timeout" COLOR_RESET "\n");
            return -1;
        }
        ret = (int)recv(fd, recv_buf + used, sizeof(recv_buf) - 1 - used, 0);
        if (ret < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, COLOR_RED "[Client ERROR] Auth receive failed: %s" COLOR_RESET "\n",
                    strerror(errno));
            return -1;
        }
        if (ret == 0) return -1;
        used += (size_t)ret;
        recv_buf[used] = '\0';
        if (strchr(recv_buf, '\n') != NULL) break;
    }
    while (used > 0 && (recv_buf[used - 1] == '\n' || recv_buf[used - 1] == '\r'))
        recv_buf[--used] = '\0';
    if (strncmp(recv_buf, "OK: AUTHENTICATED", strlen("OK: AUTHENTICATED")) != 0) {
        fprintf(stderr, COLOR_RED "[Client ERROR] Authentication rejected: %s" COLOR_RESET "\n",
                recv_buf);
        return -1;
    }
    printf(COLOR_GREEN "[Client INFO] Authenticated with auth_key=%s" COLOR_RESET "\n", g_auth_key);
    return 0;
}

static int configure_auth_key(int argc, char *argv[]) {
    const char *key = getenv("AIP_AUTH_KEY");
    char *line;

    if (argc == 5) {
        if (strcmp(argv[3], "--key") != 0 && strcmp(argv[3], "-k") != 0) return -1;
        key = argv[4];
    } else if (argc != 3) {
        return -1;
    }
    if (key == NULL || key[0] == '\0') {
        line = readline("[Client Auth Key] > ");
        if (line == NULL) return -1;
        trim_space(line);
        key = line;
        if (key[0] == '\0') {
            free(line);
            return -1;
        }
        strncpy(g_auth_key, key, sizeof(g_auth_key) - 1);
        g_auth_key[sizeof(g_auth_key) - 1] = '\0';
        free(line);
    } else {
        strncpy(g_auth_key, key, sizeof(g_auth_key) - 1);
        g_auth_key[sizeof(g_auth_key) - 1] = '\0';
    }
    return 0;
}

// ========== 打印累积的回复并重绘提示符 ==========
static void flush_accum_reply() {
    if (accum_len > 0) {
        accum_buf[accum_len] = '\0';  // 确保终止
        printf("\n" COLOR_GREEN "[Server Reply] %s" COLOR_RESET "\n", accum_buf);
        fflush(stdout);
        accum_len = 0;
        accum_buf[0] = '\0';
        // 重绘提示符
        rl_forced_update_display();
    }
}

// ========== 读取服务器数据并累积（非阻塞）==========
// 返回值：0 正常，-1 连接关闭或错误
static int read_all_server_reply(int fd) {
    if (fd < 0) return -1;

    char recv_buf[MAX_CMD_LEN + 1] = {0};
    ssize_t n;
    size_t chunk_len;

    while (1) {
        n = recv(fd, recv_buf, sizeof(recv_buf)-1, 0);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            fprintf(stderr, COLOR_RED "[Client ERROR] recv failed: %s" COLOR_RESET "\n", strerror(errno));
            return -1;
        } else if (n == 0) {
            // 对方关闭连接
            printf(COLOR_YELLOW "[Client INFO] Server disconnected" COLOR_RESET "\n");
            return -1;
        }

        recv_buf[n] = '\0';
        chunk_len = (size_t)n;

        // 追加到累积缓冲区
        if (chunk_len <= sizeof(accum_buf) - 1 - accum_len) {
            memcpy(accum_buf + accum_len, recv_buf, chunk_len);
            accum_len += chunk_len;
            accum_buf[accum_len] = '\0';  // 临时终止以便查找
        } else {
            fprintf(stderr, COLOR_YELLOW "[Client WARNING] Reply too long, truncated" COLOR_RESET "\n");
            // 缓冲区已满，强制打印
            flush_accum_reply();
            // 重新开始累积当前数据（可能丢失部分）
            accum_len = chunk_len > sizeof(accum_buf)-1 ? sizeof(accum_buf)-1 : chunk_len;
            memcpy(accum_buf, recv_buf, accum_len);
            accum_buf[accum_len] = '\0';
            break;
        }

        // 检查累积数据中是否包含关键字
        if (strstr(accum_buf, "ERROR:") != NULL || strstr(accum_buf, "OK:") != NULL) {
            // 找到关键字，认为回复完整，立即打印
            flush_accum_reply();
            // 打印后继续循环读取可能剩余的数据（这些数据属于下一个回复）
        }
    }

    return 0;
}

// ========== Readline 补全 ==========
static char *cmd_completion_generator(const char *text, int state) {
    static int list_index, len;
    const char *name;

    if (!state) {
        list_index = 0;
        len = strlen(text);
    }

    while ((name = completion_cmds[list_index++]) != NULL) {
        if (strncmp(name, text, len) == 0) return strdup(name);
    }

    return NULL;
}

static char **cmd_completion(const char *text, int start, int end) {
    (void)start; (void)end;
    rl_attempted_completion_over = 1;
    return rl_completion_matches(text, cmd_completion_generator);
}

// ========== Readline 行处理回调 ==========
static void handle_line(char *line) {
    if (line == NULL) {   // Ctrl+D
        printf(COLOR_YELLOW "\n[Client INFO] Exit (Ctrl+D)" COLOR_RESET "\n");
        running = 0;
        return;
    }

    trim_space(line);
    size_t line_len = strlen(line);
    if (line_len == 0) {
        free(line);
        return;
    }

    if (strcmp(line, "quit") == 0) {
        printf(COLOR_YELLOW "[Client INFO] Exit (command)" COLOR_RESET "\n");
        running = 0;
        free(line);
        return;
    }

    if (line_len > MAX_CMD_LEN) {
        printf(COLOR_RED "[Client ERROR] Command too long (max %d bytes)" COLOR_RESET "\n", MAX_CMD_LEN);
        free(line);
        return;
    }

    add_history(line);

    if (sock < 0) {
        printf(COLOR_YELLOW "[Client WARNING] No connection, reconnecting..." COLOR_RESET "\n");
        sock = reconnect_server();
        if (sock < 0) {
            printf(COLOR_RED "[Client ERROR] Reconnect failed, exiting." COLOR_RESET "\n");
            running = 0;
            free(line);
            return;
        }
    }

    char send_buf[MAX_CMD_LEN + 2] = {0};
    snprintf(send_buf, sizeof(send_buf), "%s\n", line);
    if (send_all(sock, send_buf, strlen(send_buf)) < 0) {
        printf(COLOR_YELLOW "[Client WARNING] Send failed, reconnecting..." COLOR_RESET "\n");
        close(sock);
        sock = reconnect_server();
        if (sock < 0) {
            printf(COLOR_RED "[Client ERROR] Reconnect failed, exiting." COLOR_RESET "\n");
            running = 0;
            free(line);
            return;
        }
        if (send_all(sock, send_buf, strlen(send_buf)) >= 0) {
            printf(COLOR_GREEN "[Client Send] (reconnected) %s" COLOR_RESET "\n", line);
        } else {
            printf(COLOR_RED "[Client ERROR] Resend failed after reconnect" COLOR_RESET "\n");
            running = 0;
        }
    } else {
        printf(COLOR_GREEN "[Client Send] %s" COLOR_RESET "\n", line);
    }

    // 抑制 readline 自动显示下一个提示符
    rl_already_prompted = 1;

    free(line);
}

// ========== Readline 初始化 ==========
static void init_readline() {
    using_history();
    stifle_history(MAX_HISTORY);

    char *hist_path = get_history_file_path();
    if (access(hist_path, F_OK) == 0) {
        read_history(hist_path);
        printf(COLOR_YELLOW "[Client INFO] Loaded history from %s" COLOR_RESET "\n", hist_path);
    }

    rl_attempted_completion_function = cmd_completion;
}

static void save_history() {
    char *hist_path = get_history_file_path();
    if (write_history(hist_path) == 0) {
        history_truncate_file(hist_path, MAX_HISTORY);
        printf(COLOR_YELLOW "[Client INFO] History saved to %s" COLOR_RESET "\n", hist_path);
    }
}

// ========== 主函数 ==========
int main(int argc, char *argv[]) {
    if (argc != 3 && argc != 5) {
        fprintf(stderr, COLOR_YELLOW "[Client USAGE] %s <server_ip> <port> [--key <auth_key>]" COLOR_RESET "\n", argv[0]);
        return 1;
    }

    strncpy(g_server_ip, argv[1], sizeof(g_server_ip)-1);
    g_server_port = atoi(argv[2]);

    if (configure_auth_key(argc, argv) != 0) {
        fprintf(stderr, COLOR_RED "[Client ERROR] A decimal auth key is required (use --key or AIP_AUTH_KEY)" COLOR_RESET "\n");
        return 1;
    }

    init_readline();

    sock = nonblock_connect(g_server_ip, g_server_port, CONNECT_TIMEOUT);
    if (sock < 0 || authenticate_socket(sock) != 0) {
        if (sock >= 0) close(sock);
        fprintf(stderr, COLOR_RED "[Client ERROR] Connect to %s:%d failed" COLOR_RESET "\n", g_server_ip, g_server_port);
        return 1;
    }

    printf(COLOR_BLUE "========================================" COLOR_RESET "\n");
    printf(COLOR_GREEN "[Client INFO] Connected to %s:%d (non-blocking)!" COLOR_RESET "\n", g_server_ip, g_server_port);
    printf(COLOR_YELLOW "[Client TIPS] ↑/↓: history | Ctrl+R: search | Tab: complete | quit: exit" COLOR_RESET "\n");
    printf(COLOR_BLUE "========================================" COLOR_RESET "\n\n");

    rl_callback_handler_install(COLOR_BLUE "[Client Input] > " COLOR_RESET, handle_line);

    // 初始化累积缓冲区
    accum_len = 0;
    accum_buf[0] = '\0';

    // 主事件循环，带超时
    while (running) {
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(STDIN_FILENO, &readfds);
        int maxfd = STDIN_FILENO;

        if (sock >= 0) {
            FD_SET(sock, &readfds);
            if (sock > maxfd) maxfd = sock;
        }

        struct timeval tv;
        tv.tv_sec = SELECT_TIMEOUT_MS / 1000;
        tv.tv_usec = (SELECT_TIMEOUT_MS % 1000) * 1000;

        int ret = select(maxfd + 1, &readfds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }

        if (ret == 0) {
            // 超时：检查是否有未打印的累积数据（可能回复中不包含关键字）
            if (accum_len > 0) {
                flush_accum_reply();
            }
            continue;
        }

        // 检查服务器套接字
        if (sock >= 0 && FD_ISSET(sock, &readfds)) {
            if (read_all_server_reply(sock) < 0) {
                close(sock);
                sock = -1;
                printf(COLOR_YELLOW "[Client INFO] Connection lost, attempting reconnect..." COLOR_RESET "\n");
                sock = reconnect_server();
                if (sock < 0) {
                    printf(COLOR_RED "[Client ERROR] Reconnect failed, exiting." COLOR_RESET "\n");
                    running = 0;
                    break;
                }
            }
        }

        // 检查标准输入
        if (FD_ISSET(STDIN_FILENO, &readfds)) {
            rl_callback_read_char();
        }
    }

    // 清理
    rl_callback_handler_remove();
    save_history();
    clear_history();
    if (sock >= 0) close(sock);

    printf(COLOR_BLUE "\n========================================" COLOR_RESET "\n");
    printf(COLOR_GREEN "[Client INFO] Exited successfully" COLOR_RESET "\n");
    return 0;
}
