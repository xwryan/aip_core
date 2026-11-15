#!/usr/bin/env python3
"""tests/socket：显式监听的真实宿主资源、协议及跨进程快照回归驱动。

依赖 Linux /proc、已编译 simv 和现有 Python 协议测试；本进程拥有子进程与
SOCKET_WORK 内日志/gate，失败先终止自己创建的进程组，不访问其他仿真资源。
"""
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ERROR_PATTERN = r"C_BRIDGE_LIFECYCLE_FAIL|^Error-|^Fatal[-:]|^UVM_(ERROR|FATAL) .*@"


def listening_sockets(pid):
    """按 fd inode 关联进程实际 TCP LISTEN socket；不把 license 客户端连接误当监听。"""
    inodes = set()
    for fd in Path(f"/proc/{pid}/fd").iterdir():
        try:
            target = os.readlink(fd)
        except FileNotFoundError:
            continue
        match = re.fullmatch(r"socket:\[(\d+)\]", target)
        if match:
            inodes.add(match.group(1))
    listeners = []
    for kind in ("tcp", "tcp6"):
        for row in Path(f"/proc/{pid}/net/{kind}").read_text().splitlines()[1:]:
            fields = row.split()
            if fields[3] == "0A" and fields[9] in inodes:
                listeners.append((fields[9], int(fields[1].split(":")[1], 16)))
    return listeners


def wait_marker(process, log, marker, deadline):
    """等待真实行首标记或终止/期限；忽略 UCLI 回显源码，防止未执行语句误判通过。"""
    while True:
        text = log.read_text(errors="replace")
        match = re.search(marker, text, re.MULTILINE)
        if match:
            return match
        if process.poll() is not None:
            raise RuntimeError(f"simulation exited {process.returncode} before {marker}: {log}")
        if time.monotonic() >= deadline:
            raise TimeoutError(f"simulation timed out before {marker}: {log}")
        time.sleep(0.05)


def phase(root, work, name, attempt):
    """单阶段先验证真实 fd 再放行 Tcl；普通/恢复阶段复用完整客户端协议和错误隔离断言。"""
    gate = work / "inspect.done"
    gate.unlink(missing_ok=True)
    log = work / f"{name}.attempt{attempt}.log"
    deadline = time.monotonic() + float(os.environ.get("SOCKET_TIMEOUT", "120"))
    with log.open("w") as output:
        process = subprocess.Popen(
            [str(work / "simv"), "-ucli", "-do", str(root / f"tests/tcl/c_bridge_{name}.tcl")],
            cwd=work, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            wait_marker(process, log, r"^C_BRIDGE_HOST_INSPECT_READY$", deadline)
            listeners = listening_sockets(process.pid)
            if listeners:
                raise AssertionError(f"default bridge unexpectedly owns LISTEN sockets: {listeners}")
            print(f"C_BRIDGE_OS_CLOSED phase={name} pid={process.pid}", flush=True)
            gate.write_text("inspected\n")
            if name != "generate":
                match = wait_marker(
                    process, log,
                    r"^C_BRIDGE_EXPLICIT_LISTEN OK: Listening on 127\.0\.0\.1:(\d+), fd=(\d+), auth_key=(\d+)$",
                    deadline,
                )
                port, fd, key = map(int, match.groups())
                listeners = listening_sockets(process.pid)
                if len(listeners) != 1 or listeners[0][1] != port:
                    raise AssertionError(f"explicit listen owns wrong sockets: {listeners}, port={port}")
                if os.readlink(f"/proc/{process.pid}/fd/{fd}") != f"socket:[{listeners[0][0]}]":
                    raise AssertionError("reported listener fd does not own actual TCP socket")
                print(f"C_BRIDGE_OS_LISTEN phase={name} port={port} fd={fd}", flush=True)
                subprocess.run(
                    [sys.executable, str(root / "tests/socket/test_c_bridge_socket.py"), "127.0.0.1", str(port), str(key)],
                    check=True, timeout=45,
                )
                wait_marker(process, log, r"^C_BRIDGE_SOCKET_SIM_CONTINUED$", deadline)
                wait_marker(process, log, r"^C_BRIDGE_SOCKET_WAIT_PASS background=checked legacy=preserved$", deadline)
            else:
                wait_marker(process, log, r"^C_BRIDGE_GENERATE_DONE$", deadline)
            process.wait(timeout=max(0.1, deadline - time.monotonic()))
            text = log.read_text(errors="replace")
            if process.returncode != 0 or re.search(ERROR_PATTERN, text, re.MULTILINE):
                raise AssertionError(f"simulation failed: {log}")
            if name != "immediate" and not re.search(r"^C_BRIDGE_ARGUMENTS_REJECTED$", text, re.MULTILINE):
                raise AssertionError(f"public command argument rejection was not tested: {log}")
            if name in ("ordinary", "generate") and "C_BRIDGE_FAILED_START_CLEAN" not in text:
                raise AssertionError(f"failed-start cleanup was not tested: {log}")
            (work / f"{name}.log").write_text(text)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()


def main():
    """两种 loader 都先检查握手后立即监听；随后覆盖文件/失败或跨进程恢复，只重试保存超时。"""
    root = Path(os.environ["AIP_CORE"])
    work = Path(os.environ["SOCKET_WORK"])
    (work / "socket_commands.txt").write_text("socket_file_mark\n")
    names = ("immediate", "ordinary") if sys.argv[1] == "ordinary" else ("immediate", "generate", "restore")
    for name in names:
        for attempt in range(1, 4):
            try:
                phase(root, work, name, attempt)
                break
            except (TimeoutError, subprocess.TimeoutExpired):
                text = (work / f"{name}.attempt{attempt}.log").read_text(errors="replace")
                if (name != "generate" or attempt == 3
                        or not re.search(r"^C_BRIDGE_SAVE_BEGIN$", text, re.MULTILINE)
                        or re.search(ERROR_PATTERN, text, re.MULTILINE)):
                    raise
                print(f"C_BRIDGE_RETRY phase={name} attempt={attempt}", flush=True)
    print(f"C_BRIDGE_EXPLICIT_PASS mode={sys.argv[1]}", flush=True)


if __name__ == "__main__":
    main()
