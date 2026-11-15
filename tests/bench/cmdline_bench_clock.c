/* tests/bench：为参数解析基准提供主机 CPU/单调墙钟，而不是 SV 仿真时间。
 * 仅链接进基准 simv，不属于生产库；不持有资源，不写入解析器状态。
 * Linux clock_gettime 由 libc 提供。时钟失败时立即非零退出，禁止生成伪造数据。
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 读取指定时钟并换算为秒；两次读数之差才是待测区间，不能使用其绝对值。
 * 失败直接终止基准进程；不允许把 -1 或零当作有效耗时继续汇总。
 */
static double read_clock_seconds(clockid_t clock_id)
{
    struct timespec value;

    if (clock_gettime(clock_id, &value) != 0) {
        perror("cmdline benchmark clock_gettime");
        exit(EXIT_FAILURE);
    }
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

/* 返回当前进程已消耗的 CPU 秒数，不计许可证等待、调度等待及其它进程 CPU。
 * 由 SV 在工作段前后调用，不跨进程累计；含当前进程所有线程的 CPU 时间。
 */
double aip_cmdline_bench_cpu_seconds(void)
{
    return read_clock_seconds(CLOCK_PROCESS_CPUTIME_ID);
}

/* 返回单调墙钟秒数，辅助观察宿主机调度影响；系统日历时间调整不影响它。
 * 仅计主机耗时，不推进 SV 时间、不睡眠。
 */
double aip_cmdline_bench_wall_seconds(void)
{
    return read_clock_seconds(CLOCK_MONOTONIC);
}

#ifdef __cplusplus
}
#endif
