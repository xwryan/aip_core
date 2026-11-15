# 在 VCS 内嵌 Tcl 或 host Tcl 中解析已生成的 RAL 记录（不驱动 DUT）；逐 byte 重建与 bridge/inject 一致，不借 UTF8 解码掩盖桥接错误。
set ral_records_path [file join [pwd] ral_records.txt]
if {[info exists argv] && [llength $argv] == 1 && [file exists [lindex $argv 0]]} {
    set ral_records_path [lindex $argv 0]
}
set ral_checks 0
proc ral_demand {condition label} {
    if {!$condition} { error "RAL_FOUNDATION_TCL_ASSERT $label" }
    incr ::ral_checks
}
# 严格模拟逐byte format %c，同时验证inject的ASCII限制。
proc ral_bridge_bytes {encoded} {
    binary scan $encoded cu* values
    set rebuilt ""
    foreach value $values {
        ral_demand [expr {$value <= 127}] "non_ASCII_wire"
        append rebuilt [format %c $value]
    }
    return $rebuilt
}
# 只按首个等号切分；整元素必须先经合法Tcl list解析。
proc ral_fields {encoded} {
    set fields [dict create]
    ral_demand [expr {[llength $encoded] >= 1}] "empty_result"
    dict set fields _status [lindex $encoded 0]
    foreach element [lrange $encoded 1 end] {
        set equal [string first = $element]
        ral_demand [expr {$equal > 0}] "key_value_element"
        set key [string range $element 0 [expr {$equal - 1}]]
        ral_demand [expr {![dict exists $fields $key]}] "duplicate_key"
        dict set fields $key [string range $element [expr {$equal + 1}] end]
    }
    return $fields
}
# fallback精确键序，不能省略安全envelope或添加伪叶计数。
proc ral_schema {fields expected} {
    ral_demand [expr {[dict keys $fields] eq [linsert $expected 0 _status]}] "exact_schema_order"
    ral_demand [expr {[dict get $fields _status] eq "ERROR" && [dict get $fields code] eq "RESULT_TOO_LARGE"}] "fallback_status_code"
    ral_demand [expr {[dict get $fields limit] == 1024 && [dict get $fields required_bytes] > 1024}] "fallback_bytes"
}
set ral_channel [open $ral_records_path r]
fconfigure $ral_channel -translation lf -encoding ascii
set ral_records [dict create]
while {[gets $ral_channel line] >= 0} {
    set separator [string first "\t" $line]
    ral_demand [expr {$separator > 0}] "record_separator"
    set label [string range $line 0 [expr {$separator - 1}]]
    ral_demand [expr {![dict exists $ral_records $label]}] "duplicate_record"
    dict set ral_records $label [ral_bridge_bytes [string range $line [expr {$separator + 1}] end]]
}
close $ral_channel
set ral_expected_records {QUOTE_SPACE QUOTE_EMPTY QUOTE_HOSTILE QUOTE_UTF8 PRE_ERROR EXACT_LIMIT PREFLIGHT RUNTIME_PRE RUNTIME_OP LEAF_FAIL RUNTIME_POST PASS}
ral_demand [expr {[dict keys $ral_records] eq $ral_expected_records}] "record_inventory"
ral_demand [expr {[llength [dict get $ral_records QUOTE_SPACE]] == 1 && [lindex [dict get $ral_records QUOTE_SPACE] 0] eq "detail=two words"}] "space_roundtrip"
ral_demand [expr {[llength [dict get $ral_records QUOTE_EMPTY]] == 1 && [lindex [dict get $ral_records QUOTE_EMPTY] 0] eq ""}] "empty_roundtrip"
set ral_unicode [encoding convertfrom utf-8 [binary format H* c3a9e4b8adf09f9880]]
ral_demand [expr {[llength [dict get $ral_records QUOTE_UTF8]] == 1 && [lindex [dict get $ral_records QUOTE_UTF8] 0] eq "detail=$ral_unicode"}] "UTF8_BMP_astral_roundtrip"
set ral_hostile {detail= a {b} \path [cmd] $x; "q"\n\r}
append ral_hostile "\t" [encoding convertfrom utf-8 [binary format H* e4b8adf09f9880]]
ral_demand [expr {[llength [dict get $ral_records QUOTE_HOSTILE]] == 1 && [lindex [dict get $ral_records QUOTE_HOSTILE] 0] eq $ral_hostile}] "hostile_single_element_roundtrip"
set ral_pre [ral_fields [dict get $ral_records PRE_ERROR]]
ral_demand [expr {[dict get $ral_pre _status] eq "ERROR" && [dict get $ral_pre inventory_complete] == 0 && ![dict exists $ral_pre total]}] "pre_inventory_no_fake_counts"
ral_demand [expr {[string length [dict get $ral_records EXACT_LIMIT]] == 1024 && [dict get [ral_fields [dict get $ral_records EXACT_LIMIT]] code] eq "CONFIG_ERROR"}] "exact_limit_keeps_original"
set ral_safety {side_effects partial restore resumed recovery_required required_bytes limit}
set ral_counts {total fields memories mem_mode memory_entries_tested restore_scope reset_attempted reset_performed destructive write_once_consumed passed excluded failed errors untestable not_applicable global_errors}
set ral_preflight [ral_fields [dict get $ral_records PREFLIGHT]]
ral_schema $ral_preflight [concat {code command suite phase inventory_complete reset_attempted reset_performed destructive} $ral_safety]
ral_demand [expr {[dict get $ral_preflight side_effects] eq "0" && [dict get $ral_preflight destructive] == 0 && [dict get $ral_preflight required_bytes] == 1025}] "preflight_clean_zero_action_envelope"
set ral_runtime_pre [ral_fields [dict get $ral_records RUNTIME_PRE]]
ral_schema $ral_runtime_pre [concat {code command suite original_status original_code phase original_phase inventory_complete reset_attempted reset_performed destructive} $ral_safety]
set ral_runtime_op [ral_fields [dict get $ral_records RUNTIME_OP]]
ral_schema $ral_runtime_op [concat {code command original_status original_code phase original_phase} $ral_safety]
ral_demand [expr {[dict get $ral_runtime_op original_code] eq "BUS_ERROR"}] "op_original_code_preserved"
foreach fields [list $ral_runtime_pre $ral_runtime_op] {
    ral_demand [expr {[dict get $fields side_effects] eq "unknown" && [dict get $fields partial] eq "unknown" && [dict get $fields restore] eq "not_guaranteed" && [dict get $fields resumed] == 0 && [dict get $fields recovery_required] == 1}] "runtime_safety_preserved"
}
set ral_post [ral_fields [dict get $ral_records RUNTIME_POST]]
ral_schema $ral_post [concat {code command suite original_status original_code phase original_phase inventory_complete} $ral_counts $ral_safety]
ral_demand [expr {[dict get $ral_post total] == 5 && [dict get $ral_post fields] + [dict get $ral_post memories] == 5 && [dict get $ral_post errors] == 2 && [dict get $ral_post failed] == 1 && [dict get $ral_post excluded] == 1 && [dict get $ral_post untestable] == 1}] "post_inventory_counts_preserved"
ral_demand [expr {[dict get $ral_post reset_attempted] == 1 && [dict get $ral_post reset_performed] == 1 && [dict get $ral_post destructive] == 1 && [dict get $ral_post global_errors] == 4 && [dict get $ral_post restore] eq "failed"}] "post_inventory_reset_safety_preserved"
set ral_leaf [ral_fields [dict get $ral_records LEAF_FAIL]]
ral_demand [expr {[dict get $ral_leaf _status] eq "FAIL" && [dict get $ral_leaf first_status] eq "ERROR" && [dict get $ral_leaf first] eq "soc.leaf0" && [dict get $ral_leaf first_code] eq "BUS_ERROR"}] "leaf_priority_stable"
set ral_pass [ral_fields [dict get $ral_records PASS]]
ral_demand [expr {[dict get $ral_pass _status] eq "PASS" && [dict get $ral_pass total] == 1 && [dict get $ral_pass passed] == 1}] "nonempty_PASS"
foreach label [lrange $ral_expected_records 4 end] {
    ral_demand [expr {[string length [dict get $ral_records $label]] <= 1024}] "bounded_output"
}
puts "RAL_FOUNDATION_TCL_PASS checks=$ral_checks tcl=[info patchlevel]"
if {[llength [info commands quit]]} { quit }
