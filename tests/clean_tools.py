#!/usr/bin/env python3
"""Build tiny local npm/Python registries and test installs with no existing tool data."""
import base64
import csv
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import threading
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def npm_tar(name, version, files):
    stream = io.BytesIO()
    files = dict(files, **{"package.json": json.dumps(dict(name=name, version=version,
        dependencies={"offline-child": "*"} if name == "offline-node-tool" else {},
        bin={"offline-node-tool": "cli.js"} if name == "offline-node-tool" else {}, main="index.js"))})
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for filename, text in files.items():
            value = text.encode()
            info = tarfile.TarInfo("package/" + filename)
            info.size, info.mode = len(value), 0o755 if filename == "cli.js" else 0o644
            archive.addfile(info, io.BytesIO(value))
    return stream.getvalue()


def wheel(directory, name, version, dependency=None):
    module = name.replace("-", "_")
    prefix = module + "-" + version + ".dist-info/"
    code = ("def main():\n    import offline_child\n    print(offline_child.__version__)\n"
            if dependency else "__version__ = " + repr(version) + "\n")
    files = {module + "/__init__.py": code,
        prefix + "METADATA": "Metadata-Version: 2.1\nName: " + name + "\nVersion: " + version + "\n" +
            ("Requires-Dist: offline-child>=1\n" if dependency else ""),
        prefix + "WHEEL": "Wheel-Version: 1.0\nGenerator: toolchain-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n"}
    if dependency:
        files[prefix + "entry_points.txt"] = "[console_scripts]\noffline-python-tool = offline_python_tool:main\n"
    record = io.StringIO()
    writer = csv.writer(record, lineterminator="\n")
    for filename, text in files.items():
        encoded = text.encode()
        writer.writerow([filename, "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(encoded).digest()).decode().rstrip("="), len(encoded)])
    writer.writerow([prefix + "RECORD", "", ""])
    files[prefix + "RECORD"] = record.getvalue()
    with zipfile.ZipFile(directory / (module + "-" + version + "-py3-none-any.whl"), "w") as archive:
        for filename, text in files.items():
            archive.writestr(filename, text)


def main():
    with tempfile.TemporaryDirectory(prefix="toolchain-clean-") as directory:
        temp = Path(directory)
        for name in ("wheels", "updates"):
            (temp / name).mkdir()
        wheel(temp / "wheels", "offline-child", "1.0.0")
        wheel(temp / "updates", "offline-child", "2.0.0")
        wheel(temp / "wheels", "offline-python-tool", "1.0.0", dependency=True)
        packages = {("offline-node-tool", "1.0.0"): npm_tar("offline-node-tool", "1.0.0", {
            "cli.js": "#!/usr/bin/env node\nconsole.log(require('offline-child').version)\n"})}
        for version in ("1.0.0", "2.0.0"):
            packages[("offline-child", version)] = npm_tar("offline-child", version, {"index.js": "exports.version=" + repr(version) + ";\n"})

        class Registry(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                path = self.path.split("?", 1)[0]
                if path.startswith("/tar/"):
                    name, version = path[len("/tar/"):].rsplit("/", 1)
                    body = packages.get((name, version))
                else:
                    name = path.lstrip("/")
                    versions = [version for pkg, version in packages if pkg == name and
                                (version != "2.0.0" or (temp / "registry-updated").exists())]
                    if versions:
                        entries = {}
                        for version in versions:
                            entries[version] = {"name": name, "version": version,
                                "dependencies": {"offline-child": "*"} if name == "offline-node-tool" else {},
                                "bin": {"offline-node-tool": "cli.js"} if name == "offline-node-tool" else {},
                                "dist": {"tarball": "http://127.0.0.1:%d/tar/%s/%s" % (self.server.server_port, name, version),
                                         "integrity": "sha512-" + base64.b64encode(hashlib.sha512(packages[(name, version)]).digest()).decode()}}
                        body = json.dumps({"name": name, "dist-tags": {"latest": sorted(versions)[-1]}, "versions": entries}).encode()
                    else:
                        body = None
                self.send_response(200 if body else 404)
                self.send_header("Content-Type", "application/json" if not path.startswith("/tar/") else "application/octet-stream")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                if body:
                    self.wfile.write(body)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Registry)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = dict(os.environ, TOOLCHAIN_CLEAN_TMP=directory, XDG_DATA_HOME=directory + "/data",
            XDG_STATE_HOME=directory + "/state", XDG_CACHE_HOME=directory + "/cache", NVIM_LOG_FILE=directory + "/nvim.log",
            NVIM_DEV_PLUGIN_ROOT=directory + "/missing-plugins", npm_config_registry="http://127.0.0.1:%d" % server.server_port,
            npm_config_audit="false", npm_config_fund="false", npm_config_userconfig=os.devnull,
            npm_config_global="true", npm_config_prefix=directory + "/unrelated-global", npm_config_update_notifier="false",
            PIP_NO_INDEX="1", PIP_FIND_LINKS=str(temp / "wheels"), UV_NO_INDEX="1", UV_FIND_LINKS=str(temp / "wheels"),
            PATH=":".join(p for p in os.environ["PATH"].split(":") if "/mason/" not in p))
        try:
            result = subprocess.run([env.get("NVIM_BIN", "nvim"), "--headless", "-n", "-u", "NONE", "-i", "NONE",
                "--noplugin", "-l", str(ROOT / "tests/clean_tools.lua")], cwd=ROOT, env=env, capture_output=True, text=True, timeout=240)
            assert result.returncode == 0, result.stdout + result.stderr
            print(result.stdout.strip())
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    main()
