#!/usr/bin/env python3
"""tests/socket：真实 TCP 命令回复及逐命令等待隔离验证。

依赖标准库 socket 与 test_c_bridge_socket.sv；本脚本拥有一个客户端连接，
业务 worker 由 SV flag 门控，避免依赖网络到达速度和短仿真延迟的竞速。
"""
import socket
import sys
import time


def request(sock, command):
    """发送一条命令并完整接收换行回复；连接中断或接收超时立即终止测试。"""
    sock.sendall((command + "\n").encode("ascii"))
    data = bytearray()
    while not data.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("bridge closed connection before replying")
        data.extend(chunk)
    reply = data.decode("utf-8").strip()
    print(f"{command} => {reply}")
    return reply


def main():
    """连接真实 bridge，验证隔离后再发最终 ping；只有全部断言通过才打印 PASS。"""
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 19091
    auth_key = sys.argv[3] if len(sys.argv) > 3 else None
    if not auth_key:
        raise RuntimeError("test requires the simulation auth key as argument 3")
    deadline = time.monotonic() + 30
    while True:
        try:
            sock = socket.create_connection((host, port), timeout=5)
            break
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)

    with sock:
        sock.settimeout(5)
        unauthenticated = request(sock, "socket_value")
        if not unauthenticated.startswith("ERROR: AUTH_REQUIRED"):
            raise AssertionError(f"unauthenticated command was not rejected: {unauthenticated}")
        authenticated = request(sock, f"auth {auth_key}")
        if authenticated != "OK: AUTHENTICATED":
            raise AssertionError(f"authentication failed: {authenticated}")
        value = request(sock, "socket_value")
        started = request(sock, "socket_wait_task token=original wait=0")
        if started != "OK: STARTED: socket_wait_task":
            raise AssertionError(f"background task did not return STARTED: {started}")
        pending = request(sock, "socket_wait_control op=background_state")
        if pending != "OK: started=1 finished=0":
            raise AssertionError(f"task completed without explicit gate release: {pending}")
        foreground = request(sock, "socket_wait_front")
        if foreground != "OK: FOREGROUND_DONE":
            raise AssertionError(f"next default command lost its real result: {foreground}")

        legacy_start = request(sock, "socket_legacy text=preserve wait=0")
        if legacy_start != "OK: STARTED: socket_legacy":
            raise AssertionError(f"legacy background launch lost its result: {legacy_start}")
        legacy_started = request(sock, "socket_wait_control op=legacy_started")
        if legacy_started != "OK: LEGACY_STARTED":
            raise AssertionError(f"legacy startup reply used stale global result: {legacy_started}")
        during_legacy = request(sock, "socket_value")
        if during_legacy != "OK: value=0x1234":
            raise AssertionError(f"ordinary command used pending legacy result: {during_legacy}")
        legacy_done = request(sock, "socket_wait_control op=legacy_finish")
        if legacy_done != "OK: legacy_status=17 legacy_result=LEGACY:preserve":
            raise AssertionError(f"other command ACK corrupted legacy result: {legacy_done}")
        print("C_BRIDGE_SOCKET_WAIT_CLIENT_PASS")

        cseq = request(sock, "socket_cseq count=3")
        unknown = request(sock, "does_not_exist")
        nested_unknown = request(sock, "fork does_not_exist join")
        valid_after = request(sock, "socket_ping")

    if value != "OK: value=0x1234":
        raise AssertionError(f"value command did not return its result: {value}")
    if cseq != "OK: socket_cseq count=3":
        raise AssertionError(f"cseq command did not return summary: {cseq}")
    if not unknown.startswith("ERROR:"):
        raise AssertionError(f"unknown command did not return ERROR: {unknown}")
    if not nested_unknown.startswith("ERROR:"):
        raise AssertionError(
            f"unknown command inside fork did not return ERROR: {nested_unknown}"
        )
    if not valid_after.startswith("OK:"):
        raise AssertionError(f"bridge did not continue after unknown command: {valid_after}")
    print("C_BRIDGE_SOCKET_PASS")


if __name__ == "__main__":
    main()
