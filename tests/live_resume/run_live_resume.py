#!/usr/bin/env python3
"""tests/live_resume：真实 VCS/UCLI 的暂停、续跑和旧脚本兼容门禁。

依赖 VCS、GNU make、Python pexpect；在配置好 license 的仿真主机执行。
本 runner 只拥有专属构建目录、PTY 子进程、逐用例目录和日志，不删除源码。
默认重新构建真实 dist Tcl .so，并以普通 -do/source 加载公开入口；不注入、
重写或替换任何生产 proc。超时、意外 EOF、漏 PASS 和非零 UVM 错误均失败。
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

import pexpect


MODES = ("baseline", "watch", "ack", "notify", "manual", "legacy")
LOADERS = ("so", "source")
FAILURE = r"(?:^|\r?\n)[ \t]*(?:pause%[ \t]*)?AIP_LIVE_FAIL[^\r\n]*"


def checked_build(command: list[str], cwd: Path, log: Path) -> None:
    """执行独立构建并记录完整证据；超时或编译失败不进入仿真阶段。"""
    with log.open("w", encoding="utf-8") as stream:
        result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                timeout=300, check=False)
    if result.returncode:
        raise RuntimeError(f"build failed rc={result.returncode}: {log}")


def build(root: Path, directory: Path) -> Path:
    """重新内嵌生产 Tcl 源码，并复用真实 seq/driver 夹具构建独立 simv。"""
    checked_build(["make", "-B", "-C", str(root / "dist"), "tcl"], root,
                  directory / "so_build.log")
    include_dirs = [root, root / "src/sv", root / "src/sv/core", root / "src/sv/bridge",
                    root / "src/sv/util", root / "src/sv/plugin", root / "src/sv/cpu_mem"]
    binary = directory / "simv_live_resume"
    command = ["vcs", "-full64", "-sverilog", "-ntb_opts", "uvm", "-timescale=1ns/1ps",
               "-lca", "-debug_access+r+w+f"]
    command.extend(f"+incdir+{path}" for path in include_dirs)
    command.extend(["-top", "test_cmd_wait", "-top", "aip_live_resume_fixture",
                    "-o", str(binary), f"-Mdir={directory / 'csrc_live_resume'}",
                    str(root / "tests/sv/test_cmd_wait.sv"),
                    str(root / "tests/sv/test_live_resume_fixture.sv")])
    checked_build(command, directory, directory / "vcs_build.log")
    return binary


def expect(child: pexpect.spawn, pattern: str, *, timeout: float = 60) -> None:
    """等真实输出而非输入回显；测试断言失败、EOF 和墙钟超时都立即报错。"""
    matched = child.expect([pattern, FAILURE, pexpect.EOF, pexpect.TIMEOUT], timeout=timeout)
    if matched:
        raise AssertionError(f"wanted {pattern!r}, event={matched}, tail={child.before[-1200:]!r}")


def debug_command(child: pexpect.spawn, command: str, marker: str) -> None:
    """在 native pause 内执行只读/受控调试命令，要求确认标记和下一次提示符。"""
    child.sendline(command)
    expect(child, rf"(?:^|\r?\n)[ \t]*{re.escape(marker)}\r?\n")
    expect(child, r"pause%")


def check_pause(child: pexpect.spawn, hit: int, *, pending: bool = False,
                ack: bool = False, manual: bool = False) -> None:
    """证明暂停确实保栈/冻结，并验证可见调试、生命周期守卫和请求字节未变。"""
    # 不预填 resume；真实停留期间后续脚本、driver report 都不能偷偷完成。
    event = child.expect([r"AIP_LIVE_PASS", r"AIP_LIVE_MANUAL_AFTER",
                          r"CMD_WAIT_SV_PASS", pexpect.TIMEOUT], timeout=0.15)
    if event != 3:
        raise AssertionError("script advanced before native resume")
    debug_command(child,
                  f'set ::live_saved_snapshot [live_snapshot]; '
                  f'live_check pause_depth [expr {{[dict get [aip_sim_status] depth] > 0}}]; '
                  f'puts "AIP_LIVE_SNAPSHOT_SAVED hit={hit}"',
                  f"AIP_LIVE_SNAPSHOT_SAVED hit={hit}")
    if pending or ack:
        assertion = "==" if ack else "!="
        debug_command(child,
                      'live_check pending_id [expr {[dict get [aip_sim_status] pending_id] == 1}]; '
                      'live_check request_id [expr {[aip_parse_int [get aip_core_pkg::__tcl_cmd_id]] == 1}]; '
                      f'live_check ack_relation [expr {{[get aip_core_pkg::__tcl_result_id] {assertion} '
                      '[get aip_core_pkg::__tcl_cmd_id]}]; '
                      'live_check original_trigger [expr {[aip_parse_int [get aip_core_pkg::__tcl_cmd_trigger]] == 1}]; '
                      'puts "AIP_LIVE_PENDING_CONFIRMED"', "AIP_LIVE_PENDING_CONFIRMED")
    if manual:
        debug_command(child,
                      'live_check manual_midrun [expr {[live_time_fs] > 0 && [live_time_fs] < 500000000000}]; '
                      'puts "AIP_LIVE_MANUAL_MIDRUN"', "AIP_LIVE_MANUAL_MIDRUN")

    # get/gv/fv 不得被 ACK 的 redirect /dev/null 吞掉；实际值必须已经变化。
    child.sendline("get aip_live_resume_fixture.debug_flag")
    # PTY 关闭输入回显后，VCS 会把短 get 返回值直接接在 pause% 后面。
    expect(child, r"'b[01]\r?\n")
    expect(child, r"pause%")
    debug_command(child,
                  'fv aip_live_resume_fixture.debug_flag 1 -mode force; '
                  'gv aip_live_resume_fixture.debug_flag; '
                  'live_check debug_force [expr {[aip_parse_int [get aip_live_resume_fixture.debug_flag]] == 1}]; '
                  'puts "AIP_LIVE_DEBUG_VISIBLE"', "AIP_LIVE_DEBUG_VISIBLE")
    child.sendline("error AIP_LIVE_DEBUG_INTENTIONAL")
    expect(child, r"(?:^|\r?\n)[ \t]*(?:pause%[ \t]*)?AIP_LIVE_DEBUG_INTENTIONAL\r?\n")
    expect(child, r"pause%")

    # 只检查仍不允许的全局生命周期操作（普通命令/有界推进由暂停注入门禁覆盖）。
    guards = {
        "checkpoint": "aip_checkpoint forbidden_pause",
        "restore": "aip_restore forbidden_pause",
    }
    for label, command in guards.items():
        debug_command(child, f"live_expect_busy {label} {{{command}}}",
                      f"AIP_LIVE_BUSY_PASS {label}")
    debug_command(child,
                  'live_repeat_init; '
                  'live_check frozen_request [expr {[live_snapshot] eq $::live_saved_snapshot}]; '
                  'puts "AIP_LIVE_REQUEST_PRESERVED"', "AIP_LIVE_REQUEST_PRESERVED")


def validate_log(log: Path, loader: str, mode: str) -> None:
    """独立检查完整日志，拒绝只碰巧打印 PASS、重复完成或隐藏 UVM 失败。"""
    text = log.read_text(encoding="utf-8", errors="replace")
    plain = re.sub(r"\x1b\[[0-9;]*m", "", text).replace("\r", "")
    had_native_pause = re.search(r"(?m)^pause%", plain) is not None
    # 无输入回显时，resume 后首条业务输出也可能紧接原 pause% 提示符。
    # 只去行首真实提示符，不把 Tcl 命令中的 PASS 字符串误算作执行结果。
    plain = re.sub(r"(?m)^(?:pause|ucli)%[ \t]*", "", plain)
    expected_driver = 1 if mode in ("baseline", "watch", "ack") else 0
    assert len(re.findall(rf"^AIP_LIVE_PASS loader={loader} mode={mode} checks=\d+$", plain, re.M)) == 1, \
        f"missing or repeated Tcl PASS: {log}"
    assert len(re.findall(rf"^CMD_WAIT_SV_PASS driver_count={expected_driver}$", plain, re.M)) == 1, \
        f"missing, repeated or incorrect SV driver PASS: {log}"
    assert not re.search(r"^AIP_LIVE_FAIL|^UVM_(ERROR|FATAL)\s+.*@|^Fatal:|^Error-", plain, re.M), \
        f"simulation failure in transcript: {log}"
    for severity in ("WARNING", "ERROR", "FATAL"):
        assert len(re.findall(rf"^UVM_{severity}\s*:\s*0\s*$", plain, re.M)) == 1, \
            f"missing or nonzero UVM {severity} summary: {log}"
    notifications = re.findall(r"^\[AIP_WATCH\].*$", plain, re.M)
    expected_notifications = {"watch": 3, "ack": 4, "notify": 1}.get(mode, 0)
    assert len(notifications) == expected_notifications, notifications
    if mode == "notify":
        assert "path=aip_live_resume_fixture.first" in notifications[0]
        assert not had_native_pause, f"notification-only watch unexpectedly paused: {log}"
    if mode == "manual":
        assert len(re.findall(r"^AIP_LIVE_MANUAL_AFTER iteration=[01] ", plain, re.M)) == 2


def run_case(root: Path, directory: Path, binary: Path, loader: str, mode: str) -> Path:
    """每例独占 PTY/临时 legacy 文件；任何异常只终止本 runner 创建的进程。"""
    work = Path(tempfile.mkdtemp(prefix=f"{loader}-{mode}.", dir=directory))
    for kind in ("source", "self"):
        name = f"live_resume_legacy_{kind}_case.tcl"
        shutil.copy2(root / "tests/tcl" / name, work / name)
    environment = dict(os.environ, AIP_CORE=str(root), AIP_LIVE_WORK=str(work),
                       AIP_LIVE_LOADER=loader, AIP_LIVE_MODE=mode)
    arguments = ["-ucli", "-do", str(root / "tests/tcl/live_resume_entry.tcl"),
                 "-no_save", "-exitstatus", "+UVM_NO_RELNOTES"]
    if mode == "manual":
        arguments.append("+AIP_LIVE_MANUAL")
    log = work / "transcript.log"
    with log.open("w", encoding="utf-8") as stream:
        child = pexpect.spawn(str(binary), arguments, cwd=str(work), env=environment,
                              encoding="utf-8", codec_errors="replace", timeout=60, echo=False)
        child.logfile_read = stream
        try:
            if mode in ("watch", "ack"):
                hits = 4 if mode == "ack" else 3
                for hit in range(1, hits + 1):
                    expect(child, r"pause%")
                    check_pause(child, hit, pending=(hit == 3), ack=(hit == 4))
                    child.sendline("resume")
            elif mode == "manual":
                expect(child, r"(?:^|\r?\n)AIP_LIVE_MANUAL_BEFORE iteration=0[^\r\n]*\r?\n")
                if child.expect([r"AIP_LIVE_MANUAL_AFTER iteration=0", pexpect.TIMEOUT], timeout=0.05) != 1:
                    raise AssertionError("manual run finished before Ctrl+C window")
                child.sendintr()
                expect(child, r"Pause in command '[^\r\n]*-keep[^\r\n]*'")
                expect(child, r"pause%")
                check_pause(child, 1, manual=True)
                child.sendline("resume")

            expect(child, rf"(?:^|\r?\n)AIP_LIVE_PASS loader={loader} mode={mode} checks=\d+\r?\n", timeout=120)
            expected_driver = 1 if mode in ("baseline", "watch", "ack") else 0
            expect(child, rf"(?:^|\r?\n)CMD_WAIT_SV_PASS driver_count={expected_driver}\r?\n")
            child.expect(pexpect.EOF, timeout=30)
            child.close()
            if child.exitstatus != 0 or child.signalstatus is not None:
                raise AssertionError(f"simv exit={child.exitstatus} signal={child.signalstatus}")
        finally:
            if child.isalive():
                child.terminate(force=True)
    validate_log(log, loader, mode)
    print(f"AIP_LIVE_PTY_PASS loader={loader} mode={mode} log={log}", flush=True)
    return log


def main() -> int:
    """解析明确测试范围；默认完整双入口矩阵，--skip-build 仅供同一快照复跑。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--loaders", default=",".join(LOADERS))
    parser.add_argument("--modes", default=",".join(MODES))
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    directory = args.build_dir.resolve() if args.build_dir else Path(tempfile.mkdtemp(prefix="aip-live-resume."))
    directory.mkdir(parents=True, exist_ok=True)
    loaders = args.loaders.split(",")
    modes = args.modes.split(",")
    if not set(loaders) <= set(LOADERS) or not set(modes) <= set(MODES):
        parser.error("unknown loader or mode")
    print(f"AIP_LIVE_BUILD_DIR {directory}", flush=True)
    binary = directory / "simv_live_resume"
    if not args.skip_build:
        binary = build(root, directory)
    if not binary.is_file():
        raise FileNotFoundError(binary)
    for loader in loaders:
        for mode in modes:
            run_case(root, directory, binary, loader, mode)
    print(f"AIP_LIVE_RESUME_PASS cases={len(loaders) * len(modes)} build={directory}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, OSError, RuntimeError, subprocess.SubprocessError, pexpect.ExceptionPexpect) as error:
        print(f"AIP_LIVE_RUNNER_FAIL {type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(1)
