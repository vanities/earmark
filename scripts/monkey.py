#!/usr/bin/env python3
"""Stress / monkey test Earmark in the iOS Simulator through the xcodebuildmcp CLI.

Runs scripted scenarios against a real (already configured) NAS source — streaming, skipping,
speed, sleep timer, switching books, download/cancel/resume, background/foreground, kill
mid-scan — then random taps that avoid destructive actions. Reports crashes and logged errors.

  python3 scripts/monkey.py --udid <SIM_UDID> [--steps 150] [--seed 7]
"""
from __future__ import annotations

import argparse
import glob
import os
import random
import re
import subprocess
import sys
import time

BUNDLE = "com.vanities.earmark"
LINE = re.compile(r"^\s*(e\d+)\|(\w+)\|([\w-]+)\|(.*?)\|(.*?)\|(.*)$")
BLOCK = re.compile(
    r"delete|remove|move all|move in|move into|download all|download to iphone|sync|add nas|add folder|rebuild cover|"
    r"hide|cancel download|clear finished|source code|help & support|privacy policy|show in files|connect|retry",
    re.IGNORECASE,
)

class Sim:
    def __init__(self, udid: str, log):
        self.udid = udid
        self.log = log
        self.start = time.time()
        self.baseline_crashes = set(self.crash_reports())
        self.issues: list[str] = []

    def sh(self, cmd: str, timeout: int = 120) -> str:
        try:
            return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout).stdout
        except subprocess.TimeoutExpired:
            self.note(f"TIMEOUT: {cmd[:80]}")
            return ""

    def note(self, msg: str) -> None:
        line = f"[{time.time() - self.start:6.0f}s] {msg}"
        print(line, flush=True)
        self.log.write(line + "\n"); self.log.flush()

    # --- device control
    def snapshot(self) -> list[dict]:
        out = self.sh(f"xcodebuildmcp ui-automation snapshot-ui --simulator-id {self.udid}")
        targets = []
        for line in out.splitlines():
            m = LINE.match(line)
            if m:
                targets.append({"ref": m.group(1), "action": m.group(2), "role": m.group(3), "label": m.group(4), "value": m.group(5), "id": m.group(6)})
        return targets

    def tap(self, ref: str) -> bool:
        out = self.sh(f"xcodebuildmcp ui-automation tap --simulator-id {self.udid} --element-ref {ref}")
        return "✅" in out

    def type_text(self, ref: str, text: str) -> None:
        self.sh(f"xcodebuildmcp ui-automation type-text --simulator-id {self.udid} --element-ref {ref} --text '{text}' --replace-existing")

    def swipe(self, ref: str, direction: str = "up", distance: float = 0.6) -> None:
        self.sh(f"xcodebuildmcp ui-automation swipe --simulator-id {self.udid} --within-element-ref {ref} --direction {direction} --distance {distance}")

    def home(self) -> None:
        self.sh(f"xcodebuildmcp ui-automation button --simulator-id {self.udid} --button-type home")

    def relaunch(self) -> None:
        self.sh(f"xcrun simctl launch {self.udid} {BUNDLE}")
        time.sleep(3)

    def terminate(self) -> None:
        self.sh(f"xcrun simctl terminate {self.udid} {BUNDLE}")

    def alive(self) -> bool:
        return self.sh("pgrep -x Earmark").strip() != ""

    def crash_reports(self) -> list[str]:
        return glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/Earmark*.ips"))

    def check(self, where: str) -> None:
        new = set(self.crash_reports()) - self.baseline_crashes
        if new:
            for path in new:
                self.issues.append(f"CRASH during {where}: {os.path.basename(path)}")
                self.note(f"!!! crash report: {path}")
            self.baseline_crashes |= new
        if not self.alive():
            self.issues.append(f"app not running after {where}")
            self.note(f"!!! app not running after {where} — relaunching")
            self.relaunch()

    # --- helpers
    def find(self, targets: list[dict], *needles: str, role: str | None = None, action: str | None = None) -> dict | None:
        for t in targets:
            hay = f"{t['label']} {t['value']} {t['id']}".lower()
            if role and t["role"] != role: continue
            if action and t["action"] != action: continue
            if all(n.lower() in hay for n in needles):
                return t
        return None

    def tap_first(self, *needles: str, role: str | None = None, wait: float = 1.2) -> bool:
        t = self.find(self.snapshot(), *needles, role=role)
        if not t:
            self.note(f"   (not found: {' + '.join(needles)})")
            return False
        ok = self.tap(t["ref"])
        self.note(f"   tap {' + '.join(needles)} -> {t['ref']} {'ok' if ok else 'FAILED'}")
        time.sleep(wait)
        return ok

    def go_tab(self, name: str) -> None:
        self.tap_first(f"|tab|{name}".replace("|tab|", ""), role="tab")

    def close_sheets(self) -> None:
        for _ in range(3):
            targets = self.snapshot()
            t = self.find(targets, "Close", role="button") or self.find(targets, "Cancel", role="button")
            if not t: break
            self.tap(t["ref"]); time.sleep(0.8)

    # --- scenarios
    def scenario_stream(self) -> None:
        self.note("== scenario: stream remote book, skip, chapters, speed, sleep")
        self.go_tab("Library")
        if not self.tap_first("Remote", "Apprentice") and not self.tap_first("Remote"):
            self.note("   no remote book found"); return
        if not (self.tap_first("Play", role="button") or self.tap_first("Resume", role="button")):
            return
        time.sleep(8)
        targets = self.snapshot()
        playing = self.find(targets, "Pause", role="button") is not None
        self.note(f"   playing after 8s: {playing}")
        for _ in range(3):
            self.tap_first("Skip forward", role="button", wait=1.5)
        self.tap_first("Skip back", role="button", wait=1.5)
        if self.tap_first("Playback speed", role="button"):
            self.tap_first("2×", role="button", wait=1)
            self.sh(f"xcodebuildmcp ui-automation gesture --simulator-id {self.udid} --preset swipe-down") or None
            time.sleep(1); self.close_sheets()
        if self.tap_first("Sleep timer", role="button"):
            self.tap_first("End of chapter", role="button")
        time.sleep(3)
        self.check("stream scenario")
        self.close_sheets()

    def scenario_switch_books(self) -> None:
        self.note("== scenario: switch between remote books quickly")
        for needle in ("E-Myth", "Fool", "Dragon", "Ship"):
            self.go_tab("Library")
            if self.tap_first("Remote", needle):
                self.tap_first("Play", role="button", wait=2) or self.tap_first("Resume", role="button", wait=2)
                self.tap_first("Skip forward", role="button", wait=1)
                self.close_sheets()
                self.tap_first("Library", role="button", wait=0.8)  # back button
            self.check(f"switch to {needle}")

    def scenario_download(self) -> None:
        self.note("== scenario: download, cancel, resume")
        self.go_tab("Library")
        if not self.tap_first("Remote", "Wilful"):
            self.note("   Wilful Princess not visible; trying any m4b-ish remote")
            if not self.tap_first("Remote", "Inheritance"): return
        if not self.tap_first("Download to iPhone", role="button"): return
        time.sleep(6)
        self.tap_first("Cancel Download", role="button", wait=2)
        self.tap_first("Retry Download", role="button") or self.tap_first("Download to iPhone", role="button")
        time.sleep(5)
        self.go_tab("Folders")
        targets = self.snapshot()
        moving = [t for t in targets if "Downloading" in t["label"] or "Downloading" in t["value"] or "Queued" in t["label"]]
        self.note(f"   transfers visible: {len(moving)}")
        self.check("download scenario")

    def scenario_background(self) -> None:
        self.note("== scenario: background while playing, then return")
        self.go_tab("Library")
        if self.tap_first("Remote", "Apprentice") and (self.tap_first("Play", role="button") or self.tap_first("Resume", role="button")):
            time.sleep(3)
        self.home(); time.sleep(6)
        self.relaunch()
        self.note(f"   alive after background/foreground: {self.alive()}")
        targets = self.snapshot()
        self.note(f"   pause visible (still playing): {self.find(targets, 'Pause', role='button') is not None}")
        self.check("background scenario")
        self.close_sheets()

    def scenario_kill_mid_scan(self) -> None:
        self.note("== scenario: rescan NAS, kill mid-scan, relaunch")
        self.go_tab("Folders")
        if self.tap_first("NAS, smb", role="button"):
            self.tap_first("Rescan", role="button", wait=4)
        self.terminate(); time.sleep(2)
        self.relaunch()
        self.note(f"   alive after kill/relaunch: {self.alive()}")
        self.check("kill mid-scan")

    def monkey(self, steps: int, rng: random.Random) -> None:
        self.note(f"== monkey: {steps} random steps")
        words = ["Robin", "Dragon", "fool", "e-myth", "zz", "", "Ship of"]
        for i in range(1, steps + 1):
            targets = [t for t in self.snapshot() if not BLOCK.search(f"{t['label']} {t['value']} {t['id']}")]
            if not targets:
                self.note("   no targets; pressing home + relaunch"); self.home(); time.sleep(1); self.relaunch(); continue
            roll = rng.random()
            if roll < 0.05:
                self.home(); time.sleep(rng.uniform(1, 4)); self.relaunch(); self.note(f"   [{i}] background/foreground")
            elif roll < 0.12:
                self.close_sheets(); self.note(f"   [{i}] close sheets")
            else:
                t = rng.choice(targets)
                if t["action"] == "typeText":
                    word = rng.choice(words); self.type_text(t["ref"], word); self.note(f"   [{i}] type '{word}' into {t['ref']}")
                elif t["action"] == "swipe":
                    self.swipe(t["ref"], rng.choice(["up", "down"])); self.note(f"   [{i}] swipe {t['ref']}")
                else:
                    self.tap(t["ref"]); self.note(f"   [{i}] tap {t['ref']} {t['role']} '{(t['label'] or t['value'])[:60]}'")
            time.sleep(rng.uniform(0.3, 1.2))
            if i % 10 == 0:
                self.check(f"monkey step {i}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--steps", type=int, default=150)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--log", default="monkey.log")
    args = parser.parse_args()
    rng = random.Random(args.seed)
    with open(args.log, "a") as log:
        sim = Sim(args.udid, log)
        if not sim.alive():
            sim.relaunch()
        sim.scenario_stream()
        sim.scenario_switch_books()
        sim.scenario_download()
        sim.scenario_background()
        sim.scenario_kill_mid_scan()
        sim.monkey(args.steps, rng)
        sim.check("end")
        sim.note("== RESULT: " + ("no crashes" if not sim.issues else "; ".join(sim.issues)))
        sys.exit(1 if sim.issues else 0)


if __name__ == "__main__":
    main()
