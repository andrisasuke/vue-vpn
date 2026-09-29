#!/usr/bin/env python3
"""Compile the native app without launching it. Packaging adds/signs the helper."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    args = parser.parse_args()
    output = ROOT / "artifacts/build"
    output.mkdir(parents=True, exist_ok=True)
    log = output / f"native-{args.configuration.lower()}.log"
    with log.open("w") as stream:
        result = subprocess.run([
            "xcodebuild", "-quiet", "-project", "macos/VueVPN.xcodeproj", "-scheme", "VueVPN",
            "-configuration", args.configuration, "-destination", "platform=macOS,arch=arm64",
            "-derivedDataPath", "macos/build", "CODE_SIGNING_ALLOWED=NO", "build",
        ], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    for line in log.read_text().splitlines():
        if "error:" in line or "warning:" in line or "** BUILD" in line:
            print(line)
    print(f"Native {args.configuration}: {'PASS' if result.returncode == 0 else 'FAIL'}; log: {log.relative_to(ROOT)}")
    print("No app or helper started. Use scripts/package.py for a signed VPN-capable bundle.")
    return result.returncode

if __name__ == "__main__":
    sys.exit(main())
