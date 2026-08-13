#!/usr/bin/env python3
"""在 Linux/macOS PTY 中验证 PSAITerminal 的真实 PSReadLine 交互。"""

from __future__ import annotations

import errno
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time


CONTROL_SEQUENCE = re.compile(
    r"(?:\x1b\][^\x07]*(?:\x07|\x1b\\))|"
    r"(?:\x1b\[[0-?]*[ -/]*[@-~])|"
    r"(?:\x1b[()][0-2A-Z])|"
    r"[\x00-\x08\x0b\x0c\x0e-\x1a]"
)
WINDOW_SIZE = struct.pack("HHHH", 40, 120, 0, 0)


def clean(value: bytes) -> str:
    return CONTROL_SEQUENCE.sub("", value.decode("utf-8", errors="replace"))


class Terminal:
    def __init__(self, pwsh: str, manifest: str, state_root: str) -> None:
        environment = os.environ.copy()
        environment["TERM"] = "xterm-256color"
        environment["PSAI_CONFIG_HOME"] = os.path.join(state_root, "config")
        environment["PSAI_DATA_HOME"] = os.path.join(state_root, "data")
        pid, master = pty.fork()
        if pid == 0:
            try:
                # Runner 的默认 PTY 可能为 0×0；子进程执行前必须设置有效尺寸。
                fcntl.ioctl(0, termios.TIOCSWINSZ, WINDOW_SIZE)
                os.chdir(os.path.dirname(manifest))
                os.execve(pwsh, [pwsh, "-NoLogo", "-NoProfile"], environment)
            except BaseException as exception:  # noqa: BLE001 - exec 失败后只能直接退出子进程
                os.write(2, f"启动 PowerShell 失败：{exception}\n".encode("utf-8", errors="replace"))
                os._exit(127)

        fcntl.ioctl(master, termios.TIOCSWINSZ, WINDOW_SIZE)
        self.master = master
        self.pid = pid
        self.returncode: int | None = None
        self.transcript = bytearray()

    def poll(self) -> int | None:
        if self.returncode is not None:
            return self.returncode
        child, status = os.waitpid(self.pid, os.WNOHANG)
        if child == 0:
            return None
        self.returncode = os.waitstatus_to_exitcode(status)
        return self.returncode

    def wait(self, timeout: float) -> int:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.poll()
            if result is not None:
                return result
            time.sleep(0.05)
        raise TimeoutError("等待 PowerShell 退出超时。")

    def send(self, value: str | bytes) -> None:
        data = value.encode("utf-8") if isinstance(value, str) else value
        os.write(self.master, data)

    def wait_for(self, marker: str, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if marker in clean(self.transcript):
                return
            ready, _, _ = select.select([self.master], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(self.master, 4096)
                except OSError as exception:
                    if exception.errno == errno.EIO:
                        break
                    raise
                if chunk:
                    self.transcript.extend(chunk)
            if self.poll() is not None:
                break
        raise RuntimeError(f"等待终端输出超时：{marker}\n{clean(self.transcript)}")

    def close(self) -> None:
        try:
            if self.poll() is None:
                self.send("exit\r")
                self.wait(10)
        except (OSError, TimeoutError):
            try:
                if self.poll() is None:
                    os.kill(self.pid, signal.SIGKILL)
                self.wait(5)
            except (ChildProcessError, ProcessLookupError, TimeoutError):
                pass
        finally:
            os.close(self.master)


def main() -> int:
    if sys.platform not in {"linux", "darwin"}:
        print("此冒烟测试仅支持 Linux/macOS。", file=sys.stderr)
        return 2
    if len(sys.argv) != 3:
        print("用法：pty_smoke.py <pwsh> <PSAITerminal.psd1>", file=sys.stderr)
        return 2

    pwsh = os.path.abspath(sys.argv[1])
    manifest = os.path.abspath(sys.argv[2])
    if not os.path.isfile(pwsh) or not os.path.isfile(manifest):
        print("pwsh 或模块清单不存在。", file=sys.stderr)
        return 2

    state_root = tempfile.mkdtemp(prefix="PSAITerminal.PTY.")
    terminal: Terminal | None = None
    try:
        terminal = Terminal(pwsh, manifest, state_root)
        terminal.wait_for("PS ", 15)
        escaped_manifest = manifest.replace("'", "''")
        terminal.send(f"Import-Module '{escaped_manifest}' -Force;Write-Output '__PSAI_IMPORTED__'\r")
        terminal.wait_for("__PSAI_IMPORTED__", 20)
        terminal.send(
            "$a=(Get-PSReadLineKeyHandler -Chord F2).Function;"
            "$b=(Get-PSReadLineKeyHandler -Chord F3).Function;"
            "Write-Output ('__PSAI_BINDINGS__'+$a+'|'+$b)\r"
        )
        terminal.wait_for("__PSAI_BINDINGS__PSAIForceAI|PSAIForceShell", 10)

        terminal.send("Write-Output '__PSAI_F3_OK__'")
        terminal.send(b"\x1bOR")
        terminal.wait_for("__PSAI_F3_OK__", 10)

        terminal.send("PSAI_F2_PROBE")
        terminal.send(b"\x1bOQ")
        terminal.wait_for("尚未配置活动模型", 15)

        terminal.send("ai\r")
        terminal.wait_for("6. Diagnostics", 10)
        terminal.send("0\r")
        terminal.send("Write-Output '__PSAI_MENU_EXITED__'\r")
        terminal.wait_for("__PSAI_MENU_EXITED__", 10)

        transcript = clean(terminal.transcript)
        forbidden = (
            "Invoke-PSAI -PendingInvocation",
            "New-AITopLevelHarnessScript",
            "Start-PSAIToolExecution",
            "The term 'if' is not recognized",
            "while ($null -ne",
        )
        if "PSAI_F2_PROBE" not in transcript or ". (Invoke-PSAI)" in transcript or any(
            value in transcript for value in forbidden
        ):
            raise RuntimeError("Unix PTY 没有保留原始输入，或显示了内部调度命令/Harness 源码。\n" + transcript)

        print("Unix PTY 冒烟测试通过：F2/F3 与设置菜单均已验证，原始输入完整保留，内部调度命令未显示。")
        return 0
    except Exception as exception:  # noqa: BLE001 - 测试入口需要输出完整失败原因
        print(str(exception), file=sys.stderr)
        return 1
    finally:
        if terminal is not None:
            terminal.close()
        shutil.rmtree(state_root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
