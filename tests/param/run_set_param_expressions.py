#!/usr/bin/env python3
"""tests/param：运行来源等价性与错误诊断矩阵；依赖已编译的 VCS simv。

runner 拥有日志，SV 拥有断言和 RNG；使用 argv 列表避免 shell/Tcl 对表达式二次展开。
任一退出码、成功标记或轨迹不符立即失败。只应在指定 VCS 主机执行。
"""
import pathlib
import subprocess


# 所有输入都由真实 plusarg 提供，SV override 模式再经正式 set_param 命令安装。
CASES = {
    "i_fixed": "200", "i_hex": "32'hFACE", "i_signed": "-17", "i_spaces": "2 0 0",
    "i_unsized_hex": "'hFACE", "i_bare_hex": "hFACE",
    "i_range": "[50:200]", "i_bare": "50:200", "i_list": "50,100,200",
    "i_wrapped": "[50,100,200]", "i_mixed": "1,[50:200],300",
    "i_weight": "{0:=0,50:=20,[100:200]:/80}",
    "i_each": "(0:=0,[1:4]:=2,9:/1)", "i_single_weight": "[1:4]:/3",
    "i_inc": "inc:2:8:3", "i_dec": "dec:8:2:3", "i_rand": "rand",
    "r_fixed": "2.5e2", "r_range": "[50.0:200.0]", "r_bare": "1.0:2.0",
    "r_list": "1.25,2.5,5.0", "r_weight": "{0.0:=0,50.0:=20,[100.0:200.0]:/80}",
    "r_each": "(0.0:=0,[1.0:4.0]:=2,9.0:/1)", "r_single_weight": "[1.0:4.0]:/3",
    "r_inc": "inc:0.25:1.0:0.25", "r_dec": "dec:1.0:0.25:0.25",
    "s_fixed": "hello world", "s_list": "red,blue,green", "s_bracket": "[50:200]",
    "e_fixed": "MODE1", "e_list": "mode0,MODE1,MODE2", "w_rand": "rand",
    "w_fixed": "256'h123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0",
}
CONTAINERS = {
    "array.size": "5", "array.each": "[10:90]", "array.unique": "1", "array.sort": "asc",
    "sequence_values": "seq:2:8:2", "permutation": "perm:10:13",
    "queue.size": "4", "queue.each": "[10:20]", "queue.sort": "desc",
    "reals": "[1.0:2.0],2.5,3.0",
    "cfg.length": "[64:128]", "cfg.rate": "[2.0:3.0]",
    "cfg.label": "red,blue", "cfg.mode": "MODE1,MODE2",
}
BAD = [
    ("int", "[200:50]"), ("int", "{1:=0,2:=0}"),
    ("int", "{1:=-1,2:=1}"), ("int", "inc:1:9:0"),
    ("int", "seq:1:9"), ("int", "33'h1FFFFFFFF"),
    ("real", "[2.0:1.0]"), ("real", "{1.0:=0,2.0:=0}"),
    ("real", "{1.0:=-1,2.0:=1}"), ("real", "inc:1.0:2.0:0.0"),
    ("real", "1.5junk"), ("real", "rand"),
]


def run(name, args, expect_ok=True):
    """执行一次仿真并保留完整日志；负例还必须包含实际宏调用处的诊断。"""
    result = subprocess.run(["./simv_set_param_expressions", "-no_save", "-exitstatus",
                             "+ntb_random_seed=12345", *args],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=90)
    pathlib.Path(f"set_param_{name}.log").write_text(result.stdout)
    if expect_ok:
        assert result.returncode == 0 and "SET_PARAM_EXPRESSIONS_PASS" in result.stdout, name
    else:
        assert result.returncode != 0, name
        assert "SET_PARAM_EXPRESSIONS_PASS" not in result.stdout, name
        assert "SET_PARAM_UNEXPECTED_CONTINUE" not in result.stdout, name
        assert "parameter='+probe.bad.value'" in result.stdout, name
        assert "test_set_param_expressions.sv(" in result.stdout, name
    return result.stdout


def main():
    """先比较全部正例轨迹，再逐来源执行同一负例，最后报告完成数量。"""
    args = [f"+probe.{name}.value={value}" for name, value in CASES.items()]
    args += [f"+probe.{name}={value}" for name, value in CONTAINERS.items()]
    args += ["+priority.value=19"]
    traces = []
    for source in ("plusarg", "override"):
        output = run(source, args + (["+USE_OVERRIDE"] if source == "override" else []))
        trace = [line for line in output.splitlines() if line.startswith("SET_PARAM_TRACE ")]
        assert len(trace) == len(CASES) * 64 + 1, (source, len(trace))
        traces.append(trace)
    assert traces[0] == traces[1], "plusarg/override traces differ"
    for index, (kind, expression) in enumerate(BAD):
        for source in ("plusarg", "override"):
            run(f"bad_{index}_{source}", [f"+NEGATIVE_KIND={kind}", f"+probe.bad.value={expression}"]
                + (["+USE_OVERRIDE"] if source == "override" else []), expect_ok=False)
    print(f"SET_PARAM_MATRIX_PASS scalar_cases={len(CASES)} samples_each=64 negative_runs={len(BAD)*2}")


if __name__ == "__main__":
    main()
