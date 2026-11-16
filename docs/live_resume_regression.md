# 同会话暂停/续跑：迁移与回归记录

日期：2026-09-17。真实仿真环境：已配置许可证的 VCS 主机，VCS
`W-2024.09-SP1`、内置 Tcl `8.6.11`。本记录针对本轮 Tcl 控制层变更及工作树中
已有的命令兼容实现，不把早期原型或中间版本的通过结果当成终版证据。

## 接口迁移结论

| 接口/场景 | 本轮行为 | 旧脚本处理 |
|---|---|---|
| `resume` | VCS 原生命令，在 `pause%` 恢复当前 Tcl 调用栈 | 如果原来用于桥状态清理，改为 `aip_recover` |
| `aip_recover` | 清理已经异常展开后的桥状态，不恢复调用栈 | 保留旧清理参数兼容，但不能在保栈暂停中调用 |
| 普通 `source` / `-do` | 推进中暂停后可在同一会话直接 `resume` | 新脚本无需 `aip_run_self` |
| `aip_run_self` / `aip_source` | 旧错误块跟踪与 `_left.tcl` 重放继续保留（deprecated） | 现有依赖无需删除；它们不等价于保栈续跑 |
| `aip_watch path value stop=0` | 一次性后台观察，只通知，不中止脚本 | 新增能力，默认 `stop=0` |
| `aip_watch path value stop=1` | 命中后通知并保栈暂停，原生 `resume` 后继续 | 暂停期间不允许重入 AIP 请求/推进/快照 |

暂停提示符中的普通已注册命令现在使用独立的有界 ticket 队列：相同注册绑定
FIFO，不同绑定并行；原 bridge 的 pending owner、参数和结果仍归原调用者。公开
入口为 `aip_submit` 与 `aip_job status|wait|cancel|release`，32 个槽位，运行中
超时只标记而不 kill。调试推进会同时推进原任务和DUT，显式 `resume` 后再恢复
原 Tcl 栈。真实 VCS 证据覆盖 source/.so × watch/Ctrl+C 四例、SV 队列 82 项，
并重新通过旧 live-resume 12 例和双 SVT AIP 门禁。

普通交互终端（stdin 为 TTY）自动使用原生 `run -keep`；非 TTY 不自动添加，
避免改变批处理 SIGINT 的中止语义。显式 `-keep` 原样保留，但 VCS 在 EOF
时可能自行继续，不是无人值守的安全暂停保证。托管 watch 暂停若未收到真实
`resume` 就因 EOF 返回，则报 `AIP_CONTROL_PAUSE_ABORTED`。

`dist/aip_init_so.tcl` 仍是推荐库入口；六个 Tcl 模块均实际内嵌 `.so`，不靠
运行时修改 proc 或读取旁路源码实现新功能。修改 Tcl 后需重新 `make -C dist tcl`。

## 覆盖范围与判定

已有根 Makefile 共 41 个叶子目标，结构体聚合目标不重复计数：

| 分组 | 目标数 | 主要能力 |
|---|---:|---|
| core | 8 | CPU bridge、CSEQ 仲裁、DUT 控制、字符串与旧返回槽、逐调用上下文、旧宏/直接 SV 调用、package 前置包含 |
| random | 7 | 随机化负例、零权重、诊断定位、容器语法、打印控制、宽整数、数组 |
| struct | 14 | 标量/容器/嵌套 schema、typed postprocess、队列、生命周期、大小/位宽预算、集成与编译/运行负例 |
| Tcl/socket VCS | 11 | TCP、package、注册/用户 seq、同步/异步 wait、watchdog、end-checker、动态库、状态触发/普通/后台在途快照 |
| 旧 host Tcl | 1 | checkpoint 解析、超时、清理及错误透传 |

新增 `test_sim_control_tcl`、`test_watch_tcl`、`test_live_resume`；另补 dist、
host C、RAM/ROM、固件构建与双 SVT 集成，不能只以新的最小 fixture 替代旧回归。

判定规则：记录真实退出码；实际执行输出须具备精确 PASS 标记；正常 UVM
用例检查 WARNING/ERROR/FATAL 汇总。故意失败的负例要求命中预期诊断、来源与
退出方式，主机超时、崩溃、测试兜底 fatal 不算通过。输入回显中的 `puts PASS`
不算执行结果。

本轮未改变生产 SV 源码。部分终版 Tcl 复跑使用已编译的 simv，但先逐文件
核对 SV/C/fixture 一致，再重新运行真实仿真；`.so` 按终版 Tcl 强制重建。

## 终版结果

已有 41 个叶子目标全部通过：29 个 SV-only、11 个 Tcl/socket VCS，以及
1 个本地 checkpoint Tcl 目标。新增三个目标也全部通过。下述实验 PLI 项
不属于这 41 个目标，仍单列为既有失败，不能据此宣称所有实验能力均通过。
结构体负例包括 56 个运行负例和 22 个编译负例，均命中预期错误。

终版 Tcl 组包括 end-checker 20 个场景，以及状态触发、普通 save/restore、
后台在途 save/restore 三类快照。后台在途快照生成/恢复分别通过 71/69 条
检查，driver_count 均为 2，恢复后的 8 行状态与保存基线一致。

已完成 host 检查：control 203、watch 70、checkpoint wait 111、元数据 8、
loader 12，全部通过，另 `DIST_MAKEFILE_PASS` 通过。53 没有独立 `tclsh`，
这些检查在本地主机实际执行，不把远程 skip 算作 PASS。

新增同会话 PTY 矩阵 12/12 通过，共 816 条 Tcl 检查；每例另检查实际 SV
driver 完成次数以及 UVM WARNING/ERROR/FATAL 均为 0：

| 入口 | 普通执行 | 多次 watch 暂停 | ACK 同刻暂停 | 只通知/取消 | Ctrl+C | 旧重放 |
|---|---:|---:|---:|---:|---:|---:|
| 真实 `.so` | 30 | 129 | 162 | 18 | 47 | 22 |
| source | 30 | 129 | 162 | 18 | 47 | 22 |

数字为逐例 Tcl 检查数。检查真实 proc/for 局部变量、剩余推进时长、完整请求及
返回槽、重复加载与调试可见性；拒绝 7 类暂停中重入操作。sequence 只发一次，
其真实 driver 恰好执行一次，ACK 同刻恢复不额外推进轮询窗口。

额外边界与集成验证：

- 真实 `.so` helper 21 项通过：`run_to`、`wait_posedge`、`pulse`、`reset_dut`、
  force/get/release/deposit、silent/loud、真实 sequence/driver。
- 非 TTY 下单次 SIGINT 提前中断，未自动完成原 500,000ns run；显式
  `aip_recover` 后正常收尾。
- 64bit 信号的 `4294967299` / `8589934597` 在 3ns / 7ns 匹配；立即命中
  `stop=1` 在 0fs 暂停，notify-only 仍补满原 10ns run。
- stdin 为 `/dev/null` 时，托管暂停报告 `AIP_CONTROL_PAUSE_ABORTED`，后续
  业务 marker 未执行；仅 `+r` 的 `.so` 启动兼容检查通过。
- 双 SVT：source/真实 `.so` × 同步/异步建链，4/4 通过。每组覆盖建链、配置
  空间、RC→EP 12 笔、EP→RC 6 笔、34 个参数拒绝项和并行双向读取，
  UVM WARNING/ERROR/FATAL 均为 0。
- host C 六项通过；RAM/ROM 86 项、RAM72/packed40 71 项检查通过；三种 boot
  模式 × 三种 wake 模式的九组固件构建通过，共 27 个 ELF/HEX/MAP 工件。
- dist 构建、源码无 debug 权限的启动冒烟及 `.so` 仅 `+r` 的启动冒烟通过。
  低权限验证只代表加载/启动兼容，不代表可以在缺少 `+f` 时发送完整桥接命令。

## 证据索引

证据目录是本次运行的工件位置，不是仓库依赖；临时目录被清理后应通过测试
入口重新生成。中间版本 `a224` / `c6e8` 的结果不计入上述终版矩阵。

| 范围 | 本地主机索引 | 53 工件根 |
|---|---|---|
| 旧全量与分组状态 | `/tmp/aip_fullmatrix_local.TAmB18/AUDIT.md` | `/tmp/aip_fullaudit.wNdMDF/`，最终 Tcl 组 `evidence/bridge_617d/` 与 `evidence/dist_617d/` |
| 同会话 12 例 | `/tmp/aip-live-617d-evidence.Qtqm8i/RESULTS.md` | `/tmp/aip_live_resume.eT1bxB/`，`final12_617d.log` |
| helper/EOF/batch/宽向量 | `/tmp/aip-native-ucli-local.RK5iD2/FINAL_EVIDENCE.md` | `/tmp/aip-final-edge-probes.GndLzB/`；其他路径见该索引 |
| 双 SVT 四组 | `/tmp/aip-live-integration.b6fcNy/svt_runner_617d.log` | `/tmp/aip_live_integration.wQqH4W/`，同名日志 |
| 本地 host 汇总 | `/tmp/aip-live-integration.b6fcNy/host_617d.log` | 不以远程 `tclsh` skip 代替 |

## 既有例外：实验 PLI 插件

`make -C dist test-ucli-pli` 在编译进程装载实验插件时失败：

```text
undefined symbol: mhpi_ucliCreateCommand
VCS exit=127 / Make exit=2
```

从修改前快照复制相同 fixture 后复跑，失败一致；未进入 Tcl 控制或 SV 业务。
这项不能记作 PASS，也不是本轮新增失败。它使用实验 PLI 装载路径，与经过
验证的 `libaip_tcl_bridge.so` / `aip_init_so.tcl` 路径不同。

双边证据位于 53：`/tmp/aip_fullaudit.wNdMDF/evidence/dist/test-ucli-pli.log`
与 `evidence/pli_baseline/test-ucli-pli.log`（同一根目录）。

## 版本指纹

以下是终版生产源码 SHA256；后续改动后应重新运行相关门禁，而不能沿用本记录。

```text
617d9f62da81e0be9542f9bbc954944cdf92cd55715316b08937589ae2634602  src/tcl/aip_sim_control.tcl
4ba51b854a54d311b75742df519ff29341f2851988d53f0b0a3975f4a7d59a38  src/tcl/aip_watch.tcl
2953c2d242e6b78e424df48a75c839bc36009911b0ea59547ab0c6a66bbdcf22  src/tcl/aip_cmd.tcl
d5f26672d8af21d8f8c4ec2dfe9f82add0c1aecfbc4a23c0e9c77630de8d2702  src/tcl/aip_checkpoint.tcl
17cdd6bb11c5fa18fa69e3ee7c86e957a434ed5c7c40479d8339e3b16dbd87d3  src/tcl/aip_ucli_utils.tcl
383b6dde4793ec10d39e166002179527967d9958f861c589a1949bfa14542f18  dist/aip_init.tcl
9043ff6cd520caa679ef6f24081fa8bea1e7f0e7e8b4151a259c936b6ff76687  dist/aip_init_so.tcl
43f8d046a82614f25aa43ba34bc3268dff6f752d6289f03fcf00ac0833e46f77  dist/aip_run.tcl
7f5253958e85dae54b397bb647107fcfd14e3ea49b6d3541f4054319dd1b4382  dist/lib/libaip_tcl_bridge.so
```

## 复现与边界

```bash
# 在已加载 VCS/license 环境的 53 上执行
make test_live_resume
make ci-cmd
make test_checkpoint_wait_vcs test_checkpoint_restore
make -C dist test-ucli-tcl test-ucli-so

# 有 tclsh 的主机上执行
make test_sim_control_tcl test_watch_tcl test_checkpoint_wait_tcl
tclsh tests/tcl/test_checkpoint_meta.tcl
make -C dist test
```

`test_live_resume` 依赖 Python 3/pexpect；默认重新构建 simv 和真实 `.so`，
用 PTY 驱动 UCLI，日志放在独立临时目录。`make ci` 经 `ci-regress` 包含此门禁。
完整旧目标清单可用 `make help` 和审计索引核对。

- 本轮是 Tcl/UCLI 通道能力，未增加 TCP 异步 EVENT 通知/恢复协议。
- 只承诺受控仿真推进中的同会话保栈；纯 Tcl 死循环、进程退出、错误展开不是暂停。
- 高级边沿/源码行/倒退 run 若被 watch 截断，明确报不支持精确恢复；优先用时间或无限 run。
- 活动 watch 不序列化到快照。checkpoint/restore 前取消 armed 观察，恢复后重新注册。
- CPU bridge/RAM 测试使用 mailbox、IRQ 或存储器行为模型；固件九种组合是构建验证，
  不等于真实 CPU 指令级执行。
- 未承诺其他 VCS 版本与任意自定义 `onbreak` 策略；AIP 不覆盖用户全局 `onbreak`。
