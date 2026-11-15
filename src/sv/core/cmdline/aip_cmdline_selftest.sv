//===========================================================
// 所属层次：src/sv/core/cmdline（内部 include 片段，不是独立 compilation unit）。
// 旧版 standalone 自测模块 test_param_parser_full；从原聚合文件等价迁出。
// 仅由聚合入口在 AIP_CMDLINE_TEST 定义时加载，依赖已加载的公共宏和解析类。
// 模块持有测试变量，initial 顺序执行并结束仿真；此旧开关不用于 aip_core_pkg 的包内入口。
// 只允许 aip_cmdline.sv 在其 include 窗口加载；拒绝直接包含，避免创建第二份 $unit/package 类型。
// 聚合入口持有唯一的 AIP_CMDLINE_SV 防重入 guard，本文件不声明新的 package。
// 本次仅按职责迁移定义，原有函数实现和宏展开语句保持不变。
//===========================================================
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else
module test_param_parser_full;

    typedef enum { FAST_MODE, SLOW_MODE, NORMAL_MODE } test_mode_e;
    typedef struct {
        int    addr;
        int    len;
        string name;
        real   freq;
        test_mode_e mode;
    } test_cfg_t;

    initial begin
        real real_plain;
        real real_range;
        real real_list;
        real real_sci;
        real real_arr[];
        byte byte_val;
        bit [7:0] bit8_val;
        int int_plain;
        int int_hex;
        int int_bin;
        int int_range;
        int int_list;
        int int_weight;
        int int_inc;
        int int_dec;
        int val_int;
        string str_list;
        string str_plain;
        string str_with_spaces;
        int val_enum;
        int int_array[];
        string str_array[];
        int dyn_arr2[];
        int dyn_arr[];
        int sarray[10];
        string colors[] = {"RED","GREEN","BLUE"};
        int cvals[] = '{0,1,2};

        $display("=====================================");
        $display("========== 测试1：单个int参数 ==========");
        $display("=====================================");
        `aip_int("int_plain",int, int_plain,2);
        $display("int_plain (100) → %0d", int_plain);
        `aip_int("int_hex", int, int_hex,0);
        $display("int_hex (0x7F) → %0d", int_hex);
        `aip_int("int_bin", int, int_bin);
        $display("int_bin (0b1010) → %0d", int_bin);
        `aip_int("int_range", int, int_range);
        $display("int_range ([1:10]) → %0d", int_range);
        `aip_int("int_list", int, int_list);
        $display("int_list (10,20,30) → %0d", int_list);
        `aip_int("int_weight", int, int_weight);   // 单个权重项
        $display("int_weight (0:=40) → %0d", int_weight);
        `aip_int("int_inc", int, int_inc);
        $display("int_inc (inc:0:10:2) → %0d", int_inc);
        `aip_int("int_dec", int, int_dec);
        $display("int_dec (dec:10:0:2) → %0d", int_dec);

        $display("\n=====================================");
        $display("========== 测试2：单个string参数 =========");
        $display("=====================================");
        `aip_string("str_plain", str_plain ,"default");
        $display("str_plain (hello_world) → '%s'", str_plain);
        `aip_string("str_list", str_list, "default");
        $display("str_list (apple,banana,orange) → '%s'", str_list);
        `aip_string("str_with_spaces",str_with_spaces, "default");
        $display("str_with_spaces ('hello world') → '%s'", str_with_spaces);

        $display("\n=====================================");
        $display("========== 测试4：int数组（包含复合权重）======");
        $display("=====================================");
        `aip_int_list("int_array", int, int_array);
        $write("int_array (1,2,[8:9],10:20,{0:=40,[1:3]:=60},([1:5]:/10),100) → ");
        foreach (int_array[i]) $write("%0d ", int_array[i]);
        $display("");
        $display("数组长度（预期7）→ %0d", int_array.size());

        $display("\n=====================================");
        $display("========== 测试5：string数组 ==========");
        $display("=====================================");
        `aip_str_list("str_array", str_array);
        $write("str_array (aaa,bbb,ccc,hello world) → ");
        foreach (str_array[i]) $write("'%s' ", str_array[i]);
        $display("");
        $display("数组长度（预期4）→ %0d", str_array.size());

        $display("\n=====================================");
        $display("========== 测试6：路径优先 ==========");
        $display("=====================================");
        `aip_int("path_param", int, val_int);
        $display("path_param (无路径) → %0d", val_int);
        `aip_int("path_param", int, val_int);
        $display("path_param (path=top) → %0d", val_int);

        $display("\n=====================================");
        $display("========== 测试7：后定义覆盖 ==========");
        $display("=====================================");
        `aip_int("cover_param", int, val_int);
        $display("cover_param (后定义200覆盖100) → %0d", val_int);

        $display("\n=====================================");
        $display("========== 测试8：全局必填开关 =========");
        $display("=====================================");
        `aip_int("non_exist", int, val_int,999);
        $display("non_exist (关闭必填，返回默认值999) → %0d", val_int);
        aip_cmdline#(int)::global_required = 1;
        $display("开启全局必填，访问不存在的参数会触发Fatal（以下是预期报错）");
        // `aip_int("non_exist", "", 0, val_int); // 取消注释验证报错
        aip_cmdline#(int)::global_required = 0;

        $display("\n=====================================");
        $display("========== 测试9：动态数组 with .size =========");
        $display("=====================================");
        `aip_int_list("dyn_array", int, dyn_arr);
        $write("dyn_array (size=[3:5], overall=1,2,3, index[1]=[10:20]) → ");
        foreach (dyn_arr[i]) $write("%0d ", dyn_arr[i]);
        $display("");

        $display("\n=====================================");
        $display("========== 测试10：动态数组 without .size =========");
        $display("=====================================");
        `aip_int_slist("",int, sarray,1)
        $write("sarray (overall=1,2,3,4,5) → ");
        foreach (sarray[i]) $write("%0d ", sarray[i]);
        $display("");

        // ========== 测试11：real 类型 ==========
        $display("\n=====================================");
        $display("========== 测试11：real参数 ==========");
        $display("=====================================");
        `aip_real("", real_plain, 0.0)
        $display("real_plain → %g", real_plain);
        `aip_real("", real_sci, 100.0e6)
        $display("real_sci → %g", real_sci);
        `aip_real("", real_range, 0.0)
        $display("real_range ([0.8:1.0]) → %g", real_range);
        `aip_real("", real_list, 0.0)
        $display("real_list (0.8,0.9,1.0) → %g", real_list);

        // ========== 测试12：real 数组 ==========
        $display("\n=====================================");
        $display("========== 测试12：real数组 ==========");
        $display("=====================================");
        `aip_real_list("", real_arr, 0.0)
        $write("real_arr → ");
        foreach (real_arr[i]) $write("%g ", real_arr[i]);
        $display("");

        // ========== 测试13：byte 类型 ==========
        $display("\n=====================================");
        $display("========== 测试13：byte参数 ==========");
        $display("=====================================");
        `aip_int("", byte, byte_val, 0)
        $display("byte_val → %0d", byte_val);
        `aip_int("", bit[7:0], bit8_val, 0)
        $display("bit8_val → %0d", bit8_val);

        // ========== 测试14：enum 类型 ==========
        $display("\n=====================================");
        $display("========== 测试14：enum参数 ==========");
        $display("=====================================");
        begin
            test_mode_e test_mode;
            `aip_enum("", test_mode_e, test_mode, NORMAL_MODE)
            $display("test_mode → %s (%0d)", test_mode.name(), test_mode);
        end

        // ========== 测试15：struct 类型 ==========
        $display("\n=====================================");
        $display("========== 测试15：struct参数 ==========");
        $display("=====================================");
        begin
            test_cfg_t test_cfg;
            `aip_struct_begin("", test_cfg)
                `aip_struct_int(test_cfg, addr, 0)
                `aip_struct_int(test_cfg, len, 64)
                `aip_struct_string(test_cfg, name, "default")
                `aip_struct_real(test_cfg, freq, 100.0e6)
                `aip_struct_enum(test_mode_e, test_cfg, mode, NORMAL_MODE)
            `aip_struct_end(test_cfg)
            $display("test_cfg.addr → 0x%0h", test_cfg.addr);
            $display("test_cfg.len  → %0d", test_cfg.len);
            $display("test_cfg.name → '%s'", test_cfg.name);
            $display("test_cfg.freq → %g", test_cfg.freq);
            $display("test_cfg.mode → %s", test_cfg.mode.name());
        end

        $display("\n=====================================");
        $display("========== 所有测试完成 ==========");
        $display("=====================================");
        $finish;
    end
endmodule
`endif // AIP_CMDLINE_INTERNAL_INCLUDE
