"""Generates docs/architecture-light.svg and docs/architecture-dark.svg from one layout.

    python3 scripts/architecture-diagram.py docs
"""
import sys

SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"

THEMES = {
    "light": dict(bg="#f6f7f9", mac="#e8eef8", dev="#eaf4ef", box="#ffffff", line="#c9d0da",
                  acc="#2856c9", devc="#1f7a52", aud="#8a4fbf", ring="#111111", chip="#eceff4",
                  muted="#5b6676", text="#16202e", audbox="#f6effc"),
    "dark": dict(bg="#0d1117", mac="#1a2638", dev="#172a23", box="#18202b", line="#354152",
                 acc="#7fa2ff", devc="#5fcf9a", aud="#c9a2ff", ring="#f2f2f2", chip="#212b38",
                 muted="#9aa6b6", text="#e6ebf2", audbox="#221d2e"),
}

W, H = 960, 640

DESC = (
    "On the Mac: an AI agent talks to the vofocus-mcp server, and you or CI use the vofocus CLI. "
    "Both use VOFocusKit, whose RunnerManager starts the runner once through xcodebuild and whose "
    "RunnerClient sends HTTP commands such as POST /vo/next, with a token, over loopback to a "
    "Simulator or over the CoreDevice tunnel to an iPhone (USB or Wi-Fi). On the iPhone or "
    "Simulator, the VOFocusRunner UI test runs each command with XCUIVoiceOverService and "
    "synthesized swipes, driving the real VoiceOver, which reads your unchanged app and speaks; "
    "the runner replies with what it said, such as Save Button. Optionally, VOFocusAudio "
    "(experimental) records VoiceOver's speech and sounds, never a microphone, and transcribes "
    "them on the Mac."
)


def svg(t):
    o = []
    a = o.append
    a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
      'role="img" aria-labelledby="svg-title svg-desc">')
    a('<title id="svg-title">VOFocus architecture</title>')
    a(f'<desc id="svg-desc">{DESC}</desc>')
    a(f"""<style>
.bg{{fill:{t['bg']}}} .zone-mac{{fill:{t['mac']}}} .zone-dev{{fill:{t['dev']}}}
.box{{fill:{t['box']};stroke:{t['line']};stroke-width:1.25}}
.box-kit{{fill:none;stroke:{t['acc']};stroke-width:1.25;stroke-dasharray:4 4}}
.box-run{{fill:{t['box']};stroke:{t['devc']};stroke-width:2}}
.box-mcp{{fill:{t['box']};stroke:{t['acc']};stroke-width:2}}
.box-aud{{fill:{t['audbox']};stroke:{t['aud']};stroke-width:1.5;stroke-dasharray:6 3}}
.ring{{fill:none;stroke:{t['ring']};stroke-width:3}} .chip{{fill:{t['chip']}}}
.t-zone{{font:600 13px {MONO};letter-spacing:.08em;fill:{t['muted']}}}
.t-title{{font:600 14.5px {SANS};fill:{t['text']}}} .t-sub{{font:400 12px {SANS};fill:{t['muted']}}}
.t-mono{{font:500 11.5px {MONO};fill:{t['text']}}} .t-edge{{font:400 11px {MONO};fill:{t['muted']}}}
.t-acc{{fill:{t['acc']}}} .t-dev{{fill:{t['devc']}}} .t-aud{{fill:{t['aud']}}}
.edge{{stroke:{t['muted']};stroke-width:1.5;fill:none}} .edge-acc{{stroke:{t['acc']};stroke-width:2;fill:none}}
.edge-dev{{stroke:{t['devc']};stroke-width:2;fill:none}} .edge-aud{{stroke:{t['aud']};stroke-width:2;fill:none;stroke-dasharray:2 4;stroke-linecap:round}}
.dashed{{stroke-dasharray:5 4}}
.head{{fill:{t['muted']}}} .head-acc{{fill:{t['acc']}}} .head-dev{{fill:{t['devc']}}} .head-aud{{fill:{t['aud']}}}
</style>""")
    a(f'<rect class="bg" width="{W}" height="{H}" rx="14"/>')
    a('<defs>')
    for mid, cls in [("h", "head"), ("ha", "head-acc"), ("hd", "head-dev"), ("hu", "head-aud")]:
        a(f'<marker id="{mid}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
          f'orient="auto-start-reverse"><path class="{cls}" d="M0,0 L10,5 L0,10 z"/></marker>')
    a('</defs>')

    def box(x, y, w, h, cls="box"):
        a(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')

    def text(x, y, s, cls):
        a(f'<text class="{cls}" x="{x}" y="{y}">{s}</text>')

    def line(d, cls="edge", head="h", start=False):
        m = f' marker-start="url(#{head})"' if start else ""
        a(f'<path class="{cls}" d="{d}" marker-end="url(#{head})"{m}/>')

    # Zones
    a(f'<rect class="zone-mac" x="10" y="10" width="440" height="{H - 20}" rx="16"/>')
    a(f'<rect class="zone-dev" x="590" y="10" width="360" height="{H - 20}" rx="16"/>')
    text(30, 40, "YOUR MAC", "t-zone")
    text(610, 40, "IPHONE OR SIMULATOR", "t-zone")

    # Who asks
    box(30, 60, 195, 58)
    text(46, 85, "AI agent", "t-title")
    text(46, 104, "Claude Code, any MCP client", "t-sub")
    box(240, 60, 195, 58)
    text(256, 85, "You or CI", "t-title")
    text(256, 104, "a terminal, GitHub Actions", "t-sub")
    line("M127,118 L127,162")
    text(135, 145, "tool calls", "t-edge")
    line("M337,118 L337,162")
    text(345, 145, "vofocus run", "t-edge")

    # Servers
    box(30, 165, 195, 78, "box-mcp")
    text(46, 190, "vofocus-mcp", "t-title t-acc")
    text(46, 209, "MCP server: 16 tools, like", "t-sub")
    text(46, 225, "vo_walk and audio_report", "t-sub")
    box(240, 165, 195, 78)
    text(256, 190, "vofocus CLI", "t-title")
    text(256, 209, "runs and records YAML", "t-sub")
    text(256, 225, "scenarios, writes JUnit", "t-sub")
    line("M127,243 L127,282")
    line("M337,243 L337,282")

    # VOFocusKit
    a('<rect class="box-kit" x="30" y="285" width="405" height="135" rx="12"/>')
    text(46, 308, "VOFocusKit (shared Swift library)", "t-mono t-acc")
    box(46, 322, 180, 82)
    text(62, 348, "RunnerManager", "t-title")
    text(62, 368, "starts and stops", "t-sub")
    text(62, 385, "the runner", "t-sub")
    box(240, 322, 180, 82)
    text(256, 348, "RunnerClient", "t-title")
    text(256, 368, "sends commands with", "t-sub")
    text(256, 385, "the token, reads replies", "t-sub")

    # xcodebuild
    line("M136,404 L136,452")
    box(46, 455, 180, 44)
    text(62, 482, "xcodebuild test", "t-mono")

    # VOFocusAudio
    a('<rect class="box-aud" x="30" y="520" width="405" height="96" rx="12"/>')
    text(46, 545, "VOFocusAudio · experimental, opt-in", "t-mono t-aud")
    text(46, 568, "records VoiceOver's speech and sounds, never a mic;", "t-sub")
    text(46, 585, "transcribes on the Mac and lines words and sounds", "t-sub")
    text(46, 602, "up with each step (run --audio, audio_start)", "t-sub")

    # Right side: app, VoiceOver, runner
    box(615, 60, 310, 112)
    text(633, 86, "Your app", "t-title")
    text(633, 105, "unchanged: nothing added to it", "t-sub")
    for x, label in [(633, "Profile"), (721, "Save"), (809, "Cancel")]:
        a(f'<rect class="chip" x="{x}" y="120" width="82" height="34" rx="7"/>')
        a(f'<text class="t-mono" x="{x + 41}" y="142" text-anchor="middle">{label}</text>')
    a('<rect class="ring" x="717" y="116" width="90" height="42" rx="9"/>')

    line("M700,214 L700,175")
    text(708, 192, "reads the accessibility tree", "t-edge")

    box(615, 217, 310, 72)
    text(633, 243, "VoiceOver", "t-title")
    text(633, 262, "the real one, built into iOS:", "t-sub")
    text(633, 278, "it speaks and plays its sounds", "t-sub")

    line("M700,340 L700,292", "edge-dev", "hd")
    text(708, 312, "move, swipe, tap,", "t-edge")
    text(708, 327, "read speech", "t-edge")
    line("M860,292 L860,340")
    text(868, 320, "speech", "t-edge")

    box(615, 343, 310, 122, "box-run")
    text(633, 369, "VOFocusRunner", "t-title t-dev")
    text(633, 389, "a UI test that never finishes: it waits", "t-sub")
    text(633, 406, "for commands on port 8740 and runs", "t-sub")
    text(633, 423, "each one with XCUITest", "t-sub")
    a('<rect class="chip" x="633" y="433" width="200" height="22" rx="5"/>')
    text(642, 449, "XCUIVoiceOverService", "t-mono")

    # HTTP between RunnerClient and the runner
    text(462, 282, "HTTP + token over", "t-edge")
    text(462, 298, "CoreDevice tunnel", "t-edge")
    text(462, 314, "(USB or Wi-Fi),", "t-edge")
    text(462, 330, "or loopback (Sim)", "t-edge")
    line("M420,372 L612,372", "edge-acc", "ha")
    text(462, 365, "POST /vo/next", "t-edge t-acc")
    line("M612,398 L423,398", "edge-dev", "hd")
    text(462, 416, '"Save Button"', "t-edge t-dev")

    # xcodebuild starts the runner once
    a('<path class="edge dashed" d="M226,477 L770,477 L770,468" marker-end="url(#h)"/>')
    text(462, 470, "starts it, once", "t-edge")

    # Audio back to the Mac
    line("M925,253 L940,253 L940,590 L438,590", "edge-aud", "hu")
    text(615, 530, "VoiceOver's audio: a process", "t-edge t-aud")
    text(615, 546, "tap on the Simulator, or the", "t-edge t-aud")
    text(615, 562, "iPhone's audio over USB", "t-edge t-aud")

    a('</svg>')
    return "\n".join(o)


if __name__ == "__main__":
    out = sys.argv[1]
    for name, theme in THEMES.items():
        with open(f"{out}/architecture-{name}.svg", "w") as f:
            f.write(svg(theme) + "\n")
