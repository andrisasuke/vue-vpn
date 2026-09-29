#!/usr/bin/env python3
"""Hostless AppKit unit/image tests against frozen references; no app or window."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "artifacts/migration"
PHASES = {
    "native": (["testNativeHeadingMeetsSimilarityRequirement", "testNativePasswordFieldMeetsSimilarityRequirement"], ["heading", "password"]),
    "panels": (["testNativeConnectionPanelsMeetSimilarityRequirement"], [f"connection-{s}" for s in ["disconnected", "connected", "connecting"]]),
    "chrome": (["testNativeWorkspaceChromeMeetsSimilarityRequirement"], ["sidebar", "header", "footer"]),
    "credentials": (["testNativeCredentialsContentMeetsSimilarityRequirement"], ["credentials"]),
    "overview": (["testNativeOverviewMeetsSimilarityRequirement"], [f"overview-{s}" for s in ["disconnected", "connected", "connecting"]]),
    "screens": (["testNativeAdditionalScreensMeetSimilarityRequirement"], ["welcome", "activity-empty", "activity-events", "settings-enabled", "settings-repair", "overview-all", "overview-routes", "overview-minimum"]),
    "dialogs": (["testNativeDialogsMeetSimilarityRequirement"], ["editor-selected", "editor-all", "delete-dialog", "pin-error"]),
    "behavior": (["SceneTests/"], []),
    "theme": (["ThemeTests/"], []),
    "energy": (["EnergyTests/"], []),
    "performance": (["PerformanceTests/"], []),
}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=[*PHASES, "all"], default="all", nargs="?")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    args = parser.parse_args()
    references = ROOT / "macos/VisualTests/References"
    manifest = json.loads((references / "manifest.json").read_text())
    for name, expected in manifest["sha256"].items():
        if hashlib.sha256((references / name).read_bytes()).hexdigest() != expected:
            parser.error(f"Frozen reference changed: {name}")
    phases = list(PHASES) if args.phase == "all" else [args.phase]
    methods = [method for phase in phases for method in PHASES[phase][0]]
    reports = [name for phase in phases for name in PHASES[phase][1]]
    expected_count = sum(12 if phase == "behavior" else 7 if phase == "theme" else 8 if phase == "energy" else len(PHASES[phase][0]) for phase in phases)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    suffix = args.phase + ("-release" if args.configuration == "Release" else "")
    bundle = OUTPUT / f"ui-{suffix}.xcresult"
    if bundle.exists():
        shutil.rmtree(bundle)
    for name in reports:
        (OUTPUT / f"{name}-comparison.json").unlink(missing_ok=True)
    command = ["xcodebuild", "-quiet", "-project", "macos/VueVPN.xcodeproj",
               "-scheme", "VueVPNVisualTests", "-configuration", args.configuration,
               "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", "macos/build",
               "-parallel-testing-enabled", "NO", "-resultBundlePath", str(bundle)]
    command += [f"-only-testing:VueVPNVisualTests/{m.rstrip('/') if '/' in m else 'OffscreenTests/' + m}" for m in methods]
    log = OUTPUT / f"ui-{suffix}.log"
    with log.open("w") as stream:
        result = subprocess.run(command + ["test"], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    status = result.returncode
    for line in log.read_text().splitlines():
        if "error:" in line or "** TEST FAILED **" in line:
            print(line)
    if bundle.exists():
        report = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
                                cwd=ROOT, capture_output=True, text=True)
        if report.returncode == 0:
            summary = json.loads(report.stdout)
            count = summary.get("totalTestCount", 0)
            print(f"UI: executed {count} tests; {summary.get('passedTests', 0)} passed; {summary.get('failedTests', 0)} failed")
            if count != expected_count or summary.get("skippedTests", 0) or summary.get("failedTests", 0):
                print(f"Expected {expected_count} tests with no skips or failures.")
                status = status or 1
        else:
            print("Could not verify executed test count.")
            status = status or 1
    else:
        status = status or 1
    for name in reports:
        report = OUTPUT / f"{name}-comparison.json"
        if not report.exists():
            print(f"Missing comparison: {name}")
            status = status or 1
            continue
        data = json.loads(report.read_text())
        total, significant = data["totalPixels"], data["significantDifferentPixels"]
        print(f"{name}: {100 * (1 - significant / total):.3f}% similarity; "
              f"{data['differentPixels']} exact differences / {total}; {significant} beyond 2/255 allowance")
    print(f"Native UI: {'PASS' if status == 0 else 'FAIL'}; log: {log.relative_to(ROOT)}")
    return status

if __name__ == "__main__":
    sys.exit(main())
