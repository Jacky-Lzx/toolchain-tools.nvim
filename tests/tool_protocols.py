"""Bounded real LSP/DAP process helpers shared by explicit acceptance tests."""

import json
import os
import queue
import signal
import socket
import subprocess
import threading
import time


def run(args, **kwargs):
    p = subprocess.run(
        args, check=False, capture_output=True, text=True, timeout=120, **kwargs
    )
    assert p.returncode == 0, (args, p.returncode, p.stdout[-2000:], p.stderr[-3000:])
    return p.stdout


class Protocol:
    def __init__(self, command, port=None):
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.messages = queue.Queue()
        self.diagnostics = bytearray()

        def stderr():
            for block in iter(self.process.stderr.readline, b""):
                self.diagnostics.extend(block)

        threading.Thread(target=stderr, daemon=True).start()
        self.sock = None
        if port:
            deadline = time.monotonic() + 30
            while True:
                try:
                    self.sock = socket.create_connection(("127.0.0.1", port), timeout=1)
                    self.sock.settimeout(None)
                    break
                except OSError:
                    if time.monotonic() > deadline:
                        raise
                    time.sleep(0.05)
            self.input = self.sock.makefile("wb", buffering=0)
            self.output = self.sock.makefile("rb")
        else:
            self.input, self.output = self.process.stdin, self.process.stdout

        def reader():
            try:
                while True:
                    length = None
                    while True:
                        line = self.output.readline()
                        if not line:
                            return
                        if line in (b"\r\n", b"\n"):
                            break
                        if line.lower().startswith(b"content-length:"):
                            length = int(line.split(b":", 1)[1])
                    if length is not None:
                        self.messages.put(json.loads(self.output.read(length)))
            except (OSError, ValueError) as e:
                self.messages.put({"reader_error": repr(e)})

        threading.Thread(target=reader, daemon=True).start()

    def send(self, value):
        data = json.dumps(value).encode()
        self.input.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        self.input.flush()

    def until(self, predicate, seconds=45):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(
                    timeout=max(0.01, deadline - time.monotonic())
                )
            except queue.Empty:
                break
            if predicate(message):
                return message
        raise AssertionError(
            (
                "Protocol timeout",
                self.process.args,
                self.process.poll(),
                self.diagnostics.decode(errors="replace")[-3000:],
            )
        )

    def close(self):
        if self.sock:
            self.sock.close()
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait()
