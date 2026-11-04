#!/usr/bin/env python3
"""Exercise the task window with real Neovim terminal input."""
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time

root = Path(__file__).resolve().parents[1]
actions = {
    "plan": b"i",
    "installed": b"j\r",
    "detail": b"r",
    "retried": b"\rj\r",
    "optional_detail": b"r",
    "narrow": b"q",
    "reopened": b"q",
}
with tempfile.TemporaryDirectory(prefix="toolchain-tui-") as directory:
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    env = dict(os.environ, TERM="xterm-256color", TOOLCHAIN_TUI_DIR=directory,
               NVIM_LOG_FILE=directory + "/nvim.log")
    process = subprocess.Popen(
        [os.environ.get("NVIM_BIN") or shutil.which("nvim"), "-u", "NONE", "-n", "-i", "NONE",
         "--noplugin", "-c", "lua dofile('tests/tui.lua')"],
        cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
    )
    os.close(slave)
    handled, output = set(), bytearray()
    deadline = time.monotonic() + 15
    try:
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.02)[0]:
                try:
                    output.extend(os.read(master, 65536))
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
            stage_file = Path(directory, "stage")
            stage = stage_file.read_text().strip() if stage_file.exists() else ""
            if stage in handled:
                continue
            if stage == "optional_retried":
                os.write(master, b"\r")
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 20, 40, 0, 0))
                os.kill(process.pid, signal.SIGWINCH)
                handled.add(stage)
            elif stage in actions:
                os.write(master, actions[stage])
                handled.add(stage)
        if process.poll() is None:
            process.kill()
        process.wait()
        result_file = Path(directory, "result")
        result = result_file.read_text() if result_file.exists() else "No result; stages: " + repr(handled)
        assert process.returncode == 0 and result.startswith("PASS"), result + "\n" + output.decode(errors="replace")[-5000:]
        print(result.strip())
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        os.close(master)
