// 寄存器命令的参数/位宽/错误回传回归，不依赖具体总线 VIP；PCIe 引脚/Completion 由 Intel 集成测试另行验证。
`include "aip_core_pkg.sv"

// 宽标量假后端让解析结果独立可查；未实现总线，不应拿本测试证明 PCIe 时序。
class reg_wide_seq extends uvm_sequence;
    `uvm_object_utils(reg_wide_seq)
    bit	                is_write;
    longint unsigned	  addr;
    int unsigned	      len;
    int unsigned	      mask;
    bit [127:0]	        wdata;
    bit [127:0]	        rdata;
    string	             error_msg;
    static int	         runs;
    static bit [127:0]	 stored[longint unsigned];
    static int unsigned	last_mask;
    static int unsigned	last_len;

    function new(string name = "reg_wide_seq"); super.new(name); endfunction

    // 模拟可处理的业务错误，检查宏不会把失败覆盖为 OK。
    task body();
        runs++;
        last_mask = mask;
        last_len = len;
        if (addr == 'hbad0) begin
            error_msg = "backend read timeout";
            return;
        end
        if (is_write) stored[addr] = wdata;
        else rdata = stored.exists(addr) ? stored[addr] : 0;
    endtask
endclass

// 旧类保留 64 位字段且无 error_msg，证明三参数注册源码仍然兼容。
class reg_legacy_seq extends uvm_sequence;
    `uvm_object_utils(reg_legacy_seq)
    bit	                is_write;
    longint unsigned	  addr;
    int unsigned	      len;
    int unsigned	      mask;
    longint unsigned	  wdata;
    longint unsigned	  rdata;
    static int	         runs;

    function new(string name = "reg_legacy_seq"); super.new(name); endfunction

    // 原样回传，检查 64 位上边界并统计是否误启动超宽访问。
    task body(); runs++; rdata = wdata; endtask
endclass

// 新策略由注册显式映射，旧后端仍不要求增加字段；仅记录每次解析值。
class reg_policy_seq extends reg_wide_seq;
    `uvm_object_utils(reg_policy_seq)
    bit	check_read_data = 1;
    static bit	last_check;
    extern function new(string name = "reg_policy_seq");

    extern task body();
endclass

function reg_policy_seq::new(string name = "reg_policy_seq");
    super.new(name);
endfunction

// 独立记录本次选项，确保省略参数时没有沿用上一次命令的关闭策略。
task reg_policy_seq::body();
    last_check = check_read_data;
    super.body();
endtask

// 注册静态句柄只借用 test 创建的 sequencer，禁止命令自身创建第二套 agent。
class reg_wide_context;
    static uvm_sequencer_base	sqr;
endclass
`aip_cmd_reg(wide, reg_wide_seq, reg_wide_context::sqr, seq.error_msg)
`aip_cmd_creg(strict_wide, reg_wide_seq, reg_wide_context::sqr, seq.error_msg)
`aip_cmd_reg(legacy, reg_legacy_seq, reg_wide_context::sqr)
`aip_cmd_reg(policy, reg_policy_seq, reg_wide_context::sqr, seq.error_msg, seq.check_read_data)
`aip_cmd_creg(strict_policy, reg_policy_seq, reg_wide_context::sqr, seq.error_msg, seq.check_read_data)

// 命令驱动回归覆盖位置/命名格式、宽度溢出、状态和连续访问的新地址。
class reg_wide_test extends uvm_test;
    `uvm_component_utils(reg_wide_test)
    int	checks;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    // 为严格宏提供真实可 grab 的 sequencer，不需要 driver 即可启动无 item 序列。
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        reg_wide_context::sqr = uvm_sequencer#(uvm_sequence_item)::type_id::create("sqr", this);
    endfunction

    // 精确比较成功/失败及结果，不能只凭仿真退出码判定通过。
    task command(string text, bit success, string expected = "");
        int	st;
        string	result;
        aip_cmd::exec_result(text, SRC_INTERNAL, st, result);
        if ((st == 0) != success || (expected != "" && result != expected))
            `uvm_fatal("REG_WIDE", $sformatf("%s -> status=%0d result=%s expected=%s", text, st, result, expected))
        checks++;
    endtask

    // 用独立常量检查最高位数据，负向访问必须在 sequence body 前被拒绝。
    task run_phase(uvm_phase phase);
        int	before_runs;
        phase.raise_objection(this);
        command("wide write 0x1000 16 0x112233445566778899aabbccddeeff00", 1);
        command("wide read 0x1000 16", 1, "rdata=0x112233445566778899aabbccddeeff00");
        if (reg_wide_seq::last_mask != 0) `uvm_fatal("REG_WIDE", "default mask is not zero")
        command("wide write 0x1004 4 0x12345678 mask=2", 1);
        if (reg_wide_seq::last_mask != 2) `uvm_fatal("REG_WIDE", "named mask changed")
        command("wide read 0x1004", 1, "rdata=0x12345678");
        if (reg_wide_seq::last_len != 4) `uvm_fatal("REG_WIDE", "default len changed")
        command("wide op=write addr=0x1008 len=12 data=0xaabbccddeeff112233445566", 1);
        command("wide op=read addr=0x1008 len=12", 1, "rdata=0xaabbccddeeff112233445566");
        command("strict_wide write 0x1010 8 0xffffffffffffffff 0x5", 1);
        if (reg_wide_seq::last_mask != 5) `uvm_fatal("REG_WIDE", "positional mask changed")
        command("strict_wide read 0x1010 8", 1, "rdata=0xffffffffffffffff");
        command("wide write 0x1020 16 340282366920938463463374607431768211455", 1);
        command("wide read 0x1020 16", 1, "rdata=0xffffffffffffffffffffffffffffffff");
        command("wide write 0x1030 16 128'h80000000000000000000000000000000", 1);
        command("wide read 0x1030 16", 1, "rdata=0x80000000000000000000000000000000");
        command("legacy op=read addr=0 data=0xffffffffffffffff", 1, "rdata=0xffffffffffffffff");
        before_runs = reg_legacy_seq::runs;
        command("legacy read 0 check_read_data=0", 0,
            "ERROR: reg legacy: check_read_data is not supported by this registration");
        command("legacy write 0 12 0x10000000000000000", 0);
        if (reg_legacy_seq::runs != before_runs) `uvm_fatal("REG_WIDE", "legacy width overflow started sequence")

        before_runs = reg_wide_seq::runs;
        command("wide read 0 check_read_data=0", 0,
            "ERROR: reg wide: check_read_data is not supported by this registration");
        command("strict_wide read 0 check_read_data=1", 0,
            "ERROR: reg strict_wide: check_read_data is not supported by this registration");
        command("policy read 0 check_read_data=2", 0);
        command("policy read 0 check_read_data=-1", 0);
        command("policy op=read addr=0 check_read_data=junk", 0);
        command("policy read 0 check_read_data=0 check_read_data=1", 0);
        command("wide read", 0);
        command("wide op=read", 0);
        command("wide typo 0x1000 4", 0);
        command("wide write 0 4", 0);
        command("wide write 0 16 0x100000000000000000000000000000000", 0);
        command("wide read 0x10000000000000000", 0);
        command("wide read junk", 0);
        command("wide read 0 len=4", 0);
        command("wide op=read addr=0 addr=4", 0);
        command("wide write 0 4 1 0 mask=1", 0);
        command("wide read 0 4 mask=0x100000000", 0);
        if (reg_wide_seq::runs != before_runs) `uvm_fatal("REG_WIDE", "bad arguments started sequence")
        command("policy read 0 check_read_data=0", 1);
        if (reg_policy_seq::last_check != 0) `uvm_fatal("REG_WIDE", "opt-out was not forwarded")
        command("policy op=read addr=0 check_read_data=1", 1);
        if (reg_policy_seq::last_check != 1) `uvm_fatal("REG_WIDE", "explicit enable was not forwarded")
        command("strict_policy read 0 check_read_data=0", 1);
        if (reg_policy_seq::last_check != 0) `uvm_fatal("REG_WIDE", "strict opt-out was not forwarded")
        command("strict_policy read 0", 1);
        if (reg_policy_seq::last_check != 1) `uvm_fatal("REG_WIDE", "omitted policy did not restore default")
        command("wide read 0xbad0", 0, "ERROR: reg wide: backend read timeout");
        command("strict_wide read 0xbad0", 0, "ERROR: reg strict_wide: backend read timeout");
        if (__aip_active_seqs.num() != 0) `uvm_fatal("REG_WIDE", "sequence registry leaked")
        `uvm_info("REG_WIDE_PASS", $sformatf("checks=%0d", checks), UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

module test_reg_wide;
    initial run_test("reg_wide_test");
endmodule
