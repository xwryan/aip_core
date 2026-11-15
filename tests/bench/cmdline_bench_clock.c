/* 参数解析基准用的主机 CPU/单调墙钟（非 SV 仿真时间），仅链接进基准 simv；时钟失败立即非零退出，禁止伪造数据。 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 只有两次读数之差有意义；失败直接终止，不把 -1/0 当有效耗时。 */
static double read_clock_seconds(clockid_t clock_id)
{
    struct timespec value;

    if (clock_gettime(clock_id, &value) != 0) {
        perror("cmdline benchmark clock_gettime");
        exit(EXIT_FAILURE);
    }
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

/* 当前进程（含所有线程）已耗 CPU 秒数，不含许可证/调度等待。 */
double aip_cmdline_bench_cpu_seconds(void)
{
    return read_clock_seconds(CLOCK_PROCESS_CPUTIME_ID);
}

/* 单调墙钟秒数（不受日历时间调整影响），用于观察宿主机调度影响。 */
double aip_cmdline_bench_wall_seconds(void)
{
    return read_clock_seconds(CLOCK_MONOTONIC);
}

#ifdef __cplusplus
}
#endif
