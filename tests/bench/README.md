# 参数解析性能基准

本目录用于测量现有结构体参数解析的主机执行成本，不修改生产解析器，也不属于功能回归
总目标。SV 工作负载在 `tests/sv/test_cmdline_benchmark.sv`；本目录的 C 文件只提供计时，
shell 脚本负责串行执行场景、检查结果并汇总。这里不包含性能优化实现。

## 在 53 上运行

必须在 VCS 主机 `10.11.10.53` 运行，使用已配置 VCS 和许可证的交互式 bash 环境。
例如先登录，再在该主机上的工作副本根目录执行：

```bash
ssh -t ubuntu@10.11.10.53 'bash -i'
source ~/.bashrc
cd /path/to/aip_core
make bench_cmdline
```

`/path/to/aip_core` 替换为 53 上的实际工作副本路径。非交互式 shell 中只执行
`source ~/.bashrc` 可能遇到文件提前 return，因此远程批处理也应使用 `bash -ic`。
需要 VCS、C 编译器、bash、GNU `timeout`、`sort`、`awk` 等工具。

`make bench_cmdline` 先编译，再串行运行全部场景；编译使用
`-debug_access+r+w+f`，运行使用 `-no_save -exitstatus +ntb_random_seed=17`。
编译日志保存在 `tests/sv/cmdline_benchmark_compile.log`。每次运行脚本会创建独立的
`tests/sv/cmdline_benchmark.XXXXXX/` 结果目录，开头通过 `BENCH_LOG_DIR` 输出路径，
不会覆盖或自动清理旧结果。

如只想编译一次，再调整测量工作量：

```bash
make bench_cmdline_build
BENCH_FILTER='repeat_*' BENCH_REPEAT_ITERS=2000 bash tests/bench/run_cmdline_benchmark.sh
BENCH_FILTER='array_*_1000' BENCH_ARRAY_ITERS=2 bash tests/bench/run_cmdline_benchmark.sh
```

## 工作量控制

以下变量是运行脚本读取的环境变量，也可放在 `make bench_cmdline` 前设置。

| 环境变量 | 默认值 | 含义 |
|---|---|---|
| `BENCH_REPEATS` | `3` | 每个场景独立启动 simv 的样本数，只允许 1～9 的奇数 |
| `BENCH_REPEAT_ITERS` | `1000` | 每个热重复样本的标量 struct apply 次数 |
| `BENCH_MICRO_ITERS` | `10000` | 每个 lookup/compact 微基准样本的外层循环次数 |
| `BENCH_ARRAY_ITERS` | `1` | 每个数组样本的完整 dynamic-array apply 次数 |
| `BENCH_TIMEOUT` | `120` | 单次 simv 样本的超时秒数，包含启动及计时外工作 |
| `BENCH_FILTER` | `*` | 场景 label 的 bash glob 匹配，不是正则表达式 |

计数与超时必须是正十进制整数。filter 应加引号，避免被调用 shell 提前展开；例如：

```bash
BENCH_FILTER='repeat_compact_*' BENCH_REPEATS=5 make bench_cmdline
BENCH_FILTER='lookup_*' BENCH_MICRO_ITERS=50000 make bench_cmdline
```

filter 没有匹配场景时不会产生样本或汇总，不能据此认为已经完成测量。
脚本会把这些设置转换成 SV 的 `BENCH_CASE/SOURCE/ITERS/SIZE/MISS` plusarg，并按场景
提供真实字段 plusarg 或 runtime override；通常无需直接调用 simv 手工构造输入。

## 测量场景与单位

每条结构体记录有 16 个 `int` 字段 `f00`～`f15`。实际配置使用确定值 1～16，defaults
对照使用全零常量默认值，不启用随机表达式、`unique` 或 `sort`，关闭参数注册打印。
本轮不测 RNG 成本；固定随机种子也不意味着这些确定性输入需要随机采样。

| 场景 label | 测量内容 | 单个样本的 `records` 单位 |
|---|---|---|
| `init_dotted_*` | 未预热的第一次 schema apply，包含懒初始化/首次注册 | 1 条结构体记录 |
| `repeat_defaults_*`、`repeat_dotted_*`、`repeat_compact_*`、`repeat_override_*` | 预热一次后反复执行标量 struct apply，比较默认值、点号 plusarg、compact plusarg 与 override 来源 | apply 次数，即结构体记录数 |
| `array_*` | 预热一次后执行 128 或 1024 条记录的动态结构体数组 apply，保留原有 fixed/each 两阶段 | apply 次数 × 数组长度，即结构体记录数 |
| `lookup_hit_*`、`lookup_miss_*`、`lookup_override_*` | 预热后反复查询一个完整 key，分别检查命中、未命中与 override 来源 | key 查询次数，不是结构体记录数 |
| `compact_scan` | 预热后对固定 compact 文本逐一查询 16 个字段 | 外层循环次数 × 16，即成员查询次数 |

数组来源为 dotted 或 override；compact 数组不是本轮场景。lookup/compact 是辅助定位
成本的微基准，不能把它们的 `records/s` 与整条结构体 apply 的吞吐量混用。

输出中的 `noise` 仅表示附加的无关 `+unused_bench_N=N` plusarg 数量，不是进程的参数
总数。基准控制 plusarg、字段值、数组 `.size` 等真实配置另行计数。矩阵包含 0、100、
1000 个无关参数的不同场景，不是每种来源都遍历全部数量。

## 计时、校验与统计

计时通过 DPI 读取 Linux 主机时钟，而不是 `$time` 或 `$realtime`。全部解析在零仿真
时间完成，仍会消耗真实 CPU 时间。

- `cpu_s` 使用 `CLOCK_PROCESS_CPUTIME_ID`：待测区间内当前进程所有线程的 CPU 时间，
  不包括其它进程的 CPU 或调度等待。
- `wall_s` 使用 `CLOCK_MONOTONIC`：同一区间的真实墙钟耗时，会反映主机调度等影响，
  不受系统日历时间调整影响。
- 编译、simv 启动、输入准备、预热、完整结果校验与最终打印均在计时之外。计时区间
  包含待测调用、最小 checksum 累加及计时边界开销，不是剔除一切辅助操作的纯解析时间。
- `init` 不预热，其余场景预热一次。每个样本是新的 simv 进程，状态不跨样本共享。
  首调用与热重复的工作量不同，不能简单相减并称为“纯 schema 注册耗时”。
- 每个样本检查完整字段或查询结果、checksum 和退出码。override 场景在停止计时后将
  `f00` 更新为 101，再通过公开 apply 路径验证即时可见性；该更新验证不计入耗时。
  失败或超时会停止脚本，不会作为有效样本参与汇总。

每个有效样本输出一条 `BENCH_RESULT` 和 `BENCH_PASS`；脚本输出带 label/noise 的
`BENCH_SAMPLE`，并为每个场景生成 `BENCH_SUMMARY`。默认使用三个样本，分别对 CPU
与墙钟时间取中位数，汇总字段为：

```text
label noise repeats records cpu_median_s cpu_min_s cpu_max_s wall_median_s
```

CPU min/max 是有效样本中的最小/最大值，不是置信区间。中位数对应的 CPU 与墙钟值
分别排序取得，不一定来自同一次样本。三次采样只能提供初步波动观察，不能代替统计
显著性检验；首次调用尤其短时，计时分辨率和固定开销的相对影响更大。

## 使用结果的边界

比较不同实现时应保持 VCS 版本、编译参数、主机、负载、输入来源、noise、迭代次数及
数组长度一致，并保留原始日志与代码版本。本基准没有 DUT、时钟推进、事务流量或真实
UVM 环境负载；不涵盖嵌套结构、随机默认函数、随机化/unique/sort 和所有字段类型。
微基准耗时也不能直接作为整个 apply 的精确热点占比。

这里测得的是特定参数配置路径的执行成本；即使后续该路径加速，也不能据此推导真实
DUT 仿真的整体提速比例。真实收益还取决于项目中 apply 的调用频度及其占总运行时间
的比例，需另行测量。

## 2026-09-17 实测基线

结论：少量初始化配置的绝对开销较小；频繁 apply 或大数组场景下，重复扫描 plusargs
已经产生明显成本，参数查询索引值得优先优化，compact 解析复用其次。本轮只测试现有
实现，没有实现缓存，也没有测量某个优化版本的实际加速比。

### 环境与数据

- 主机：`10.11.10.53`，8 vCPU，VMware 上的 Intel Xeon E5-2695 v4 @ 2.10GHz。
- VCS：`W-2024.09-SP1`，`-debug_access+r+w+f -full64 -lca`，seed 17。
- 源码：提交 `6913070` 基础上的物理拆分工作树，含本目录基准；生产解析逻辑未优化。
- 使用上述默认工作量串行执行，21 个场景、每场景 3 个独立样本，63 个样本全部通过
  字段/查询结果、checksum、退出码检查；override 更新验证也通过。
- [全部样本 CSV](results/2026-09-17-baseline-samples.csv) 保留每次 CPU、墙钟和 checksum；
  [汇总 CSV](results/2026-09-17-baseline-summary.csv) 保留 21 组中位数和 CPU min/max。
- 53 上原始运行目录：`/tmp/aip_cmdline_bench.l83UzC/`；完整驱动日志是
  `benchmark_full.log`，样本日志在 `tests/sv/cmdline_benchmark.pxwFf7/`。临时目录可能被
  系统清理，因此 CSV 同时保存在仓库中；小工作量 pilot 未混入正式统计。

本次关键源码 SHA-256：

```text
0760a094d6c24504a1f40de48b24fc316d806c44f808015c6c10f2ca0d486043  aip_struct_runtime.sv
b9180ed64f9d13cd8dc95291ad77fd040cec89730457276410d6d2f7f6440442  aip_struct_macros.svh
```

### 端到端结果

下表单位为 **CPU 秒，三个样本的中位数**；不包含启动、预热和完整校验。
两列只改变附加无关参数的数量；每个 struct 都有 16 个 int 字段。

| 场景与工作量 | 无额外参数 | 附加 1000 个参数 |
|---|---:|---:|
| 首次 dotted apply，1 次 | 0.001187 | 0.004632 |
| 重复 dotted apply，1000 次 | 0.692344 | 3.522816 |
| 重复 compact apply，1000 次 | 1.324184 | 4.287805 |
| 重复 override apply，1000 次 | 0.565083 | 0.751215 |
| dotted 数组，128 条记录 apply 1 次 | 0.508387 | 2.687916 |
| dotted 数组，1024 条记录 apply 1 次 | 4.213204 | 21.084491 |

补充对照：重复 dotted apply、附加 100 个参数时为 0.998669 秒；无额外参数的
defaults-only 重复 apply 为 0.199062 秒。override 数组的 1024 条记录、附加 1000 个
参数时为 15.792835 秒，本轮未测其无额外参数对照。

首次 apply 只需约 1.2～4.6 ms，单纯做少量初始化通常不必为这些开销大改架构。
但重复 dotted apply 与 1024 条数组在附加 1000 个参数后，分别慢约 5.09 倍和 5.00 倍。
这是当前实现面对不同输入规模的耗时比，**不是缓存实现的提速比**。

### 微基准与优化优先级

同样使用 CPU 秒的三次中位数；micro 的查询数与上表结构体记录数不是同一种单位。

| 微基准与工作量 | 无额外参数 | 附加 1000 个参数 |
|---|---:|---:|
| exact plusarg 命中，10000 次 lookup | 0.062963 | 1.756460 |
| plusarg 未命中，10000 次 lookup | 0.038979 | 1.688784 |
| exact override 命中，10000 次 lookup | 未测 | 0.012125 |
| compact 16 成员逐字段扫描，10000 轮（160000 次成员查询） | 5.789314 | 未测 |

1. **先优化 plusarg 查询。** 命中和未命中都随参数规模显著变贵；可考虑为不可变的
   plusargs 建立索引，同时保持 override 实时可见、重复键选择和现有优先级不变。
   数组即使最终来自 override，`.each` 命中前的 indexed/overall 未命中仍有扫描成本，
   所以仅改成 override 输入不足以解决问题。
2. **再复用 compact 拆解结果。** 本轮独立测到了逐字段重新拆解同一文本的成本。
   只应复用语法/字段规则，不缓存抽样后的值；实际收益需要用优化版本进行同条件 A/B
   测试，不能直接把 dotted 与 compact 的端到端差值都算作拆解成本。
3. **注册/赋值分离暂不作为性能第一优先。** 本轮没有独立测量注册阶段，也不覆盖
   enum 重复枚举等路径，不能据此量化该项收益；现有 schema 已有一次注册标记。
   后续可为职责清晰而重构，但仍须保留默认值校验及 fixed/each 语义。

schema 字段默认值按现有设计要求必须是无副作用的常量/package parameter 表达式。
本基准使用常量，未把随机默认函数视为受支持场景，也未把重复求默认值当成已确认故障。
