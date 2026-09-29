#!/usr/bin/env python3
"""Run hostless Swift unit tests. No application, helper, Keychain or live VPN."""
from pathlib import Path
import json
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "artifacts/migration"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    log = OUTPUT / "core-tests.log"
    bundle = OUTPUT / "core.xcresult"
    if bundle.exists():
        shutil.rmtree(bundle)
    command = ["xcodebuild", "-project", "macos/VueVPN.xcodeproj",
               "-scheme", "VueVPNCoreTests", "-configuration", "Debug",
               "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", "macos/build",
               "-parallel-testing-enabled", "NO", "-resultBundlePath", str(bundle), "test"]
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    for line in log.read_text().splitlines():
        if "error:" in line or "Executed " in line or "** TEST" in line:
            print(line)
    status = result.returncode
    if bundle.exists():
        report = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
                                cwd=ROOT, capture_output=True, text=True)
        if report.returncode == 0:
            summary = json.loads(report.stdout)
            count = summary.get("totalTestCount", 0)
            print(f"core: executed {count} tests; {summary.get('passedTests', 0)} passed; {summary.get('failedTests', 0)} failed")
            if count != 102 or summary.get("skippedTests", 0) or summary.get("failedTests", 0):
                print("Expected 102 executed tests with no skips or failures.")
                status = status or 1
        else:
            print("Could not verify executed core test count.")
            status = status or 1
    else:
        status = status or 1
    print(f"Swift core: {'PASS' if status == 0 else 'FAIL'}; log: {log.relative_to(ROOT)}")
    return status


if __name__ == "__main__":
    sys.exit(main())
