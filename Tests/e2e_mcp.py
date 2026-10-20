#!/usr/bin/env python3
"""
End-to-end tests for the SwiftShot MCP server.

The test drives the real `swiftshot-mcp` binary over stdio exactly like an AI
coding agent would (JSON-RPC 2.0 / MCP) and checks the answers against the
running SwiftShot app.

Usage:
    python3 Tests/e2e_mcp.py [--binary PATH] [--keep-app-running]

Exit code 0 = all tests passed.
"""

import argparse
import base64
import json
import os
import shutil
import struct
import subprocess
import sys
import time

SOCKET_PATH = os.path.expanduser("~/Library/Application Support/SwiftShot/bridge.sock")

PASSED = []
FAILED = []


# --------------------------------------------------------------------------- helpers

def check(name, condition, detail=""):
    if condition:
        PASSED.append(name)
        print(f"  \033[32mPASS\033[0m  {name}")
    else:
        FAILED.append((name, detail))
        print(f"  \033[31mFAIL\033[0m  {name}" + (f"  -> {detail}" if detail else ""))


def section(title):
    print(f"\n\033[1m{title}\033[0m")


class MCPClient:
    """Minimal MCP client speaking JSON-RPC 2.0 over the server's stdio."""

    def __init__(self, binary):
        self.process = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self._id = 0

    def send(self, method, params=None, expect_response=True, timeout=30):
        self._id += 1
        request = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            request["params"] = params
        self._write(request)
        if not expect_response:
            return None
        return self._read(timeout=timeout)

    def notify(self, method, params=None):
        request = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            request["params"] = params
        self._write(request)

    def _write(self, payload):
        data = json.dumps(payload).encode() + b"\n"
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def _read(self, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("the MCP server closed its output stream")
            line = line.strip()
            if not line:
                continue
            return json.loads(line)
        raise TimeoutError("no response from the MCP server")

    def close(self):
        try:
            self.process.stdin.close()
        except Exception:
            pass
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except Exception:
            self.process.kill()


def png_size(data):
    """Returns (width, height) of a PNG blob."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    if data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def ensure_app_running(start_app=True):
    if os.path.exists(SOCKET_PATH):
        return True, "already running"
    if not start_app:
        return False, "the app is not running and --no-start was given"
    candidates = ["/Applications/SwiftShot.app"]
    subprocess.run(["open", "-g", "-a", "SwiftShot"], check=False)
    for _ in range(40):
        if os.path.exists(SOCKET_PATH):
            return True, "launched"
        time.sleep(0.25)
    return False, "the app did not create its bridge socket"


def find_binary(explicit=None):
    if explicit:
        return explicit
    candidates = [
        os.path.join(os.path.dirname(__file__), "..", "MCP", ".build", "release", "swiftshot-mcp"),
        os.path.join(os.path.dirname(__file__), "..", "MCP", ".build", "debug", "swiftshot-mcp"),
    ]
    for candidate in candidates:
        candidate = os.path.normpath(candidate)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which("swiftshot-mcp")
    if found:
        return found
    return None


# --------------------------------------------------------------------------- tests

def test_handshake(client):
    section("MCP handshake")
    response = client.send("initialize", {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "swiftshot-e2e", "version": "1.0.0"},
    })
    check("initialize returns a result", "result" in response, json.dumps(response)[:200])
    result = response.get("result", {})
    check("the server announces a protocol version", bool(result.get("protocolVersion")))
    check("the server announces its name", result.get("serverInfo", {}).get("name") == "swiftshot-mcp")
    check("the server advertises the tools capability", "tools" in result.get("capabilities", {}))

    client.notify("notifications/initialized")
    return result


def test_tools_list(client):
    section("tools/list")
    response = client.send("tools/list")
    tools = response.get("result", {}).get("tools", [])
    names = [tool.get("name") for tool in tools]
    check("five tools are advertised", len(tools) == 5, f"got {names}")
    for expected in ["swiftshot_capture", "swiftshot_displays", "swiftshot_status",
                     "swiftshot_settings", "swiftshot_open_settings"]:
        check(f"the tool {expected} exists", expected in names)
    capture = next((t for t in tools if t.get("name") == "swiftshot_capture"), None)
    check("the capture tool has an input schema",
          capture is not None and capture.get("inputSchema", {}).get("type") == "object")
    check("every tool has a description",
          all(bool(t.get("description")) for t in tools))


def test_status(client):
    section("swiftshot_status")
    response = client.send("tools/call", {"name": "swiftshot_status", "arguments": {}})
    content = response.get("result", {}).get("content", [])
    text = content[0].get("text", "") if content else ""
    check("the status call succeeds", response.get("result", {}).get("isError") is False, text)
    check("the status mentions the version", "SwiftShot" in text, text)
    check("the status reports the screen recording permission",
          "Screen Recording permission" in text, text)


def test_displays(client):
    section("swiftshot_displays")
    response = client.send("tools/call", {"name": "swiftshot_displays", "arguments": {}})
    content = response.get("result", {}).get("content", [])
    text = content[0].get("text", "") if content else ""
    check("the display call succeeds", response.get("result", {}).get("isError") is False, text)
    check("at least one display is listed", "id=" in text, text)
    check("the display entry carries a scale", "scale=" in text, text)


def test_capture_full_screen(client):
    section("swiftshot_capture (full screen)")
    response = client.send("tools/call", {"name": "swiftshot_capture", "arguments": {}}, timeout=60)
    result = response.get("result", {})
    check("the capture call succeeds", result.get("isError") is False,
          json.dumps(result.get("content", []))[:300])

    content = result.get("content", [])
    image_parts = [part for part in content if part.get("type") == "image"]
    check("an image is returned", len(image_parts) == 1)

    if image_parts:
        data = base64.b64decode(image_parts[0]["data"])
        check("the image is a valid PNG", data[:8] == b"\x89PNG\r\n\x1a\n")
        check("the mime type is image/png", image_parts[0].get("mimeType") == "image/png")
        size = png_size(data)
        check("the PNG has a readable size", size is not None and size[0] > 0 and size[1] > 0, str(size))
        if size:
            check("the screenshot is bigger than 200x200 points",
                  size[0] > 200 and size[1] > 200, f"{size}")
        check("the payload is not empty", len(data) > 5_000, f"{len(data)} bytes")

    text = content[0].get("text", "") if content else ""
    check("the summary reports the pixel size", "pixels" in text, text)


def test_capture_region(client):
    section("swiftshot_capture (region)")
    response = client.send("tools/call", {
        "name": "swiftshot_capture",
        "arguments": {"region": {"x": 0, "y": 0, "width": 320, "height": 200}},
    }, timeout=60)
    result = response.get("result", {})
    check("the region capture succeeds", result.get("isError") is False,
          json.dumps(result.get("content", []))[:300])

    image_parts = [part for part in result.get("content", []) if part.get("type") == "image"]
    if image_parts:
        data = base64.b64decode(image_parts[0]["data"])
        size = png_size(data)
        # The region is given in points, the image is in pixels (points * scale).
        text = result.get("content", [{}])[0].get("text", "")
        scale = 2
        for token in text.split():
            if token.startswith("scale"):
                try:
                    scale = int(token)
                except ValueError:
                    pass
        expected = (320 * scale, 200 * scale)
        check("the region is cropped to the requested size", size == expected, f"{size} != {expected}")

    # A region outside of any screen has to fail gracefully.
    response = client.send("tools/call", {
        "name": "swiftshot_capture",
        "arguments": {"region": {"x": 99999, "y": 99999, "width": 10, "height": 10}},
    }, timeout=60)
    check("an off-screen region reports an error",
          response.get("result", {}).get("isError") is True,
          json.dumps(response.get("result", {}))[:200])


def test_capture_jpeg(client):
    section("swiftshot_capture (jpeg)")
    response = client.send("tools/call", {
        "name": "swiftshot_capture",
        "arguments": {"region": {"x": 0, "y": 0, "width": 200, "height": 200}, "format": "jpeg"},
    }, timeout=60)
    result = response.get("result", {})
    check("the jpeg capture succeeds", result.get("isError") is False,
          json.dumps(result.get("content", []))[:300])
    image_parts = [part for part in result.get("content", []) if part.get("type") == "image"]
    if image_parts:
        check("the mime type is image/jpeg", image_parts[0].get("mimeType") == "image/jpeg",
              image_parts[0].get("mimeType"))
        data = base64.b64decode(image_parts[0]["data"])
        check("the jpeg payload is not a PNG", data[:8] != b"\x89PNG\r\n\x1a\n")


def test_settings(client):
    section("swiftshot_settings")
    response = client.send("tools/call", {"name": "swiftshot_settings", "arguments": {}})
    content = response.get("result", {}).get("content", [])
    text = content[0].get("text", "") if content else ""
    check("the settings call succeeds", response.get("result", {}).get("isError") is False, text)
    check("the settings include the hotkey", "hotkey" in text, text)
    check("the settings include the save format", "saveFormat" in text, text)

    # Change a value and read it back.
    response = client.send("tools/call", {
        "name": "swiftshot_settings",
        "arguments": {"show_magnifier": False},
    })
    content = response.get("result", {}).get("content", [])
    text = content[0].get("text", "") if content else ""
    check("the settings can be updated", "showMagnifier = false" in text, text)

    response = client.send("tools/call", {"name": "swiftshot_settings", "arguments": {}})
    content = response.get("result", {}).get("content", [])
    text = content[0].get("text", "") if content else ""
    check("the updated value is persisted", "showMagnifer" not in text and "showMagnifier = false" in text, text)

    # Restore the original value.
    client.send("tools/call", {"name": "swiftshot_settings", "arguments": {"show_magnifier": True}})


def test_open_settings(client):
    section("swiftshot_open_settings")
    response = client.send("tools/call", {"name": "swiftshot_open_settings", "arguments": {}})
    check("the settings window can be opened", response.get("result", {}).get("isError") is False,
          json.dumps(response.get("result", {}))[:200])


def test_errors(client):
    section("error handling")
    response = client.send("tools/call", {"name": "does_not_exist", "arguments": {}})
    check("an unknown tool reports an error", response.get("result", {}).get("isError") is True,
          json.dumps(response.get("result", {}))[:200])

    response = client.send("nonexistent/method")
    check("an unknown method returns a JSON-RPC error", "error" in response,
          json.dumps(response)[:200])
    check("the JSON-RPC error has a code", response.get("error", {}).get("code") == -32601)

    response = client.send("ping")
    check("ping is answered", "result" in response, json.dumps(response)[:120])


# --------------------------------------------------------------------------- main

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", help="path to the swiftshot-mcp executable")
    parser.add_argument("--no-start", action="store_true", help="do not launch the app")
    args = parser.parse_args()

    binary = find_binary(args.binary)
    if not binary:
        print("swiftshot-mcp binary not found — build it with: cd MCP && swift build -c release")
        return 2
    print(f"MCP server: {binary}")

    running, detail = ensure_app_running(not args.no_start)
    check("the SwiftShot app is running and exposes its bridge socket", running, detail)
    if not running:
        return 1

    client = MCPClient(binary)
    try:
        test_handshake(client)
        test_tools_list(client)
        test_status(client)
        test_displays(client)
        test_capture_full_screen(client)
        test_capture_region(client)
        test_capture_jpeg(client)
        test_settings(client)
        test_open_settings(client)
        test_errors(client)
    finally:
        client.close()

    print(f"\n\033[1mResult:\033[0m {len(PASSED)} passed, {len(FAILED)} failed")
    for name, detail in FAILED:
        print(f"  \033[31m✗\033[0m {name}" + (f" -> {detail}" if detail else ""))
    return 0 if not FAILED else 1


if __name__ == "__main__":
    sys.exit(main())
