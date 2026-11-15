# ============================================================================
# VCS UCLI (Unified Command-Line Interface) TCL 命令参考手册
# 适用版本: VCS Q-2020.03 及以上
# 说明: UCLI 基于 Tcl 8.6，支持所有标准 TCL 命令 + VCS 扩展命令
# 启动方式: simv -ucli [-i script.tcl]
# ============================================================================

# ============================================================================
# 1. 仿真控制命令 (Simulation Control)
# ============================================================================

# --- run: 推进仿真 ---
# run                           ;# 一直运行直到 $stop/$finish 或断点
# run 100                       ;# 运行 100 个时间单位（取决于 timescale）
# run 100ns                     ;# 运行 100 纳秒
# run 1us                       ;# 运行 1 微秒
# run 10ps                      ;# 运行 10 皮秒
# run 1ms                       ;# 运行 1 毫秒
# run -posedge top.clk          ;# 运行到 top.clk 的上升沿
# run -negedge top.clk          ;# 运行到 top.clk 的下降沿
# run -change top.data          ;# 运行到 top.data 值变化
# run -next                     ;# 运行到当前作用域的下一条语句
# run -step                     ;# 单步执行（进入子程序）
# run -over                     ;# 单步执行（跳过子程序）
# run -return                   ;# 运行到当前子程序返回
# run -delta                    ;# 运行一个 delta cycle
# run 0                         ;# 处理当前时间的所有事件（delta cycle）

# --- stop: 设置断点 ---
# stop -posedge top.clk                     ;# 在 clk 上升沿停止
# stop -negedge top.clk                     ;# 在 clk 下降沿停止
# stop -change top.data                     ;# 在 data 变化时停止
# stop -condition {top.counter == 100}       ;# 条件断点
# stop -time 1000                           ;# 在仿真时间 1000 时停止
# stop -file "test.sv" -line 42             ;# 在文件行号处停止
# stop -all                                 ;# 列出所有断点
# stop -delete <id>                         ;# 删除指定断点
# stop -delete -all                         ;# 删除所有断点
# stop -enable <id>                         ;# 启用断点
# stop -disable <id>                        ;# 禁用断点

# --- 其他控制 ---
# abort                         ;# 终止仿真
# finish                        ;# 正常结束仿真（等价 $finish）
# quit                          ;# 退出 UCLI
# restart                       ;# 重新开始仿真（从 time 0）

# ============================================================================
# 2. 信号/变量操作命令 (Signal/Variable Commands)
# ============================================================================

# --- get: 读取信号值 ---
# get top.dut.reg0                          ;# 读取信号当前值
# get top.dut.data -radix hex               ;# 十六进制显示
# get top.dut.data -radix dec               ;# 十进制显示
# get top.dut.data -radix bin               ;# 二进制显示
# get top.dut.data -radix oct               ;# 八进制显示
# get top.dut.mem[0]                        ;# 读取数组元素
# get {$time}                               ;# 读取当前仿真时间
# 注意: VCS Q-2020 中 get 替代 examine 命令

# --- force: 强制信号值 ---
# force top.clk 1                           ;# 强制为 1
# force top.clk 1'b1                        ;# 强制为 1（显式位宽）
# force top.data 32'hDEADBEEF               ;# 强制 32 位十六进制值
# force top.data 32'd100                    ;# 强制 32 位十进制值
# force top.data 8'b10101010                ;# 强制 8 位二进制值
# force top.en 1 -after 10ns                ;# 延迟 10ns 后强制
# force top.data 32'h0 -repeat 100ns        ;# 每 100ns 重复强制
# force -freeze top.clk 1                   ;# 冻结模式（不可被覆盖）
# force -drive top.data 32'hFF              ;# 驱动模式（可被更强驱动覆盖）
# force -deposit top.reg 32'h42             ;# 存入模式（可被任何赋值覆盖）
# force top.mem[0] 8'hAA                    ;# 强制数组元素
# 注意: force 的值在 release 前持续有效

# --- deposit: 存入信号值 ---
# deposit top.data 32'hCAFE                 ;# 存入值（仿真可覆盖）
# deposit top.clk 1'b1                      ;# 存入时钟值
# 与 force 的区别：deposit 的值可以被 HDL 赋值覆盖，force 不会

# --- release: 释放 force ---
# release top.clk                           ;# 释放对 top.clk 的 force
# release -all                              ;# 释放所有 force

# --- show: 显示对象信息 ---
# show -variables                           ;# 显示当前作用域的所有变量
# show -signals                             ;# 显示当前作用域的所有信号
# show -ports                               ;# 显示当前作用域的端口
# show -all                                 ;# 显示所有对象
# show top.dut.data                         ;# 显示特定对象信息
# show -type top.dut.data                   ;# 显示对象类型

# ============================================================================
# 3. 作用域导航命令 (Scope Navigation)
# ============================================================================

# --- scope: 切换/查看作用域 ---
# scope                                     ;# 显示当前作用域
# scope top                                 ;# 切换到 top 模块
# scope top.dut                             ;# 切换到 top.dut
# scope top.dut.u_core                      ;# 切换到子模块
# scope ..                                  ;# 返回上一级
# scope -up                                 ;# 同上，返回上一级
# scope -top                                ;# 返回顶层

# --- find: 搜索对象 ---
# find -signals top.dut.*                   ;# 搜索信号
# find -ports top.dut.*                     ;# 搜索端口
# find -instances top.*                     ;# 搜索实例

# ============================================================================
# 4. 波形转储命令 (Waveform Dump)
# ============================================================================

# --- dump: 控制波形转储 ---
# dump -file waves.vcd                      ;# 设置 VCD 转储文件
# dump -file waves.vpd                      ;# 设置 VPD 转储文件
# dump -add top -depth 0                    ;# 转储 top 下所有层级（depth 0=全部）
# dump -add top.dut -depth 1                ;# 只转储 top.dut 一级
# dump -add top.dut.data                    ;# 转储特定信号
# dump -enable                              ;# 启用转储
# dump -disable                             ;# 禁用转储
# dump -flush                               ;# 刷新转储缓冲
# dump -close                               ;# 关闭转储文件
# dump -limit 1000                          ;# 限制转储大小（MB）

# --- FSDB 转储（需要 Verdi）---
# call {$fsdbDumpfile("waves.fsdb")}        ;# 设置 FSDB 文件
# call {$fsdbDumpvars("+all")}              ;# 转储所有信号
# call {$fsdbDumpvars(0, top.dut)}          ;# 转储 top.dut 下所有
# call {$fsdbDumpon}                        ;# 开启转储
# call {$fsdbDumpoff}                       ;# 关闭转储
# call {$fsdbDumpflush}                     ;# 刷新

# ============================================================================
# 5. 系统任务调用 (System Task Call)
# ============================================================================

# --- call: 调用 SV/Verilog 系统任务或函数 ---
# call {$display("Hello from TCL")}         ;# 调用 $display
# call {$time}                              ;# 获取仿真时间
# call {$realtime}                          ;# 获取实数仿真时间
# call {$stop}                              ;# 调用 $stop
# call {$finish}                            ;# 调用 $finish
# call {$readmemh("data.hex", top.mem)}     ;# 加载内存
# call {$readmemb("data.bin", top.mem)}     ;# 加载内存（二进制）

# ============================================================================
# 6. 别名和宏命令 (Alias & Macro)
# ============================================================================

# --- alias: 创建命令别名 ---
# alias rr "run 100ns"                      ;# 定义别名 rr = run 100ns
# alias rc "run -posedge top.clk"            ;# 定义别名 rc = 到下一个时钟上升沿
# alias show_data "get top.dut.data -radix hex"
# alias                                     ;# 列出所有别名
# alias -delete rr                          ;# 删除别名

# --- source: 加载 TCL 脚本 ---
# source my_script.tcl                      ;# 加载并执行脚本
# source -echo my_script.tcl                ;# 加载并回显每行

# ============================================================================
# 7. 配置命令 (Configuration)
# ============================================================================

# --- config: 配置 UCLI 行为 ---
# config -radix hex                         ;# 默认显示格式改为十六进制
# config -radix dec                         ;# 默认显示格式改为十进制
# config -radix bin                         ;# 默认显示格式改为二进制
# config -timeunit ns                       ;# 时间单位设为纳秒
# config                                    ;# 显示当前配置

# ============================================================================
# 8. 覆盖率命令 (Coverage)
# ============================================================================

# --- coverage: 覆盖率控制 ---
# coverage -report                          ;# 生成覆盖率报告
# coverage -save cov.db                     ;# 保存覆盖率数据
# coverage -load cov.db                     ;# 加载覆盖率数据
# coverage -reset                           ;# 重置覆盖率计数

# ============================================================================
# 9. 断言命令 (Assertion)
# ============================================================================

# --- assertion: 断言控制 ---
# assertion -list                           ;# 列出所有断言
# assertion -enable <name>                  ;# 启用断言
# assertion -disable <name>                 ;# 禁用断言
# assertion -report                         ;# 断言报告

# ============================================================================
# 10. 常用 TCL 原生命令（UCLI 中可直接使用）
# ============================================================================

# --- 变量与表达式 ---
# set myvar 100                             ;# 设置变量
# set result [expr {$myvar * 2}]            ;# 表达式计算
# puts "value = $myvar"                     ;# 打印
# puts [format "0x%08X" $myvar]             ;# 格式化打印

# --- 控制流 ---
# if {$val == 1} { puts "one" } else { puts "other" }
# for {set i 0} {$i < 10} {incr i} { puts $i }
# while {$count < 100} { incr count }
# foreach item {a b c} { puts $item }
# switch $mode { "run" { run } "stop" { stop } }

# --- 过程定义 ---
# proc my_reset {} {
#     force top.rst 1
#     run 10ns
#     force top.rst 0
#     run 10ns
# }

# --- 字符串操作 ---
# string length $str                        ;# 字符串长度
# string index $str 0                       ;# 取字符
# string range $str 0 3                     ;# 取子串
# string match "*pattern*" $str             ;# 通配符匹配
# regexp {pattern} $str                     ;# 正则匹配
# scan $str "%d" num                        ;# 格式化扫描

# --- 文件操作 ---
# set fd [open "log.txt" w]                 ;# 打开文件
# puts $fd "data"                           ;# 写入
# close $fd                                 ;# 关闭
# set fd [open "cmd.txt" r]                 ;# 读取文件
# gets $fd line                             ;# 读一行

# --- 列表操作 ---
# set lst {a b c d}                         ;# 创建列表
# lindex $lst 0                             ;# 取第 0 个元素
# lappend lst "e"                           ;# 追加
# llength $lst                              ;# 长度
# lsearch $lst "b"                          ;# 搜索

# --- 错误处理 ---
# catch {some_command} result               ;# 捕获异常
# if {[catch {get top.sig} val]} { puts "error: $val" }

# ============================================================================
# 11. 常用调试场景示例
# ============================================================================

# --- 示例 1: 复位 + 运行 ---
# proc reset_and_run {cycles} {
#     force top.rst_n 0
#     run 100ns
#     force top.rst_n 1
#     release top.rst_n
#     for {set i 0} {$i < $cycles} {incr i} {
#         run -posedge top.clk
#     }
#     puts "Ran $cycles clock cycles"
# }
# reset_and_run 100

# --- 示例 2: 监控信号值 ---
# proc watch_signal {sig cycles} {
#     for {set i 0} {$i < $cycles} {incr i} {
#         run -posedge top.clk
#         set val [get $sig]
#         puts "Cycle $i: $sig = $val"
#     }
# }
# watch_signal top.dut.data 20

# --- 示例 3: 读写寄存器 ---
# proc write_reg {addr data} {
#     force top.dut.addr 32'd$addr
#     force top.dut.wdata 32'd$data
#     force top.dut.wen 1
#     run -posedge top.clk
#     force top.dut.wen 0
# }
# proc read_reg {addr} {
#     force top.dut.addr 32'd$addr
#     force top.dut.ren 1
#     run -posedge top.clk
#     set val [get top.dut.rdata]
#     force top.dut.ren 0
#     return $val
# }

# --- 示例 4: 批量加载测试向量 ---
# proc load_vectors {filename} {
#     set fd [open $filename r]
#     set count 0
#     while {[gets $fd line] >= 0} {
#         if {[string trim $line] eq "" || [string index $line 0] eq "#"} continue
#         force top.dut.data_in $line
#         run -posedge top.clk
#         incr count
#     }
#     close $fd
#     puts "Loaded $count vectors from $filename"
# }

# --- 示例 5: 条件等待 ---
# proc wait_for_done {timeout_ns} {
#     set start [get {$time}]
#     while {1} {
#         set done [get top.dut.done]
#         if {$done == "'b1" || $done == "1"} {
#             puts "Done asserted at [get {$time}]"
#             return 1
#         }
#         run 1ns
#         set now [get {$time}]
#         # 简单超时检查
#     }
# }

# --- 示例 6: 与 AIP Command Framework 配合使用 ---
# source aip_cmd.tcl
# # SV 注册的命令直接使用:
# aip_send_cmd "write_reg addr=0x100 data=0xFF"
# set result [aip_read_result]
# puts "Result: $result"
# # VCS 原生命令穿插使用:
# run 100ns
# set clk_val [get top.clk0_if.clk]
# aip_send_cmd "read_reg addr=0x100"

puts "# VCS UCLI TCL 命令参考手册已加载"
puts "# 本文件仅作注释参考，不执行任何操作"
