#================================================================
# AIP UCLI Utility Library
#
# VCS UCLI TCL helpers — force/deposit/get/release + run flow control
# + memory dump/load + breakpoints + dump-fsdb + batch.
#
# Usage:
#   simv -ucli -i aip_ucli_utils.tcl
# OR within a TCL script:
#   source aip_ucli_utils.tcl
#
# Coexists with aip_cmd.tcl (does not touch `unknown`).
#================================================================

# ---------- Global config ----------
set ::fv_verbose 1   ;# 0=quiet, 1=normal, 2=debug

# 颜色 (跟 aip_cmd.tcl 风格统一)
array set ::_aip_color {
    info  "\033\[38;5;117m"
    warn  "\033\[38;5;214m"
    error "\033\[38;5;160m"
    debug "\033\[38;5;245m"
    reset "\033\[0m"
}

# 抓 caller 文件:行
# 1. info frame stack walk source frame: source 子脚本能拿到 file:line
# 2. fallback aip_cmd.tcl 的 _aip_caller_info: -dofile 模式拿 path 无 line
# (VCS -dofile do.tcl eval 逐行执行, 原脚本 line 信息丢失, 是 VCS 限制)
proc _aip_caller_with_line {} {
    set depth [info frame]
    for {set i [expr {$depth - 1}]} {$i > 0} {incr i -1} {
        if {[catch {info frame $i} f]} { continue }
        set type ""
        if {[dict exists $f type]} { set type [dict get $f type] }
        if {$type ne "source"} { continue }
        set file ""
        if {[dict exists $f file]} { set file [dict get $f file] }
        if {$file eq ""} { continue }
        set base [file tail $file]
        if {$base in {aip_ucli_utils.tcl aip_cmd.tcl do.tcl}} { continue }
        if {[string match "*/etc/ucli/*" $file]} { continue }
        if {[string match "*/synopsys/*" $file]} { continue }
        set line ""
        if {[dict exists $f line]} { set line [dict get $f line] }
        if {$line ne ""} { return "${file}:${line}" }
        return $file
    }
    if {[info commands _aip_caller_info] ne ""} {
        catch { set s [_aip_caller_info] }
        if {[info exists s] && $s ne "" && $s ne "interactive"} { return $s }
    }
    return ""
}

# 把 "1234000 ps" / "1234567 fs" / "5 ns" 等统一转 "X.XXX ns" (6 位小数, trailing zero 保留)
# 不识别格式时原样返回
proc _aip_format_time_ns {t} {
    if {![regexp {^\s*([0-9]+(?:\.[0-9]+)?)\s*(fs|ps|ns|us|ms|s)\s*$} $t _ n unit]} {
        return $t
    }
    array set scale_to_ns {fs 1e-6  ps 1e-3  ns 1.0  us 1e3  ms 1e6  s 1e9}
    if {![info exists scale_to_ns($unit)]} { return $t }
    set ns [expr {double($n) * $scale_to_ns($unit)}]
    return [format "%.3f ns" $ns]
}

# 拿仿真时间: 优先 UCLI 原生 senv time (永远可用, 不依赖 SV bridge),
# 兜底 aip_cmd.tcl 的 _aip_sim_time (依赖 SV aip_tcl_bridge run_loop, 否则返 "0")
# 返回统一 "X.XXX ns" 格式
proc _aip_get_sim_time {} {
    set raw ""
    if {![catch {set t [senv time]} _]} {
        if {$t ne "" && $t ne "0"} { set raw $t }
    }
    if {$raw eq "" && [info commands _aip_sim_time] ne ""} {
        catch { set t2 [_aip_sim_time] }
        if {[info exists t2] && $t2 ne "" && $t2 ne "0"} { set raw $t2 }
    }
    if {$raw eq ""} { return "" }
    return [_aip_format_time_ns $raw]
}

# 统一日志格式 (跟 aip_cmd.tcl `[tcl_cmd] caller @ time: msg` 风格对齐)
# 颜色区分 level (info=绿 / warn=黄 / error=红 / debug=灰)
proc _aip_msg {level msg} {
    if {[info exists ::aip_echo] && !$::aip_echo} return

    set color $::_aip_color($level)
    set reset $::_aip_color(reset)

    set caller [_aip_caller_with_line]
    set t [_aip_get_sim_time]

    set prefix ""
    if {$caller ne ""} { append prefix " ${caller}" }
    if {$t ne ""}      { append prefix " @ ${t}" }

    puts "${color}\[ucli\]${prefix}: ${msg}${reset}"
}

# _fv_log: verbose-gated wrapper (level 1 → info, level 2 → debug)
proc _fv_log {level msg} {
    if {$::fv_verbose < $level} return
    if {$level >= 2} {
        _aip_msg debug $msg
    } else {
        _aip_msg info $msg
    }
}

#================================================================
# utils_silent / utils_loud — 关闭/打开 VCS UCLI 命令回显
#
# 默认 -do <script.tcl> 会逐行打印 "ucli% <cmd>" 跟命令内容,
# 跟 utils 的彩色输出混在一起读起来累。
#
#   utils_silent       ;# 关 ucli% prompt + 关命令行回显
#   utils_loud         ;# 恢复
#================================================================
proc utils_silent {} {
    catch { set ::tcl_prompt1 ::list }
    catch { config -cmdecho off }
    # 安装 run wrapper 让 run/step/next 跑完仍显式打印时间 (cmdecho off 关掉了 result echo)
    _install_run_wrapper
    _aip_msg info "utils_silent: UCLI command echo disabled (run/step 时间仍显示)"
}

proc utils_loud {} {
    catch { set ::tcl_prompt1 ucli::tcl_prompt1_nocle }
    catch { config -cmdecho on }
    _uninstall_run_wrapper
    _aip_msg info "utils_loud: UCLI command echo enabled"
}

# 把外层 UCLI run/step/next 包一层, silent 模式下跑完显式 puts time
# 不包 _vcs_run (aip_cmd.tcl 内 run proc 调 _vcs_run, 会重复打印)
# aip_cmd.tcl loaded 时: aip_cmd 自己的 run proc 已 puts bridge 时间, 跳过 run wrap 避免双行
# 内部 _aip_safe_run 仍用 _vcs_run + redirect /dev/null 抑制
proc _install_run_wrapper {} {
    set bases {step next}
    if {[info commands ::aip_send_cmd] eq ""} {
        # aip_cmd.tcl 未加载, 我们包 run
        lappend bases run
    }
    foreach base $bases {
        if {[info commands ::__orig_$base] ne ""} continue
        if {[info commands ::$base] eq ""} continue
        catch { rename ::$base ::__orig_$base }
        proc ::$base {args} [string map [list BASE $base] {
            set rc [catch { uplevel 1 [list ::__orig_BASE {*}$args] } result]
            set t [_aip_get_sim_time]
            if {$t ne ""} { puts "BASE [join $args] @ $t" }
            if {$rc} { return -code error $result }
            return $result
        }]
    }
}

proc _uninstall_run_wrapper {} {
    foreach base {run step next} {
        if {[info commands ::__orig_$base] eq ""} continue
        catch { rename ::$base {} }
        catch { rename ::__orig_$base ::$base }
    }
}

#================================================================
# _fv_escape_path: variable substitution for loop vars
#   {var}  → val    (path value 直接含 [val])
#
# Note: TCL 源代码层面 user 必须自己 escape `[` `]` (\[N\] 或 {path[N]})。
#       本函数不再加 backslash, 因 UCLI 接受 path 字符串字面值。
#================================================================
proc _fv_escape_path {path {vars {}}} {
    set result $path
    dict for {name val} $vars {
        set result [string map [list "\{$name\}" "\[$val\]"] $result]
    }
    return $result
}

#================================================================
# _fv_parse_opts: parse -flag value pairs from args
#================================================================
proc _fv_parse_opts {arglist defaults} {
    set opts $defaults
    set i 0
    set n [llength $arglist]
    while {$i < $n} {
        set arg [lindex $arglist $i]
        if {[regexp {^-[a-zA-Z_]} $arg]} {
            set key [string range $arg 1 end]
            if {$key in {force quiet release}} {
                if {$key eq "force"} {
                    dict set opts mode "force"
                } elseif {$key eq "release"} {
                    dict set opts mode "release"
                } else {
                    dict set opts $key 1
                }
            } else {
                incr i
                if {$i >= $n} { error "fv: missing value for -$key" }
                dict set opts $key [lindex $arglist $i]
            }
        }
        incr i
    }
    return $opts
}

#================================================================
# _fv_format_val: 把数值规格化为 UCLI force 接受的 SV 字面量
#   42       → 32'd42
#   0xABCD   → 32'hABCD
#   0b1010   → 32'b1010
#   32'hAB   → 32'hAB    (原样)
#================================================================
proc _fv_format_val {val} {
    set v [string trim $val]
    if {[regexp {^[0-9]*'[hdbHDB]} $v]} { return $v }
    if {[regexp {^0[xX]([0-9a-fA-F]+)$} $v _ hex]} { return "32'h$hex" }
    if {[regexp {^0[bB]([01]+)$} $v _ bin]} { return "32'b$bin" }
    if {[regexp {^-?[0-9]+$} $v]} { return "32'd$v" }
    return $v
}

#================================================================
# _fv_do: execute single force/deposit/release
#================================================================
proc _fv_do {escaped_path val mode} {
    set fval [_fv_format_val $val]
    if {[catch {
        switch -- $mode {
            "force"   { force -freeze $escaped_path $fval }
            "release" { _fv_release_native $escaped_path }
            default   { force -deposit $escaped_path $fval }
        }
    } err]} {
        error "fv: $mode failed on '$escaped_path' = $fval: $err"
    }
}

#================================================================
# _fv_release_native: 尝试多种 UCLI release 语法 (兼容不同 VCS 版本)
#================================================================
proc _fv_release_native {escaped_path} {
    # 试 1: UCLI release builtin (uplevel to avoid recursion if shadowed)
    if {[catch { uplevel #0 [list ::release $escaped_path] } e1]} {
        # 试 2: force -release
        if {[catch { force -release $escaped_path } e2]} {
            # 试 3: force -cancel (some VCS)
            if {[catch { force -cancel $escaped_path } e3]} {
                error "release: 所有方式都失败 ($e1 | $e2 | $e3)"
            }
        }
    }
}

#================================================================
# _fv_is_numeric: 判定字符串是否纯数字
#================================================================
proc _fv_is_numeric {s} {
    return [regexp {^-?[0-9]+$} $s]
}

#================================================================
# _parse_sv_value: parse SV literal 到 TCL int
#   支持: 32'hAB, 'b01010, 8'd255, 'd123, 纯整数
#   X/Z 视为 0
#================================================================
proc _parse_sv_value {raw} {
    set v [string trim $raw]
    if {[regexp {^[0-9]*'[hH]([0-9a-fA-FxXzZ]+)$} $v _ hex]} {
        set clean [string map {x 0 X 0 z 0 Z 0} $hex]
        return [expr "0x$clean"]
    }
    if {[regexp {^[0-9]*'[dD]([0-9]+)$} $v _ dec]} {
        return $dec
    }
    if {[regexp {^[0-9]*'[bB]([01xXzZ]+)$} $v _ bin]} {
        set clean [string map {x 0 X 0 z 0 Z 0} $bin]
        set num 0
        foreach bit [split $clean ""] { set num [expr {$num * 2 + $bit}] }
        return $num
    }
    if {[regexp {^[0-9]*'[oO]([0-7]+)$} $v _ oct]} {
        return [expr "0$oct"]
    }
    if {[regexp {^(-?[0-9]+)$} $v _ n]} {
        return $n
    }
    return ""
}

#================================================================
# fv — single signal force/deposit
#================================================================
proc fv {path val args} {
    set opts [_fv_parse_opts $args {mode deposit}]
    set escaped [_fv_escape_path $path]
    set mode [dict get $opts mode]

    _fv_do $escaped $val $mode
    _fv_log 1 "fv: $mode $path = $val"
}

#================================================================
# fv_bit — bit/bit-range force/deposit
#================================================================
proc fv_bit {path bit_range val args} {
    if {![regexp {^[0-9]+(:[0-9]+)?$} $bit_range]} {
        error "fv_bit: invalid bit range '$bit_range' (expect N or HI:LO)"
    }
    set opts [_fv_parse_opts $args {mode deposit}]
    set mode [dict get $opts mode]

    set escaped [_fv_escape_path $path]
    set full_path "${escaped}\[${bit_range}\]"

    _fv_do $full_path $val $mode
    _fv_log 1 "fv_bit: $mode ${path}\[$bit_range\] = $val"
}

#================================================================
# fv_fill — loop fill with force/deposit
#================================================================
proc fv_fill {path val count args} {
    set opts [_fv_parse_opts $args {
        mode deposit
        from 0  step 1  val_step 0
        from2 0  step2 1  count2 0
    }]

    set mode     [dict get $opts mode]
    set start    [dict get $opts from]
    set step     [dict get $opts step]
    set val_step [dict get $opts val_step]
    set start2   [dict get $opts from2]
    set step2    [dict get $opts step2]
    set count2   [dict get $opts count2]

    if {$val_step != 0 && ![_fv_is_numeric $val]} {
        error "fv_fill: -val_step requires numeric val, got '$val'"
    }

    set current_val $val
    set has_j [expr {[string first "\{j\}" $path] >= 0}]

    if {$has_j && $count2 > 0} {
        set total 0
        for {set idx 0} {$idx < $count} {incr idx} {
            set i [expr {$start + $idx * $step}]
            for {set jdx 0} {$jdx < $count2} {incr jdx} {
                set j [expr {$start2 + $jdx * $step2}]
                set escaped [_fv_escape_path $path [dict create i $i j $j]]
                _fv_do $escaped $current_val $mode
                if {$val_step != 0} {
                    set current_val [expr {$current_val + $val_step}]
                }
                incr total
            }
        }
        _fv_log 1 "fv_fill: $mode ${path} = $val, ${total} entries (${count}x${count2})"
    } else {
        for {set idx 0} {$idx < $count} {incr idx} {
            set i [expr {$start + $idx * $step}]
            set escaped [_fv_escape_path $path [dict create i $i]]
            _fv_do $escaped $current_val $mode
            if {$val_step != 0} {
                set current_val [expr {$current_val + $val_step}]
            }
        }
        set end_i [expr {$start + ($count - 1) * $step}]
        _fv_log 1 "fv_fill: $mode ${path} \[$start:$step:$end_i\] = $val, $count entries"
    }
}

#================================================================
# fv_random — random fill
#================================================================
proc fv_random {path count args} {
    set opts [_fv_parse_opts $args {
        mode deposit  from 0  step 1  width 32  seed -1
    }]

    set mode  [dict get $opts mode]
    set start [dict get $opts from]
    set step  [dict get $opts step]
    set width [dict get $opts width]
    set seed  [dict get $opts seed]

    if {$seed >= 0} { expr {srand($seed)} }
    if {$width > 64} { error "fv_random: width > 64 not supported" }

    for {set idx 0} {$idx < $count} {incr idx} {
        set i [expr {$start + $idx * $step}]
        if {$width <= 30} {
            set max [expr {(1 << $width) - 1}]
            set rval [expr {int(rand() * ($max + 1))}]
        } else {
            set hi_w [expr {$width - 30}]
            set lo [expr {entier(rand() * (1 << 30))}]
            set hi [expr {entier(rand() * (1 << $hi_w))}]
            set rval [expr {($hi << 30) | $lo}]
        }
        set escaped [_fv_escape_path $path [dict create i $i]]
        _fv_do $escaped $rval $mode
    }

    set end_i [expr {$start + ($count - 1) * $step}]
    _fv_log 1 "fv_random: $mode ${path} \[$start:$step:$end_i\], $count entries, width=$width"
}

#================================================================
# Quick aliases
#================================================================
proc fv_zero {path count args} { fv_fill $path 0 $count {*}$args }
proc fv_ones {path count args} { fv_fill $path 32'hFFFFFFFF $count {*}$args }
proc fv_incr {path count args} { fv_fill $path 0 $count -val_step 1 {*}$args }

#================================================================
# fv_at / gv_at — base path + index 分开传, proc 内拼接
#
# 避免 user 在 TCL source 层写 `[]` 被命令替换误解析
#
#   fv_at tb.dut.mem 5 32'hAA           ;# 等同 fv {tb.dut.mem[5]} 32'hAA
#   fv_at tb.dut.mem 5 1 -force
#   gv_at tb.dut.mem 5 -hex             ;# 读
#   fv_at_bit tb.dut.cfg_reg 7 1        ;# bit 操作
#================================================================
proc fv_at {base idx val args} {
    fv "${base}\[$idx\]" $val {*}$args
}
proc gv_at {base idx args} {
    gv "${base}\[$idx\]" {*}$args
}
proc fv_at_bit {base bit_range val args} {
    fv_bit $base $bit_range $val {*}$args
}
proc fv_at_release {base idx} {
    fv_release "${base}\[$idx\]"
}

#================================================================
# gv — get value with auto-escape, radix
#================================================================
proc gv {path args} {
    set radix "dec"
    foreach a $args {
        if {$a eq "-hex"} { set radix "hex" }
        if {$a eq "-bin"} { set radix "bin" }
        if {$a eq "-dec"} { set radix "dec" }
        if {$a eq "-raw"} { set radix "raw" }
    }
    set escaped [_fv_escape_path $path]
    set raw [get $escaped]

    if {$radix eq "raw"} { return $raw }

    set num [_parse_sv_value $raw]
    if {$num eq ""} { return $raw }

    switch -- $radix {
        hex { return [format "0x%x" $num] }
        bin { return [format "0b%b" $num] }
        default { return $num }
    }
}

#================================================================
# fv_release — release force on a signal (avoid name clash with UCLI release)
# Also expose as `unforce` alias
#================================================================
proc fv_release {path} {
    set escaped [_fv_escape_path $path]
    _fv_release_native $escaped
    _fv_log 1 "fv_release: $path"
}
proc unforce {path} { fv_release $path }

#================================================================
# time/unit helpers
#================================================================
proc _aip_time_to_ns {t} {
    if {[regexp {^([0-9]+)\s*(ps|ns|us|ms|s)?$} $t _ n unit]} {
        if {$unit eq ""} { set unit "ns" }
        switch -- $unit {
            ps { return [expr {$n / 1000}] }
            ns { return $n }
            us { return [expr {$n * 1000}] }
            ms { return [expr {$n * 1000000}] }
            s  { return [expr {$n * 1000000000}] }
        }
    }
    return $t
}

proc _aip_safe_run {duration} {
    if {[info commands _vcs_run] ne ""} {
        redirect /dev/null { _vcs_run $duration }
    } else {
        redirect /dev/null { run $duration }
    }
}

#================================================================
# run_to — advance sim until signal matches value
#================================================================
proc run_to {path val args} {
    set opts [_fv_parse_opts $args {timeout 10us poll 100ns}]
    set timeout_ns [_aip_time_to_ns [dict get $opts timeout]]
    set poll [dict get $opts poll]
    set poll_ns [_aip_time_to_ns $poll]

    set elapsed 0
    set cur ""
    while {$elapsed < $timeout_ns} {
        set cur [gv $path -dec]
        if {$cur == $val} {
            _fv_log 1 "run_to: $path = $val matched after ${elapsed}ns"
            return 1
        }
        _aip_safe_run $poll
        set elapsed [expr {$elapsed + $poll_ns}]
    }
    _fv_log 1 "run_to: TIMEOUT after ${timeout_ns}ns waiting $path = $val (last=$cur)"
    return 0
}

#================================================================
# wait_posedge — advance until next posedge
#================================================================
proc wait_posedge {clk args} {
    set opts [_fv_parse_opts $args {n 1 timeout 1us poll 1ns}]
    set n [dict get $opts n]
    set poll [dict get $opts poll]
    set timeout_ns [_aip_time_to_ns [dict get $opts timeout]]
    set poll_ns [_aip_time_to_ns $poll]

    set seen 0
    set prev [gv $clk -dec]
    set elapsed 0

    while {$seen < $n && $elapsed < $timeout_ns} {
        _aip_safe_run $poll
        set elapsed [expr {$elapsed + $poll_ns}]
        set cur [gv $clk -dec]
        if {$prev == 0 && $cur == 1} { incr seen }
        set prev $cur
    }
    _fv_log 1 "wait_posedge: $clk seen=$seen/$n elapsed=${elapsed}ns"
    return $seen
}

#================================================================
# pulse — force val for duration then release + deposit default
#
#   pulse path val duration              ;# release 后 deposit 0
#   pulse path val duration -default V   ;# 自定义 release 后值
#================================================================
proc pulse {path val duration args} {
    set opts [_fv_parse_opts $args {default 0}]
    set default_val [dict get $opts default]
    fv $path $val -force
    _aip_safe_run $duration
    fv_release $path
    fv $path $default_val
    _fv_log 1 "pulse: $path = $val for $duration, then $default_val"
}

#================================================================
# reset_dut — standard reset sequence
#================================================================
proc reset_dut {rst active_val duration} {
    fv $rst $active_val -force
    _aip_safe_run $duration
    set deassert [expr {1 - $active_val}]
    fv $rst $deassert -force
    _fv_log 1 "reset_dut: $rst pulsed to $active_val for $duration, then $deassert"
}

#================================================================
# dump_fsdb_start / dump_fsdb_stop / dump_vcd_start
#================================================================
proc dump_fsdb_start {args} {
    set opts [_fv_parse_opts $args {file wave.fsdb level 0 scope ""}]
    set file [dict get $opts file]
    set lvl [dict get $opts level]
    set scope [dict get $opts scope]
    set ok 0
    if {[catch {
        # fsdbDump* 是 Verdi 注册进 UCLI 的原生命令, 直接调 (原 bug: 前缀 $ 被 Tcl 当变量).
        fsdbDumpfile $file
        if {$scope ne ""} {
            fsdbDumpvars $lvl $scope
        } else {
            fsdbDumpvars $lvl
        }
        set ok 1
    } err]} {
        _fv_log 1 "dump_fsdb_start: FSDB PLI 不可用 ($err), fallback VCD"
    }
    if {!$ok} {
        if {[catch { dump -file $file } err2]} {
            error "dump_fsdb_start: $err2"
        }
    }
    _fv_log 1 "dump_fsdb_start: file=$file level=$lvl scope=$scope"
}

proc dump_fsdb_stop {} {
    catch { fsdbDumpoff }
    catch { dump -close }
    _fv_log 1 "dump_fsdb_stop"
}

proc dump_vcd_start {{file wave.vcd}} {
    catch { dump -file $file -type VCD }
    catch { dump -add / -depth 0 }
    _fv_log 1 "dump_vcd_start: $file"
}

#================================================================
# dump_mem — read memory range, write hex file
#================================================================
proc dump_mem {path args} {
    set opts [_fv_parse_opts $args {from 0 to -1 file mem.hex width 32}]
    set from [dict get $opts from]
    set to [dict get $opts to]
    set file [dict get $opts file]
    set width [dict get $opts width]

    if {$to < $from} { error "dump_mem: -to ($to) must be >= -from ($from)" }

    set fh [open $file w]
    set hex_chars [expr {($width + 3) / 4}]
    for {set i $from} {$i <= $to} {incr i} {
        set escaped [_fv_escape_path $path [dict create i $i]]
        set raw [get $escaped]
        set num [_parse_sv_value $raw]
        puts $fh [format "%0${hex_chars}x" $num]
    }
    close $fh
    set count [expr {$to - $from + 1}]
    _fv_log 1 "dump_mem: $path \[$from:$to\] → $file ($count words, width=$width)"
}

#================================================================
# load_mem — read hex file, force/deposit memory range
#================================================================
proc load_mem {path args} {
    set opts [_fv_parse_opts $args {mode deposit from 0 file mem.hex}]
    set from [dict get $opts from]
    set file [dict get $opts file]
    set mode [dict get $opts mode]

    if {![file exists $file]} { error "load_mem: file not found: $file" }

    set fh [open $file r]
    set i $from
    set count 0
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        if {[string range $line 0 1] eq "0x"} {
            set val "32'h[string range $line 2 end]"
        } else {
            set val "32'h$line"
        }
        set escaped [_fv_escape_path $path [dict create i $i]]
        _fv_do $escaped $val $mode
        incr i
        incr count
    }
    close $fh
    set end [expr {$from + $count - 1}]
    _fv_log 1 "load_mem: $file → $path \[$from:$end\] ($count words)"
}

#================================================================
# bp_set — 条件断点 (wrap UCLI when)
#================================================================
set ::_bp_id 0
set ::_bp_list {}

proc bp_set {path val action} {
    incr ::_bp_id
    set escaped [_fv_escape_path $path]
    set id $::_bp_id
    if {[catch {
        when -id $id "$escaped == $val" $action
    } err]} {
        error "bp_set failed: $err"
    }
    lappend ::_bp_list [list $id $path $val]
    _fv_log 1 "bp_set: id=$id $path == $val → $action"
    return $id
}

proc bp_clear {{id "all"}} {
    if {$id eq "all"} {
        foreach bp $::_bp_list {
            catch { when -delete -id [lindex $bp 0] }
        }
        set ::_bp_list {}
        _fv_log 1 "bp_clear: all"
    } else {
        catch { when -delete -id $id }
        set new {}
        foreach bp $::_bp_list {
            if {[lindex $bp 0] ne $id} { lappend new $bp }
        }
        set ::_bp_list $new
        _fv_log 1 "bp_clear: id=$id"
    }
}

proc bp_list {} {
    foreach bp $::_bp_list {
        puts "  id=[lindex $bp 0]  [lindex $bp 1] == [lindex $bp 2]"
    }
}

#================================================================
# safe_finish — close dumps then $finish via SV bridge if available
#================================================================
proc safe_finish {} {
    catch { dump_fsdb_stop }
    if {[info commands aip_send_cmd] ne ""} {
        catch { aip_send_cmd "end_test drain=100" }
    } else {
        catch { finish }
    }
    _fv_log 1 "safe_finish"
}

#================================================================
# find_signal — search hierarchy for matching signals
#================================================================
proc find_signal {pattern args} {
    set opts [_fv_parse_opts $args {scope ""}]
    set scope [dict get $opts scope]

    set matches {}
    set tree ""
    if {[catch {
        if {$scope ne ""} { catch { scope $scope } }
        set tree [show -tree]
    } err]} {
        _fv_log 1 "find_signal: show -tree failed: $err"
        return {}
    }
    foreach line [split $tree "\n"] {
        set line [string trim $line]
        if {[regexp $pattern $line]} {
            lappend matches $line
        }
    }
    foreach m $matches { puts "  $m" }
    _fv_log 1 "find_signal: '$pattern' matched [llength $matches] signals"
    return $matches
}

#================================================================
# drivers_of / loads_of
#================================================================
proc drivers_of {path} {
    set escaped [_fv_escape_path $path]
    if {[catch {drivers $escaped} result]} {
        error "drivers_of: $result"
    }
    puts $result
    return $result
}

proc loads_of {path} {
    set escaped [_fv_escape_path $path]
    if {[catch {loads $escaped} result]} {
        error "loads_of: $result"
    }
    puts $result
    return $result
}

#================================================================
# time_now
#================================================================
proc time_now {args} {
    set t [_aip_get_sim_time]
    if {$t ne ""} { return $t }
    return "unknown"
}

#================================================================
# batch — collect multiple fv calls, execute together
#================================================================
set ::_batch_mode 0
set ::_batch_cmds {}

proc batch {block} {
    # UCLI force 本身无 batch 接口, 此处只作 syntactic grouping + error containment
    if {[catch { uplevel 1 $block } err]} {
        error "batch: $err"
    }
    _fv_log 1 "batch: block executed"
}

#================================================================
# ECC / Parity primitives
#================================================================

# XOR all bits of an N-bit value, return 0 or 1
proc _xor_bits {val width} {
    set x 0
    for {set i 0} {$i < $width} {incr i} {
        set x [expr {$x ^ (($val >> $i) & 1)}]
    }
    return $x
}

# Parity 计算: data 按 grain 分组, 每组算 XOR (even) 或 XOR ^ 1 (odd)
# Returns: num_groups bits stacked (LSB = group 0)
proc _parity_compute {data width grain polarity} {
    if {$grain eq "word"} { set grain $width }
    if {[expr {$width % $grain}] != 0} {
        error "parity: width $width not multiple of grain $grain"
    }
    set num_groups [expr {$width / $grain}]
    set p 0
    set mask [expr {(1 << $grain) - 1}]
    for {set g 0} {$g < $num_groups} {incr g} {
        set group_val [expr {($data >> ($g * $grain)) & $mask}]
        set bit_p [_xor_bits $group_val $grain]
        if {$polarity eq "odd"} { set bit_p [expr {$bit_p ^ 1}] }
        set p [expr {$p | ($bit_p << $g)}]
    }
    return $p
}

proc _parity_width {data_width grain} {
    if {$grain eq "word"} { return 1 }
    return [expr {$data_width / $grain}]
}

# SECDED Hamming ecc width (industry-standard pairs)
proc _secded_ecc_width {data_width} {
    switch -- $data_width {
        8   { return 5 }
        16  { return 6 }
        32  { return 7 }
        64  { return 8 }
        128 { return 9 }
        default { error "secded: unsupported data width $data_width (use 8/16/32/64/128)" }
    }
}

# SECDED encode
# Layout: ecc[0] = overall parity, ecc[r:1] = r Hamming bits (r = ecc_total - 1)
proc _hamming_encode {data data_width} {
    set ecc_total [_secded_ecc_width $data_width]
    set r [expr {$ecc_total - 1}]
    set M [expr {$data_width + $r}]

    set syndrome 0
    set data_idx 0
    for {set pos 1} {$pos <= $M} {incr pos} {
        if {($pos & ($pos - 1)) == 0} { continue }
        set bit [expr {($data >> $data_idx) & 1}]
        incr data_idx
        if {$bit} { set syndrome [expr {$syndrome ^ $pos}] }
    }
    set hamming 0
    for {set i 0} {$i < $r} {incr i} {
        set b [expr {($syndrome >> $i) & 1}]
        set hamming [expr {$hamming | ($b << $i)}]
    }
    set overall [_xor_bits $data $data_width]
    set overall [expr {$overall ^ [_xor_bits $hamming $r]}]
    return [expr {($hamming << 1) | $overall}]
}

# SECDED decode → {corrected_data status}
proc _hamming_decode {data ecc data_width} {
    set ecc_total [_secded_ecc_width $data_width]
    set r [expr {$ecc_total - 1}]
    set M [expr {$data_width + $r}]

    set stored_overall [expr {$ecc & 1}]
    set stored_hamming [expr {$ecc >> 1}]

    set syndrome 0
    set data_idx 0
    for {set pos 1} {$pos <= $M} {incr pos} {
        if {($pos & ($pos - 1)) == 0} { continue }
        set bit [expr {($data >> $data_idx) & 1}]
        incr data_idx
        if {$bit} { set syndrome [expr {$syndrome ^ $pos}] }
    }
    set recalc_hamming 0
    for {set i 0} {$i < $r} {incr i} {
        set b [expr {($syndrome >> $i) & 1}]
        set recalc_hamming [expr {$recalc_hamming | ($b << $i)}]
    }

    set syndrome_diff [expr {$stored_hamming ^ $recalc_hamming}]
    set err_pos 0
    for {set i 0} {$i < $r} {incr i} {
        set b [expr {($syndrome_diff >> $i) & 1}]
        set err_pos [expr {$err_pos | ($b << $i)}]
    }

    # Overall parity check 必须用 stored_hamming 不是 recalc_hamming:
    # P = stored_overall XOR XOR(stored_data) XOR XOR(stored_hamming) 应为 0
    set recalc_overall [_xor_bits $data $data_width]
    set recalc_overall [expr {$recalc_overall ^ [_xor_bits $stored_hamming $r]}]
    set overall_mismatch [expr {$stored_overall != $recalc_overall}]

    if {$err_pos == 0 && !$overall_mismatch} {
        return [list $data "ok"]
    }
    if {$err_pos != 0 && $overall_mismatch} {
        if {($err_pos & ($err_pos - 1)) == 0} {
            return [list $data "single_err_in_ecc pos=$err_pos"]
        }
        set data_bit_idx 0
        set count 0
        for {set pos 1} {$pos <= $M} {incr pos} {
            if {($pos & ($pos - 1)) == 0} { continue }
            if {$pos == $err_pos} { set data_bit_idx $count; break }
            incr count
        }
        set corrected [expr {$data ^ (1 << $data_bit_idx)}]
        return [list $corrected "single_err pos=$err_pos corrected"]
    }
    if {$err_pos == 0 && $overall_mismatch} {
        return [list $data "single_err_in_overall"]
    }
    return [list $data "double_err uncorrectable"]
}

# CRC-8 polynomial 0x07, init 0, MSB-first
proc _crc8 {data data_width} {
    set crc 0
    set bytes [expr {($data_width + 7) / 8}]
    for {set b [expr {$bytes - 1}]} {$b >= 0} {incr b -1} {
        set byte [expr {($data >> ($b * 8)) & 0xFF}]
        set crc [expr {$crc ^ $byte}]
        for {set i 0} {$i < 8} {incr i} {
            if {$crc & 0x80} {
                set crc [expr {(($crc << 1) ^ 0x07) & 0xFF}]
            } else {
                set crc [expr {($crc << 1) & 0xFF}]
            }
        }
    }
    return $crc
}

#================================================================
# Mem ECC config
#================================================================
array set ::_mem_cfg {}

proc mem_cfg {path args} {
    set defaults [dict create \
        width 32 \
        ecc_mode none \
        parity_grain 8 \
        parity_polarity even \
        on_err warn \
        layout concat \
        ecc_path ""]
    set opts [_fv_parse_opts $args $defaults]

    set width [dict get $opts width]
    set mode  [dict get $opts ecc_mode]
    set ecc_w 0
    switch -- $mode {
        none   { set ecc_w 0 }
        parity { set ecc_w [_parity_width $width [dict get $opts parity_grain]] }
        secded { set ecc_w [_secded_ecc_width $width] }
        crc8   { set ecc_w 8 }
        default { error "mem_cfg: unknown ecc_mode '$mode' (none|parity|secded|crc8)" }
    }
    dict set opts ecc_width $ecc_w
    set ::_mem_cfg($path) $opts
    _fv_log 1 "mem_cfg: $path width=$width mode=$mode ecc_w=$ecc_w layout=[dict get $opts layout]"
    return $ecc_w
}

proc _mem_get_cfg {path} {
    if {![info exists ::_mem_cfg($path)]} {
        error "mem: path '$path' not configured, call mem_cfg first"
    }
    return $::_mem_cfg($path)
}

#----------------------------------------------------------------
# mem_cfg_list — 列出所有已配置 mem path + 配置摘要
# mem_cfg_get <path>  — 返回某 path 完整 dict
# mem_cfg_clear <path|all>  — 清除配置
#----------------------------------------------------------------
proc mem_cfg_list {} {
    set paths [lsort [array names ::_mem_cfg]]
    if {[llength $paths] == 0} {
        puts "mem_cfg_list: (no path configured)"
        return {}
    }
    puts "================================================================"
    puts [format " %-40s %-7s %-8s %-10s %-7s" "PATH" "WIDTH" "ECC_MODE" "DETAIL" "LAYOUT"]
    puts "----------------------------------------------------------------"
    foreach p $paths {
        set c $::_mem_cfg($p)
        set width  [dict get $c width]
        set mode   [dict get $c ecc_mode]
        set ecc_w  [dict get $c ecc_width]
        set layout [dict get $c layout]
        set detail ""
        switch -- $mode {
            none   { set detail "-" }
            parity { set detail "g=[dict get $c parity_grain],[dict get $c parity_polarity],+${ecc_w}b" }
            secded { set detail "+${ecc_w}b SECDED" }
            crc8   { set detail "+${ecc_w}b CRC-8" }
        }
        puts [format " %-40s %-7s %-8s %-10s %-7s" $p $width $mode $detail $layout]
    }
    puts "================================================================"
    return $paths
}

proc mem_cfg_get {path} {
    return [_mem_get_cfg $path]
}

proc mem_cfg_clear {{path "all"}} {
    if {$path eq "all"} {
        array unset ::_mem_cfg
        array set ::_mem_cfg {}
        _fv_log 1 "mem_cfg_clear: all"
    } else {
        if {[info exists ::_mem_cfg($path)]} {
            unset ::_mem_cfg($path)
            _fv_log 1 "mem_cfg_clear: $path"
        }
    }
}

proc _mem_ecc_encode {cfg data} {
    set mode [dict get $cfg ecc_mode]
    switch -- $mode {
        none   { return 0 }
        parity {
            return [_parity_compute $data [dict get $cfg width] \
                [dict get $cfg parity_grain] [dict get $cfg parity_polarity]]
        }
        secded { return [_hamming_encode $data [dict get $cfg width]] }
        crc8   { return [_crc8 $data [dict get $cfg width]] }
    }
}

proc _mem_ecc_decode {cfg data ecc} {
    set mode [dict get $cfg ecc_mode]
    switch -- $mode {
        none   { return [list $data "ok"] }
        parity {
            set p_recalc [_parity_compute $data [dict get $cfg width] \
                [dict get $cfg parity_grain] [dict get $cfg parity_polarity]]
            if {$p_recalc == $ecc} { return [list $data "ok"] }
            return [list $data "parity_err recalc=$p_recalc stored=$ecc"]
        }
        secded { return [_hamming_decode $data $ecc [dict get $cfg width]] }
        crc8   {
            set c_recalc [_crc8 $data [dict get $cfg width]]
            if {$c_recalc == $ecc} { return [list $data "ok"] }
            return [list $data "crc_err recalc=$c_recalc stored=$ecc"]
        }
    }
}

#================================================================
# mem_write / mem_read / mem_check
#================================================================
proc mem_write {path addr data} {
    set cfg [_mem_get_cfg $path]
    set width [dict get $cfg width]
    set ecc_w [dict get $cfg ecc_width]
    set layout [dict get $cfg layout]

    set data_int [_parse_sv_value $data]
    if {$data_int eq ""} { error "mem_write: invalid data '$data'" }

    set ecc [_mem_ecc_encode $cfg $data_int]
    set total_w [expr {$width + $ecc_w}]

    if {$layout eq "concat"} {
        set stored [expr {($ecc << $width) | ($data_int & ((1 << $width) - 1))}]
        fv "${path}\[$addr\]" "${total_w}'d$stored"
    } else {
        fv "${path}\[$addr\]" "${width}'d$data_int"
        if {$ecc_w > 0} {
            set ecc_path [dict get $cfg ecc_path]
            if {$ecc_path eq ""} { error "mem_write split: -ecc_path required" }
            fv "${ecc_path}\[$addr\]" "${ecc_w}'d$ecc"
        }
    }
    _fv_log 2 "mem_write: $path\[$addr\] data=$data ecc=$ecc"
}

proc mem_read {path addr} {
    set cfg [_mem_get_cfg $path]
    set width [dict get $cfg width]
    set ecc_w [dict get $cfg ecc_width]
    set layout [dict get $cfg layout]
    set on_err [dict get $cfg on_err]

    if {$layout eq "concat"} {
        set raw_int [_parse_sv_value [gv "${path}\[$addr\]" -dec]]
        if {$raw_int eq ""} { set raw_int 0 }
        set data [expr {$raw_int & ((1 << $width) - 1)}]
        set ecc [expr {$raw_int >> $width}]
    } else {
        set data [_parse_sv_value [gv "${path}\[$addr\]" -dec]]
        set ecc_path [dict get $cfg ecc_path]
        if {$ecc_w > 0 && $ecc_path ne ""} {
            set ecc [_parse_sv_value [gv "${ecc_path}\[$addr\]" -dec]]
        } else { set ecc 0 }
    }

    lassign [_mem_ecc_decode $cfg $data $ecc] corrected status
    if {$status ne "ok"} {
        if {$on_err eq "warn"} {
            _aip_msg warn "mem_read $path\[$addr\] $status (raw_data=$data ecc=$ecc)"
        } elseif {$on_err eq "error"} {
            error "mem_read: $path\[$addr\] $status"
        }
    }
    return $corrected
}

proc mem_check {path addr} {
    set cfg [_mem_get_cfg $path]
    set width [dict get $cfg width]
    set layout [dict get $cfg layout]
    if {$layout eq "concat"} {
        set raw_int [_parse_sv_value [gv "${path}\[$addr\]" -dec]]
        set data [expr {$raw_int & ((1 << $width) - 1)}]
        set ecc [expr {$raw_int >> $width}]
    } else {
        set data [_parse_sv_value [gv "${path}\[$addr\]" -dec]]
        set ecc_path [dict get $cfg ecc_path]
        if {$ecc_path eq ""} {
            set ecc 0
        } else {
            set ecc [_parse_sv_value [gv "${ecc_path}\[$addr\]" -dec]]
        }
    }
    lassign [_mem_ecc_decode $cfg $data $ecc] _ status
    return $status
}

#================================================================
# Block / pattern writes
#================================================================
proc mem_write_block {path addr data_list} {
    set i 0
    foreach d $data_list {
        mem_write $path [expr {$addr + $i}] $d
        incr i
    }
    _fv_log 1 "mem_write_block: $path\[$addr..[expr $addr+$i-1]\] $i entries"
}

proc mem_read_block {path addr count} {
    set out {}
    for {set i 0} {$i < $count} {incr i} {
        lappend out [mem_read $path [expr {$addr + $i}]]
    }
    return $out
}

proc mem_write_zero {path addr count} {
    for {set i 0} {$i < $count} {incr i} { mem_write $path [expr {$addr + $i}] 0 }
    _fv_log 1 "mem_write_zero: $path\[$addr..[expr $addr+$count-1]\]"
}

proc mem_write_incr {path addr count {start 0}} {
    for {set i 0} {$i < $count} {incr i} {
        mem_write $path [expr {$addr + $i}] [expr {$start + $i}]
    }
    _fv_log 1 "mem_write_incr: $path\[$addr..[expr $addr+$count-1]\] start=$start"
}

proc mem_write_random {path addr count args} {
    set opts [_fv_parse_opts $args {seed -1}]
    set seed [dict get $opts seed]
    if {$seed >= 0} { expr {srand($seed)} }
    set cfg [_mem_get_cfg $path]
    set width [dict get $cfg width]
    for {set i 0} {$i < $count} {incr i} {
        if {$width <= 30} {
            set max [expr {(1 << $width) - 1}]
            set rval [expr {int(rand() * ($max + 1))}]
        } else {
            set lo [expr {entier(rand() * (1 << 30))}]
            set hi [expr {entier(rand() * (1 << ($width - 30)))}]
            set rval [expr {($hi << 30) | $lo}]
        }
        mem_write $path [expr {$addr + $i}] $rval
    }
    _fv_log 1 "mem_write_random: $path\[$addr..[expr $addr+$count-1]\] seed=$seed"
}

#================================================================
# mem_inject_err / mem_scrub
#================================================================
proc mem_inject_err {path addr bit_pos} {
    set cfg [_mem_get_cfg $path]
    set width [dict get $cfg width]
    set ecc_w [dict get $cfg ecc_width]
    set total_w [expr {$width + $ecc_w}]
    set layout [dict get $cfg layout]

    if {$layout eq "concat"} {
        set raw_int [_parse_sv_value [gv "${path}\[$addr\]" -dec]]
        set flipped [expr {$raw_int ^ (1 << $bit_pos)}]
        fv "${path}\[$addr\]" "${total_w}'d$flipped"
    } else {
        if {$bit_pos < $width} {
            set raw_int [_parse_sv_value [gv "${path}\[$addr\]" -dec]]
            set flipped [expr {$raw_int ^ (1 << $bit_pos)}]
            fv "${path}\[$addr\]" "${width}'d$flipped"
        } else {
            set ecc_path [dict get $cfg ecc_path]
            set b [expr {$bit_pos - $width}]
            set raw_int [_parse_sv_value [gv "${ecc_path}\[$addr\]" -dec]]
            set flipped [expr {$raw_int ^ (1 << $b)}]
            fv "${ecc_path}\[$addr\]" "${ecc_w}'d$flipped"
        }
    }
    _fv_log 1 "mem_inject_err: $path\[$addr\] bit $bit_pos flipped"
}

proc mem_scrub {path addr_from addr_to args} {
    set opts [_fv_parse_opts $args {fix 0}]
    set do_fix [dict get $opts fix]
    set ok 0; set single 0; set double 0; set other 0
    for {set a $addr_from} {$a <= $addr_to} {incr a} {
        set status [mem_check $path $a]
        if {$status eq "ok"} {
            incr ok
        } elseif {[string match "single_err*" $status]} {
            incr single
            if {$do_fix} {
                set corrected [mem_read $path $a]
                mem_write $path $a $corrected
            }
        } elseif {[string match "double_err*" $status]} {
            incr double
            _aip_msg error "mem_scrub UNCORRECTABLE $path\[$a\] $status"
        } else {
            incr other
            _aip_msg warn "mem_scrub $path\[$a\] $status"
        }
    }
    _aip_msg info "mem_scrub $path\[$addr_from..$addr_to\] ok=$ok single=$single double=$double other=$other fix=$do_fix"
    return [dict create ok $ok single $single double $double other $other]
}

#================================================================
# utils_help — 内置帮助 (覆盖整个 aip_ucli_utils 全部命令)
#   utils_help                   ;# 列出所有命令 (按类别)
#   utils_help <name>            ;# 详细 + 示例
#   utils_help -category force   ;# 按类别筛选
#
# fv_help 保留为别名, 向后兼容
#================================================================
array set ::_fv_help_db {}

proc _fv_help_add {name category synopsis usage example} {
    set ::_fv_help_db($name) [list $category $synopsis $usage $example]
}

# ----- Force -----
_fv_help_add fv force \
    "single signal force/deposit" \
    "fv <path> <val> \[-force\]" \
    "fv tb.dut.cfg_reg 32'hDEADBEEF\nfv tb.dut.go 1 -force"
_fv_help_add fv_bit force \
    "bit / bit-range force/deposit" \
    "fv_bit <path> <bit|hi:lo> <val> \[-force\]" \
    "fv_bit tb.dut.cfg_reg 7 1\nfv_bit tb.dut.cfg_reg 15:8 8'hAA"
_fv_help_add fv_fill force \
    "loop fill memory range" \
    "fv_fill <path> <val> <count> \[-from N\] \[-step N\] \[-val_step N\] \[-count2 N\] \[-from2 N\] \[-step2 N\] \[-force\]" \
    "fv_fill tb.dut.mem{i} 0 2048\nfv_fill tb.dut.mem{i} 0 256 -from 100 -step 2 -val_step 1\nfv_fill tb.dut.mem{i}{j} 0 16 -count2 8"
_fv_help_add fv_random force \
    "random fill" \
    "fv_random <path> <count> \[-from N\] \[-step N\] \[-width N\] \[-seed N\] \[-force\]" \
    "fv_random tb.dut.mem{i} 1024 -width 32 -seed 42"
_fv_help_add fv_zero force "zero-fill (alias)" "fv_zero <path> <count>" "fv_zero tb.dut.mem{i} 2048"
_fv_help_add fv_ones force "all-1s fill"       "fv_ones <path> <count>" "fv_ones tb.dut.mem{i} 2048"
_fv_help_add fv_incr force "incrementing pattern (val=idx)" "fv_incr <path> <count>" "fv_incr tb.dut.mem{i} 2048"
_fv_help_add fv_at         force "force/deposit at base\[idx\] (避免 TCL 解析 [])" "fv_at <base> <idx> <val> \[-force\]" "fv_at tb.dut.mem 5 32'hAA"
_fv_help_add gv_at         get   "get at base\[idx\] (避免 TCL 解析 [])" "gv_at <base> <idx> \[-hex|-dec|-bin\]" "gv_at tb.dut.mem 5 -hex"
_fv_help_add fv_at_bit     force "fv_bit wrapper" "fv_at_bit <base> <bit|hi:lo> <val>" "fv_at_bit tb.dut.cfg_reg 7 1"
_fv_help_add fv_at_release force "release at base\[idx\]" "fv_at_release <base> <idx>" "fv_at_release tb.dut.mem 5"

# ----- Get / Release -----
_fv_help_add gv get \
    "get signal value with radix conversion" \
    "gv <path> \[-hex|-dec|-bin|-raw\]" \
    "gv tb.dut.cfg_reg -hex\nset v \[gv tb.dut.mem\[5\] -dec\]"
_fv_help_add fv_release get "release force on signal" "fv_release <path>" "fv_release tb.dut.cfg_reg"
_fv_help_add unforce    get "alias of fv_release"     "unforce <path>"    "unforce tb.dut.cfg_reg"

# ----- Flow -----
_fv_help_add run_to flow \
    "advance sim until signal matches value (poll)" \
    "run_to <path> <val> \[-timeout T\] \[-poll T\]" \
    "run_to tb.dut.done 1 -timeout 1us -poll 50ns"
_fv_help_add wait_posedge flow \
    "advance until N posedges on clock" \
    "wait_posedge <clk> \[-n N\] \[-timeout T\] \[-poll T\]" \
    "wait_posedge tb.dut.clk -n 10 -timeout 500ns"
_fv_help_add pulse flow \
    "force val for duration, release, deposit default" \
    "pulse <path> <val> <duration> \[-default V\]" \
    "pulse tb.dut.go 1 100ns\npulse tb.dut.req 1 50ns -default 0"
_fv_help_add reset_dut flow \
    "standard reset pulse" \
    "reset_dut <rst_path> <active_val> <duration>" \
    "reset_dut tb.dut.rst_n 0 100ns"

# ----- Dump -----
_fv_help_add dump_fsdb_start dump \
    "start FSDB dump (fallback VCD if PLI missing)" \
    "dump_fsdb_start \[-file f\] \[-level N\] \[-scope path\]" \
    "dump_fsdb_start -file wave.fsdb -level 0"
_fv_help_add dump_fsdb_stop  dump "stop FSDB/VCD dump" "dump_fsdb_stop" ""
_fv_help_add dump_vcd_start  dump "start VCD dump"     "dump_vcd_start \[file\]" "dump_vcd_start wave.vcd"

# ----- Memory I/O -----
_fv_help_add dump_mem mem \
    "read memory range, write hex file" \
    "dump_mem <path> \[-from N\] \[-to N\] \[-file f\] \[-width N\]" \
    "dump_mem tb.dut.mem{i} -from 0 -to 1023 -file out.hex"
_fv_help_add load_mem mem \
    "read hex file, force/deposit memory range" \
    "load_mem <path> \[-from N\] \[-file f\] \[-force\]" \
    "load_mem tb.dut.mem{i} -file in.hex -from 0"

# ----- Debug -----
_fv_help_add bp_set debug \
    "conditional breakpoint (wraps UCLI when)" \
    "bp_set <path> <val> { action }" \
    "bp_set tb.dut.error 1 { puts \"ERR @ \[time_now\]\" ; stop }"
_fv_help_add bp_clear debug "clear breakpoint by id or all" "bp_clear \[id|all\]" "bp_clear all"
_fv_help_add bp_list  debug "list active breakpoints"        "bp_list" ""
_fv_help_add find_signal debug \
    "search hierarchy for signals matching regex" \
    "find_signal <regex> \[-scope path\]" \
    "find_signal {clk|reset} -scope tb.dut"
_fv_help_add drivers_of debug "show drivers of signal" "drivers_of <path>" "drivers_of tb.dut.cfg_reg"
_fv_help_add loads_of   debug "show loads of signal"   "loads_of <path>"   "loads_of tb.dut.cfg_reg"

# ----- Util -----
_fv_help_add safe_finish util "close dumps then end_test (or finish)" "safe_finish" ""
_fv_help_add time_now    util "current sim time string" "time_now" ""
_fv_help_add batch       util "execute block (syntactic grouping)" "batch { cmds... }" "batch { fv a 1 ; fv b 2 }"
_fv_help_add utils_help   util "show help (list or detail)" "utils_help \[name\] \[-category cat\]" "utils_help fv_fill\nutils_help -category mem"
_fv_help_add utils_silent util "关闭 VCS UCLI 命令回显 (ucli% prompt + cmd echo)" "utils_silent" ""
_fv_help_add utils_loud   util "恢复 UCLI 命令回显" "utils_loud" ""
_fv_help_add fv_help     util "alias of utils_help (backward compat)" "fv_help \[name\] \[-category cat\]" "fv_help fv_fill"

# ----- ECC mem -----
_fv_help_add mem_cfg ecc \
    "configure mem path: width / ecc_mode / layout / on_err" \
    "mem_cfg <path> -width N -ecc_mode {none|parity|secded|crc8} \[-parity_grain {8|16|32|word}\] \[-parity_polarity {even|odd}\] \[-on_err {warn|silent|error}\] \[-layout {concat|split}\] \[-ecc_path X\]" \
    "mem_cfg tb.dut.ram -width 32 -ecc_mode secded\nmem_cfg tb.dut.ram -width 32 -ecc_mode parity -parity_grain 8\nmem_cfg tb.dut.ram -width 64 -ecc_mode crc8 -layout split -ecc_path tb.dut.ram_ecc"
_fv_help_add mem_write  ecc "write raw data, auto-compute & store ECC" "mem_write <path> <addr> <data>" "mem_write tb.dut.ram 0x10 32'hDEADBEEF"
_fv_help_add mem_read   ecc "read mem, auto-verify ECC, return raw data" "mem_read <path> <addr>" "set v \[mem_read tb.dut.ram 0x10\]"
_fv_help_add mem_check  ecc "verify entry, return ok/single_err/double_err" "mem_check <path> <addr>" "mem_check tb.dut.ram 5"
_fv_help_add mem_write_block ecc "write list of data starting at addr" "mem_write_block <path> <addr> <list>" "mem_write_block tb.dut.ram 0 {1 2 3 4}"
_fv_help_add mem_read_block  ecc "read N entries, return list" "mem_read_block <path> <addr> <count>" "mem_read_block tb.dut.ram 0 16"
_fv_help_add mem_write_zero   ecc "zero range" "mem_write_zero <path> <addr> <count>" "mem_write_zero tb.dut.ram 0 1024"
_fv_help_add mem_write_incr   ecc "incrementing pattern (0,1,2,...)" "mem_write_incr <path> <addr> <count> \[start\]" "mem_write_incr tb.dut.ram 0 256"
_fv_help_add mem_write_random ecc "random fill" "mem_write_random <path> <addr> <count> \[-seed N\]" "mem_write_random tb.dut.ram 0 1024 -seed 42"
_fv_help_add mem_inject_err ecc "flip a bit in stored entry (force ECC fault)" "mem_inject_err <path> <addr> <bit_pos>" "mem_inject_err tb.dut.ram 5 3"
_fv_help_add mem_scrub      ecc "scan range, count errors, optionally auto-fix single errs" "mem_scrub <path> <from> <to> \[-fix 0|1\]" "mem_scrub tb.dut.ram 0 1023 -fix 1"
_fv_help_add mem_cfg_list   ecc "list all configured mem paths + summary" "mem_cfg_list" ""
_fv_help_add mem_cfg_get    ecc "get full config dict for a path" "mem_cfg_get <path>" "mem_cfg_get tb.dut.ram"
_fv_help_add mem_cfg_clear  ecc "clear config (one path or all)" "mem_cfg_clear \[path|all\]" "mem_cfg_clear tb.dut.ram\nmem_cfg_clear all"

proc utils_help {args} {
    set filter_cat ""
    set target ""
    set i 0
    while {$i < [llength $args]} {
        set a [lindex $args $i]
        if {$a eq "-category"} {
            incr i
            set filter_cat [lindex $args $i]
        } else {
            set target $a
        }
        incr i
    }

    if {$target ne ""} {
        if {![info exists ::_fv_help_db($target)]} {
            puts "utils_help: unknown command '$target'"
            return
        }
        lassign $::_fv_help_db($target) cat synopsis usage example
        puts "----------------------------------------------------------------"
        puts " $target  \[$cat\]"
        puts "----------------------------------------------------------------"
        puts " $synopsis"
        puts ""
        puts " Usage:"
        puts "   $usage"
        if {$example ne ""} {
            puts ""
            puts " Example:"
            foreach line [split $example "\n"] { puts "   $line" }
        }
        puts "----------------------------------------------------------------"
        return
    }

    set cats {force get flow dump mem ecc debug util}
    array set by_cat {}
    foreach name [lsort [array names ::_fv_help_db]] {
        lassign $::_fv_help_db($name) cat synopsis _ _
        if {$filter_cat ne "" && $cat ne $filter_cat} { continue }
        lappend by_cat($cat) [list $name $synopsis]
    }

    puts "================================================================"
    puts " AIP UCLI Utils — Commands"
    puts " Detail:  utils_help <name>"
    puts " Filter:  utils_help -category {force|get|flow|dump|mem|ecc|debug|util}"
    puts " Verbose: set ::fv_verbose {0|1|2}"
    puts "================================================================"
    foreach cat $cats {
        if {![info exists by_cat($cat)]} continue
        puts ""
        puts " \[$cat\]"
        foreach item $by_cat($cat) {
            lassign $item name synopsis
            puts [format "   %-22s %s" $name $synopsis]
        }
    }
    puts ""
    puts "================================================================"
}

# 向后兼容别名
proc fv_help {args} { uplevel 1 [list utils_help {*}$args] }

#================================================================
# Startup banner
#================================================================
puts "================================================================"
puts " AIP UCLI Utils loaded"
puts " Force:   fv, fv_bit, fv_fill, fv_random, fv_zero, fv_ones, fv_incr"
puts "          fv_at, fv_at_bit, fv_at_release (避免 TCL [] 解析问题)"
puts " Get:     gv, gv_at, fv_release (alias: unforce)"
puts " Flow:    run_to, wait_posedge, pulse, reset_dut"
puts " Dump:    dump_fsdb_start, dump_fsdb_stop, dump_vcd_start"
puts " Mem:     dump_mem, load_mem"
puts " ECC:     mem_cfg, mem_cfg_list/_get/_clear, mem_write, mem_read, mem_check"
puts "          mem_write_block/_zero/_incr/_random, mem_read_block, mem_inject_err, mem_scrub"
puts " Debug:   bp_set, bp_clear, bp_list, find_signal, drivers_of, loads_of"
puts " Util:    safe_finish, time_now, batch, utils_help (alias: fv_help)"
puts "          utils_silent / utils_loud  (UCLI 命令回显开关)"
puts " Config:  set ::fv_verbose {0|1|2}"
puts "================================================================"
