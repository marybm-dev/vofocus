#!/usr/bin/env python3
"""End-to-end check of vofocus-mcp, speaking MCP over stdio like an agent's client.

    swift build --package-path Host
    scripts/mcp_smoke.py

Starts the runner through the MCP server, installs and drives the demo app, and stops
the runner. Prints PASS/FAIL per check and exits 1 on any failure.
"""
import json
import os
import pathlib
import re
import select
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = ROOT / "Host/.build/debug/vofocus-mcp"
DEMO_APP = ROOT / "build/DerivedData/Build/Products/Debug-iphonesimulator/DemoApp.app"
SIM_NAME = os.environ.get("SIM_NAME", "iPhone 18 Pro")

failures = 0


def check(description, ok, detail=""):
    global failures
    print(f"  {'PASS' if ok else 'FAIL'}  {description}")
    if not ok:
        failures += 1
        print("        " + str(detail)[:600].replace("\n", "\n        "))


class Client:
    def __init__(self):
        self.log = open(ROOT / "build/mcp-server.log", "w")
        self.proc = subprocess.Popen(
            [str(SERVER)], cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.log, env={**os.environ, "VOFOCUS_SIMULATOR": SIM_NAME})
        self.next_id = 1

    def send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params=None, timeout=300):
        request_id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        deadline = time.time() + timeout
        while time.time() < deadline:
            ready, _, _ = select.select([self.proc.stdout], [], [], deadline - time.time())
            if not ready:
                break
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("server closed stdout")
            message = json.loads(line)
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message["result"]
        raise TimeoutError(f"{method} timed out")

    def tool(self, name, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        text = "".join(part.get("text", "") for part in result["content"])
        return text, bool(result.get("isError"))

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=60)
        self.log.close()


def tool_json(client, name, **arguments):
    text, is_error = client.tool(name, **arguments)
    try:
        return json.loads(text), is_error
    except json.JSONDecodeError:
        return {"text": text}, is_error


def main():
    print("== Building demo app")
    destination = subprocess.run(
        ["bash", "-c", ". scripts/lib.sh && sim_destination"], cwd=ROOT, check=True,
        capture_output=True, text=True, env={**os.environ, "SIM_NAME": SIM_NAME}).stdout.strip()
    subprocess.run(
        ["xcodebuild", "build", "-project", "VOFocus.xcodeproj", "-scheme", "DemoApp",
         "-destination", destination, "-derivedDataPath", "build/DerivedData", "-quiet"],
        cwd=ROOT, check=True)
    prefix = "dev.vofocus"
    for config in ("Config/Project.xcconfig", "Config/Local.xcconfig"):
        path = ROOT / config
        if path.exists():
            match = re.search(r"^VOFOCUS_BUNDLE_PREFIX\s*=\s*(\S+)", path.read_text(), re.M)
            prefix = match.group(1) if match else prefix
    bundle_id = f"{prefix}.DemoApp"

    client = Client()
    try:
        print("== MCP handshake")
        init = client.request("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "mcp_smoke", "version": "0"}})
        client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        check("server identifies as vofocus", init["serverInfo"]["name"] == "vofocus", init)
        tools = [t["name"] for t in client.request("tools/list")["tools"]]
        check("lists 13 tools", len(tools) == 13, tools)

        print("== Runner")
        text, is_error = client.tool("vo_move", direction="next")
        check("tools fail clearly before the runner starts",
              is_error and ("runner_start" in text or "noSession" in text), text)
        started = time.time()
        text, is_error = client.tool("runner_start", wait=60)
        while not is_error and text.startswith("starting") and time.time() - started < 600:
            time.sleep(5)
            text, is_error = client.tool("runner_status")
        check(f"runner ready ({int(time.time() - started)} s)", text.startswith("ready"), text)

        text, is_error = client.tool("app_install", path=str(DEMO_APP))
        check("app_install", not is_error, text)

        print("== Focus order")
        session, is_error = tool_json(client, "app_launch", bundleId=bundle_id,
                                      arguments=["-VOScenario", "static"])
        check("app_launch", not is_error, session)
        walk, _ = tool_json(client, "vo_walk")
        words = [re.search(r"Static Order|One|Two|Three", s).group(0) for s in walk.get("stops", [])
                 if re.search(r"Static Order|One|Two|Three", s)]
        check("vo_walk: heading, One, Two, Three", words == ["Static Order", "One", "Two", "Three"], walk)

        print("== Activate an element: focus moves there first")
        tool_json(client, "app_launch", bundleId=bundle_id, arguments=["-VOScenario", "counter"])
        tool_json(client, "vo_focus", element={"identifier": "count"})
        _, is_error = client.tool("vo_activate", element={"identifier": "increment"})
        check("vo_activate on #increment", not is_error)
        speech, _ = tool_json(client, "vo_speech")
        check("VoiceOver focus moved to Increment", "Increment" in speech.get("utterance", ""), speech)
        tree, _ = client.tool("ui_tree")
        check("count went up", '"Count: 1"' in tree, tree)

        print("== Programmatic focus")
        for scenario, trigger, expected in [("uikit-banner", "save", "Saved successfully"),
                                            ("swiftui-error", "submit", "Name is required")]:
            tool_json(client, "app_launch", bundleId=bundle_id, arguments=["-VOScenario", scenario])
            focus, _ = tool_json(client, "vo_focus", element={"identifier": trigger})
            check(f"{scenario}: vo_focus on #{trigger}", "utterance" in focus, focus)
            _, is_error = client.tool("vo_activate")
            check(f"{scenario}: vo_activate", not is_error)
            speech, is_error = tool_json(client, "vo_speech", contains=expected, timeout=3)
            check(f"{scenario}: VoiceOver lands on \"{expected}\"", not is_error, speech)

        print("== Tree")
        text, is_error = client.tool("ui_tree")
        check("ui_tree outline shows the error text", 'staticText "Name is required" #error' in text, text)

        print("== Stop")
        text, is_error = client.tool("runner_stop")
        check("runner_stop exits cleanly", "exit status 0" in text, text)
    finally:
        client.close()

    print()
    print("All checks passed" if failures == 0 else f"{failures} check(s) failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
