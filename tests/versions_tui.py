#!/usr/bin/env python3
"""Drive version management commands through a real terminal."""
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="toolchain-versions-tui-") as directory:
    temp = Path(directory)
    env = dict(os.environ, TERM="xterm-256color", TOOLCHAIN_VERSIONS_TMP=directory,
               XDG_DATA_HOME=directory + "/data", XDG_STATE_HOME=directory + "/state",
               XDG_CACHE_HOME=directory + "/cache", NVIM_LOG_FILE=directory + "/nvim.log")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 140, 0, 0))
    process = subprocess.Popen([env.get("NVIM_BIN", "nvim"), "-n", "-i", "NONE", "-u", "NONE",
        "-c", "lua dofile('tests/versions_tui.lua')"], cwd=root, env=env,
        stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    actions = {"versions": b":ToolchainVersions tool:fixture\r", "close_versions": b"q",
               "prune": b":ToolchainPrune tool:fixture\r", "close_prune": b"q"}
    seen, output = set(), bytearray()
    deadline = time.monotonic() + 30
    try:
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], .02)[0]:
                try:
                    output.extend(os.read(master, 65536))
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
            state = temp / "stage"
            stage = state.read_text().strip() if state.exists() else ""
            if stage and stage not in seen:
                action = actions.get(stage)
                if stage == "rollback":
                    action = b":ToolchainRollback tool:fixture " + (temp / "rollback-id").read_bytes().strip() + b"\r"
                if action:
                    os.write(master, action)
                    seen.add(stage)
        if process.poll() is None:
            process.kill()
        process.wait()
        result = temp / "result"
        report = result.read_text() if result.exists() else "No version management result"
        assert process.returncode == 0 and report.startswith("PASS"), report + "\n" + output.decode(errors="replace")[-5000:]
        print(report.strip())
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        os.close(master)
