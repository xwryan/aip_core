#!/usr/bin/env python3
"""tests/paused_injection：正式暂停命令队列的source/.so真实VCS门禁。

必须在已配置 VCS 的参考服务器环境运行；借用live_resume的纯构建函数重新构建真实SV和库，
不使用临时原型。runner拥有独立目录、PTY子进程及日志；异常只终止自己
创建的进程。真实Tcl/SV双PASS、计数与UVM汇总共同决定结果。
"""

from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import re
import sys
import tempfile

import pexpect


FAILURE = r"(?:^|\r?\n)[ \t]*(?:pause%[ \t]*)?AIP_INJECTION_FAIL[^\r\n]*"


def expect(child: pexpect.spawn, pattern: str, timeout: float = 60) -> None:
    """只认可执行输出；测试失败、EOF和墙钟超时立即带最后输出报错。"""
    result = child.expect([pattern, FAILURE, pexpect.EOF, pexpect.TIMEOUT], timeout=timeout)
    if result:
        raise AssertionError(f"wanted={pattern!r} event={result} tail={child.before[-1600:]!r}")


def paused(child: pexpect.spawn, command: str, marker: str) -> None:
    """在同一原生pause执行步骤，确认真实标记后必须再次回到pause。"""
    child.sendline(command)
    expect(child, rf"(?:^|\r?\n)(?:pause%[ \t]*)?{re.escape(marker)}\r?\n")
    expect(child, r"pause%")


def run_case(root: Path, directory: Path, binary: Path, loader: str, mode: str) -> None:
    """独立PTY保存原栈；manual组真实SIGINT，watch组由真实HDL值触发。"""
    work = Path(tempfile.mkdtemp(prefix=f"{loader}-{mode}.", dir=directory))
    environment = dict(os.environ, AIP_CORE=str(root), AIP_INJECTION_LOADER=loader,
                       AIP_INJECTION_MODE=mode)
    arguments = ["-ucli", "-do", str(root / "tests/paused_injection/entry.tcl"),
                 "-no_save", "-exitstatus", "+UVM_NO_RELNOTES"]
    if mode == "manual":
        arguments.append("+AIP_LIVE_MANUAL")
    log = work / "transcript.log"
    with log.open("w", encoding="utf-8") as stream:
        child = pexpect.spawn(str(binary), arguments, cwd=str(work), env=environment,
                              encoding="utf-8", codec_errors="replace", echo=False, timeout=60)
        child.logfile_read = stream
        try:
            if mode == "manual":
                expect(child, r"(?:^|\r?\n)AIP_INJECTION_MANUAL_BEFORE\r?\n")
                if child.expect([r"AIP_INJECTION_TCL_PASS", pexpect.TIMEOUT], timeout=.05) != 1:
                    raise AssertionError("manual run finished before SIGINT window")
                child.sendintr()
            expect(child, r"pause%")
            for command, marker in (
                ("pi_pause_begin", "AIP_INJECTION_PAUSED"),
                ("pi_foreign", "AIP_INJECTION_FOREIGN_PASS"),
                ("pi_queue", "AIP_INJECTION_FIFO_QUEUED"),
                ("pi_finish_jobs", "AIP_INJECTION_JOBS_DONE"),
            ):
                paused(child, command, marker)
            if child.expect([r"AIP_INJECTION_TCL_PASS", r"CMD_WAIT_SV_PASS", pexpect.TIMEOUT], timeout=.15) != 2:
                raise AssertionError("outer script advanced before native resume")
            child.sendline("resume")
            expect(child, rf"(?:^|\r?\n)(?:pause%[ \t]*)?AIP_INJECTION_TCL_PASS loader={loader} mode={mode} checks=\d+\r?\n", 120)
            expect(child, r"(?:^|\r?\n)CMD_WAIT_SV_PASS driver_count=6\r?\n")
            child.expect(pexpect.EOF, timeout=30)
            child.close()
            if child.exitstatus != 0 or child.signalstatus is not None:
                raise AssertionError(f"simv exit={child.exitstatus} signal={child.signalstatus}")
        finally:
            if child.isalive():
                child.terminate(force=True)
    plain = re.sub(r"\x1b\[[0-9;]*m", "", log.read_text()).replace("\r", "")
    plain = re.sub(r"(?m)^(?:pause|ucli)%[ \t]*", "", plain)
    for pattern in (rf"^AIP_INJECTION_TCL_PASS loader={loader} mode={mode} checks=\d+$",
                    r"^CMD_WAIT_SV_PASS driver_count=6$"):
        assert len(re.findall(pattern, plain, re.M)) == 1, f"missing/repeated runtime PASS: {log}"
    for severity in ("WARNING", "ERROR", "FATAL"):
        assert len(re.findall(rf"^UVM_{severity}\s*:\s*0\s*$", plain, re.M)) == 1, \
            f"nonzero or missing UVM {severity}: {log}"
    assert not re.search(r"^AIP_INJECTION_FAIL|^Fatal:|^Error-", plain, re.M), log
    print(f"AIP_INJECTION_PTY_PASS loader={loader} mode={mode} log={log}", flush=True)


def main() -> int:
    """默认双loader×双暂停来源；skip-build仅供同一已冻结源码快照复跑。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--loaders", default="source,so")
    parser.add_argument("--modes", default="watch,manual")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    directory = args.build_dir.resolve() if args.build_dir else Path(tempfile.mkdtemp(prefix="aip-paused-injection."))
    directory.mkdir(parents=True, exist_ok=True)
    loaders, modes = args.loaders.split(","), args.modes.split(",")
    if not set(loaders) <= {"source", "so"} or not set(modes) <= {"watch", "manual"}:
        parser.error("invalid loader or mode")
    binary = directory / "simv_live_resume"
    if not args.skip_build:
        spec = importlib.util.spec_from_file_location("live_resume_build", root / "tests/live_resume/run_live_resume.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        binary = module.build(root, directory)
    if not binary.is_file():
        raise FileNotFoundError(binary)
    for loader in loaders:
        for mode in modes:
            run_case(root, directory, binary, loader, mode)
    print(f"AIP_PAUSED_INJECTION_PASS cases={len(loaders) * len(modes)} build={directory}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, OSError, RuntimeError, pexpect.ExceptionPexpect) as error:
        print(f"AIP_INJECTION_RUNNER_FAIL {type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(1)
