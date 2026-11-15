# dist/tests：不启动仿真的加载契约测试，使用本测试拥有的临时假模块。
# 验证源码与.so入口的幂等/缺失诊断；真实库内容另在53的UCLI用例验证。

set dist_dir [file normalize [file join [file dirname [info script]] ..]]
set loader   [file join $dist_dir aip_init.tcl]
set tmp_root [file join [pwd] .aip_init_test_tmp]
file delete -force $tmp_root
file mkdir $tmp_root
set tcl_files {src/tcl/aip_sim_control.tcl src/tcl/aip_watch.tcl src/tcl/aip_inject.tcl src/tcl/aip_cmd.tcl src/tcl/aip_checkpoint.tcl src/tcl/aip_ucli_utils.tcl}
foreach name $tcl_files {
    set path [file join $tmp_root $name]
    file mkdir [file dirname $path]
    set fh [open $path w]
    puts $fh "set ::aip_init_loaded($name) 1"
    close $fh
}

set passed 0
set failed 0
proc check {name condition} {
    upvar passed p failed f
    if {$condition} {
        puts "PASS $name"
        incr p
    } else {
        puts "FAIL $name"
        incr f
    }
}

# Sourcing the bootstrap alone must initialize the implementation files.
set probe_dist [file join $tmp_root dist]
file mkdir $probe_dist
set probe_loader [file join $probe_dist aip_init.tcl]
file copy -force $loader $probe_loader
set probe [file join $tmp_root source_only.tcl]
set fh [open $probe w]
puts $fh "source [list [file join $probe_dist aip_init.tcl]]"
puts $fh {foreach module {aip_sim_control aip_watch aip_inject aip_cmd aip_checkpoint aip_ucli_utils} {if {![info exists ::aip_init_loaded(src/tcl/$module.tcl)]} {exit 1}}}
close $fh
set rc [catch {exec [info nameofexecutable] $probe} err]
check "source alone initializes Tcl files" [expr {$rc == 0}]

source $probe_loader
set rc [catch {aip_init $tmp_root} err]
check "sources all implementation files" [expr {$rc == 0}]
foreach name $tcl_files {
    check "sources $name" [expr {[info exists ::aip_init_loaded($name)]}]
}

set before_state [array get ::aip_init_loaded]
set rc [catch {aip_init $tmp_root} err]
check "repeated init is idempotent" \
      [expr {$rc == 0 && [array get ::aip_init_loaded] eq $before_state}]

set missing_root [file join $tmp_root missing]
file mkdir $missing_root
set ::aip_initialized 0
set rc [catch {aip_init $missing_root} err]
check "missing source reports an error" \
      [expr {$rc != 0 && [string match {*aip_sim_control.tcl*not found*} $err]}]

# aip_init_so.tcl (binary loader): the two paths that need no VCS.
set so_loader [file join $dist_dir aip_init_so.tcl]
set probe_so_loader [file join $probe_dist aip_init_so.tcl]
file copy -force $so_loader $probe_so_loader
# "Already initialized" now means the flag is set *and* the commands the loader
# defines are present; VCS `restore` keeps the flag but drops the commands.
set ::aip_initialized 1
proc aip_send_cmd {args} {}
set rc [catch {source $probe_so_loader} err]
check "so loader is a no-op when already initialized" [expr {$rc == 0}]

# The loader also searches the current directory, so the two probes below run
# from a directory that holds no lib/ (running the test from dist/ or from the
# repository root would otherwise find the real library).
set saved_cwd [pwd]
cd $tmp_root

# Flag still set, commands gone: this is the post-restore state, and the loader
# must look for the library again rather than silently do nothing.
rename aip_send_cmd {}
set rc [catch {source $probe_so_loader} err]
check "so loader re-loads when its commands are gone" \
      [expr {$rc != 0 && [string match {*libaip_tcl_bridge.so*} $err]}]

set ::aip_initialized 0
set rc [catch {source $probe_so_loader} err]
check "so loader reports a missing library" \
      [expr {$rc != 0 && [string match {*libaip_tcl_bridge.so*not found*} $err]}]

cd $saved_cwd

file delete -force $tmp_root

puts "AIP_INIT_PASS passed=$passed failed=$failed"
if {$failed != 0} { exit 1 }
