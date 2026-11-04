"""Install real tools into empty data/cache directories, then exercise LSP and DAP."""

import json
import os
import subprocess
import tempfile
from pathlib import Path

from tool_protocols import Protocol

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="toolchain-protocols-") as directory:
        temp = Path(directory)
        env = dict(
            os.environ,
            TOOLCHAIN_PROTOCOL_TMP=directory,
            XDG_DATA_HOME=directory + "/data",
            XDG_CACHE_HOME=directory + "/cache",
            XDG_STATE_HOME=directory + "/state",
            NVIM_LOG_FILE=directory + "/nvim.log",
            NVIM_DEV_PLUGIN_ROOT=directory + "/missing-plugins",
            PYTHONPATH="",
            PYTHONNOUSERSITE="1",
            PIP_DISABLE_PIP_VERSION_CHECK="1",
            PATH=":".join(
                p for p in os.environ["PATH"].split(":") if "/mason/" not in p
            ),
        )
        completed = subprocess.run(
            [
                env.get("NVIM_BIN", "nvim"),
                "--headless",
                "-n",
                "-u",
                "NONE",
                "-i",
                "NONE",
                "--noplugin",
                "-l",
                str(ROOT / "tests/clean_protocols.lua"),
            ],
            check=False,
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=1200,
        )
        assert completed.returncode == 0, completed.stdout + completed.stderr
        print(completed.stdout.strip(), flush=True)
        paths = json.loads((temp / "paths.json").read_text())
        for path in paths.values():
            assert str(temp / "frozen") in path and "/mason/" not in path, path
        project = temp / "project"
        project.mkdir()
        server = Protocol([paths["lua"]])
        try:
            server.send(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "processId": os.getpid(),
                        "rootUri": project.as_uri(),
                        "capabilities": {},
                    },
                }
            )
            result = server.until(lambda m: m.get("id") == 1)
            assert result.get("result", {}).get("capabilities"), result
            server.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
            server.send(
                {"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": None}
            )
            server.until(lambda m: m.get("id") == 2)
            server.send({"jsonrpc": "2.0", "method": "exit", "params": None})
            print("PASS cold LuaLS initialize/shutdown", flush=True)
        finally:
            server.close()
        source = project / "main.py"
        source.write_text("value = 41\nprint(value + 1)\n")
        adapter = Protocol([paths["python"], "-m", "debugpy.adapter"])
        try:

            def request(seq, command, arguments):
                adapter.send(
                    {
                        "seq": seq,
                        "type": "request",
                        "command": command,
                        "arguments": arguments,
                    }
                )

            request(
                1,
                "initialize",
                {
                    "clientID": "toolchain-cold-test",
                    "adapterID": "python",
                    "linesStartAt1": True,
                    "columnsStartAt1": True,
                    "pathFormat": "path",
                },
            )
            result = adapter.until(
                lambda m: m.get("type") == "response" and m.get("request_seq") == 1
            )
            assert result.get("success"), result
            request(
                2,
                "launch",
                {
                    "name": "cold-debugpy",
                    "type": "python",
                    "request": "launch",
                    "program": str(source),
                    "python": [paths["python"]],
                    "console": "internalConsole",
                    "stopOnEntry": True,
                    "justMyCode": True,
                },
            )
            adapter.until(lambda m: m.get("event") == "initialized")
            request(3, "configurationDone", {})
            stopped = adapter.until(lambda m: m.get("event") == "stopped")
            assert stopped.get("body", {}).get("threadId"), stopped
            request(4, "disconnect", {"terminateDebuggee": True})
            reply = adapter.until(
                lambda m: m.get("type") == "response" and m.get("request_seq") == 4
            )
            assert reply.get("success"), reply
            print("PASS cold debugpy launch/stop/disconnect", flush=True)
        finally:
            adapter.close()


if __name__ == "__main__":
    main()
