# RAL 基础夹具、命名访问与确定性 runner

本目录提供真实 ralgen 模型、独立四态 word 存储、命名访问和确定性 runner 验证构建。
模型和物理存储均归测试环境所有；产品 service、memory frontdoor 和最小 runner 由
`aip_core_pkg` 提供，测试夹具只拥有 adapter/driver 和物理存储 oracle。
adapter 在有效 lane 转入二态 RAL 数据前检查 X/Z，driver 不读取 mirror 作为 oracle。

## 运行

VCS 生成、编译和仿真只能在 `10.11.10.53` 的 ubuntu bash 登录环境执行，
使用 W-2024.09-SP1 随附 UVM 1.2。环境须正确设置 VCS_HOME；不要求 UVM_HOME。

```sh
make test_ral_config
make test_ral_config_128
# 或按依赖顺序运行两种独立构建
make test_ral_foundation
```

脚本分别采用：

```sh
ralgen -full64 -uvm -l sv -t aip_fixture /absolute/repo/tests/ral/aip_fixture64.ralf
ralgen -full64 -uvm -l sv -t aip_fixture /absolute/repo/tests/ral/aip_fixture128.ralf
```

所有输出分别留在 `tests/ral/build/default` 和 `tests/ral/build/width128`。
128 构建显式重编 `uvm_pkg.sv` 和 DPI，并在同一编译命令设置 UVM_REG_DATA_WIDTH=128；
默认构建不设置该宏，仅注册64位fixture。`compile.command` 保存实际完整编译命令。
两个目录不共享生成文件、simv、Mdir 或记录，脚本不调用宽泛 clean。

检查 `generate.log`、`compile.log`、`run.log`、`ral_records.txt` 和 `tcl.log`。
SV必须产生完成标记且 UVM_ERROR/UVM_FATAL 为0；随后启动VCS内嵌Tcl独立检查
记录的list/字节契约，必须产生 `RAL_FOUNDATION_TCL_PASS` 才算本目标通过。
第二次启动在UCLI中直接解析既有记录并quit，不run测试或覆盖记录；不依赖独立tclsh。
还可把两个目录的 `ral_records.txt` 分别复制回本机额外执行：

```sh
tclsh tests/tcl/test_ral_foundation.tcl /absolute/artifacts/default/ral_records.txt
tclsh tests/tcl/test_ral_foundation.tcl /absolute/artifacts/width128/ral_records.txt
```

既有 `test_core_package` 和 `test_core_package_preinclude` 仍为独立兼容门禁。

## 夹具接口与故障

`aip_ral_fixture_pkg::aip_ral_fixture_env` 公开 model、memory、register0、sqr、driver、adapter。
`model.LEAF` 是层次 block；WIDE/RAM/VIEW 由真实 RALF 生成，VIEW的低field为13位。
RALF使用4字节总线、word地址：WIDE基址0x200，RAM基址0x300；每拍地址递增1。
driver.storage 保存四态word，addresses/data_trace/enables/bits_trace/kinds记录实际请求。
clear_trace只清记录，不清存储或故障设置，方便跨操作比较。
read_corrupt翻转采样bit0，read_x将该位置X；二者不改变物理存储，仅校准读数据检查。
adapter.unknown_count记录拒绝未知值的次数，错误返回NOT_OK，不继续二态化。
所有故障必须由测试断言具体status、数据及driver计数，不通过全局降级UVM错误掩盖失败。

## Task2 命令生命周期

以下目标独立于Task1 foundation，只用假action验证service所有权、listener和真实bridge
watchdog结果路径，不生成模型或接入真实RAL总线：

```sh
make test_ral_lifecycle
make test_ral_lifecycle_128
```

同样必须在53的VCS登录环境执行，分别写入 `build/lifecycle/default` 和
`build/lifecycle/width128`，与foundation的生成文件和缓存完全分离。
`run_lifecycle.sh`沿用已验证的显式UVM源码/DPI编译约定，并链接统一package需要的socket DPI。
UCLI执行 `tests/tcl/test_ral_lifecycle.tcl`，通过实际bridge入口测试watchdog；
没有独立tclsh依赖。SV必须输出匹配实际构建位宽的
`RAL_LIFECYCLE_COMPLETE width=N checks=N case=场景名`，Tcl必须输出 `RAL_LIFECYCLE_TCL_PASS`，
同时UVM_ERROR/UVM_FATAL为0且无额外错误。只有上述检查均成功才输出VALIDATED。
每宽编译一次，action/parse/inventory/quiesce/reset/resume/sequence/dirtycancel/restore/
normalleak/priorerror/cancelleak 共十二个场景各启动全新sim进程，通过 `+LIFECYCLE_CASE=` 选择，
绝不清空产品singleton。
脚本为每次运行显式设置 `AIP_RAL_TEST_ROOT`，Tcl据此定位bridge，不依赖VCS `-do`
可能返回空值的 `info script`；该环境只影响当前运行命令，不写入用户配置。
每一步保存 `compile.command/.log/.rc`、`run_场景名.command/.log/.rc`；每场景超时默认120秒，
可用RAL_TIMEOUT为慢主机调整，不改变测试断言。
故障红灯由验证代理在独立冻结副本临时注入，不把测试故障开关加入正式core或构建目标。

## Task4/Task5 transport 与命名访问

memory/raw transport 和 `ral_op` 按宽度隔离构建：

```sh
make test_ral_transport
make test_ral_transport_128
make test_ral_op
make test_ral_op_128
```

`ral_op` 当前支持 `read/write` 以及 reg、field、mem、vreg、vfield 的严格位置参数，省略
`am` 等价于 `am=ral`。memory/vreg/vfield 必须显式 index；输入包含 X/Z/? 或超过对象宽度
会拒绝。partial field/vfield 写入会先检查 sibling policy、parent hole 和 backing memory
几何；无法证明安全时返回 `UNSAFE_READ`、`UNSAFE_RMW` 或 `UNSUPPORTED`，不依赖旧 mirror。

`ral_test` 已接入最小确定性 runner：

```tcl
ral_test run soc
ral_test run soc.SRAM mem=all
```

`suite=policy` 为唯一 suite，memory 默认 `address-line`，可选 `all`。runner 建立
field/memory inventory，要求 SV 侧配置全局 reset hook，调用已注册 root 的 quiesce/resume
hook，执行 RW field/memory 的确定性 0/1 与 walking-1/0 写读和恢复；RO、特殊 policy、volatile 或缺少
必要 raw observer 的对象明确记为 `UNTESTABLE`，不会静默跳过或伪造 PASS。输出保留
`inventory_complete`、叶计数、memory_entries_tested、reset/restore/recovery 字段。当前
runner 不包含随机 suite、vreg/vfield 自动测试、复杂特殊 policy oracle 或跨寄存器 alias
测试；这些仍是后续扩展项。
