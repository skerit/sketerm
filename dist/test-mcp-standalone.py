#!/usr/bin/env python3
"""Smoke-test the installed standalone server after relocation, without a GUI sibling."""

import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile


def main():
    prefix = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out").resolve()
    with tempfile.TemporaryDirectory(prefix="sk-mcp-", dir="/tmp") as tmp:
        root = Path(tmp)
        (root / "bin").mkdir()
        for binary in ("sketerm-mcp", "sketerm-mux"):
            shutil.copy2(prefix / "bin" / binary, root / "bin" / binary)
        scripts = root / "share/sketerm/shell-integration"
        shutil.copytree(prefix / "share/sketerm/shell-integration", scripts)
        for script in ("sketerm.bash", "bash/sketerm-rc.bash", "zsh/.zshenv",
                       "fish-xdg/fish/vendor_conf.d/sketerm.fish"):
            assert (scripts / script).is_file(), script
        env = {k: v for k, v in os.environ.items() if not k.startswith("SKETERM_")}
        for key, directory in (("HOME", "home"), ("XDG_RUNTIME_DIR", "run"),
                               ("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"),
                               ("XDG_CACHE_HOME", "cache")):
            path = root / directory
            path.mkdir(mode=0o700)
            env[key] = str(path)
        env["SHELL"] = "/bin/bash"
        read_fd, write_fd = os.pipe()
        env["SKETERM_MUX_LIFETIME_FD"] = str(read_fd)
        try:
            with subprocess.Popen([root / "bin/sketerm-mcp", "--web-gui"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  env=env, cwd=root, pass_fds=(read_fd,)) as server:
                request_id = 0

                def rpc(method, params):
                    nonlocal request_id
                    request_id += 1
                    request = dict(jsonrpc="2.0", id=request_id, method=method, params=params)
                    server.stdin.write(json.dumps(request).encode() + b"\n")
                    server.stdin.flush()
                    assert select.select([server.stdout], [], [], 15)[0], method + " timed out"
                    reply = json.loads(server.stdout.readline())
                    assert reply.get("id") == request_id, reply
                    assert "error" not in reply, reply
                    return reply["result"]

                def tool(name, **args):
                    return rpc("tools/call", dict(name=name, arguments=args))

                try:
                    rpc("initialize", dict(protocolVersion="2024-11-05", capabilities={},
                                           clientInfo=dict(name="standalone-smoke", version="1")))
                    tools = rpc("tools/list", {})["tools"]
                    assert any(t["name"] == "term_run" for t in tools)
                    caps = tool("capabilities")["structuredContent"]
                    assert caps["app_record_webm"] is False, caps
                    assert caps["gui_socket"] is False, caps
                    refused = tool("web_open", url="about:blank")
                    assert refused["isError"], refused
                    assert refused["structuredContent"]["error"]["code"] == "unavailable", refused
                    assert "could not be started" in json.dumps(refused), refused
                    opened = tool("term_open", command=["/bin/bash"])
                    assert not opened.get("isError"), opened
                    result = tool("term_run", command="printf 'STANDALONE-OK\\n'", wait_for="command",
                                  output_only=True)
                    facts = result["structuredContent"]
                    assert facts["state"] == "completed", result
                    assert facts["exit_status"] == 0, result
                    assert facts["completion_source"] == "shell_integration", result
                    assert "STANDALONE-OK" in json.dumps(result), result
                    closed = tool("term_close")
                    assert not closed.get("isError"), closed
                    app = tool("launch_app", command=["/bin/sleep", "30"], wait_ms=10)
                    assert not app.get("isError"), app
                    webm = tool("app_record_start", window=1, format="webm")
                    assert webm["isError"], webm
                    assert webm["structuredContent"]["error"]["code"] == "unavailable", webm
                    assert not tool("close_app").get("isError")
                    server.stdin.close()
                    assert server.wait(timeout=15) == 0
                finally:
                    if server.poll() is None:
                        server.kill()
                        server.wait()
        finally:
            os.close(write_fd)
            os.close(read_fd)
    print("PASS: relocated standalone MCP, WebM refusal, GUI refusal, shell completion")


if __name__ == "__main__":
    main()
