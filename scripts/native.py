#!/usr/bin/env python3
"""Build the embedded OpenVPN library/helper, or run non-networking unit tests."""
import argparse
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
COMMIT = "18edfae7e7fd8051c93bd4746ec69be91eb02dbb"
CORE = ROOT / "vendor/openvpn3"

def run(*args, **kw):
    return subprocess.run(list(map(str, args)), check=True, cwd=ROOT, **kw)

def prepare():
    if not (CORE / ".git").exists():
        CORE.parent.mkdir(exist_ok=True)
        run("git", "clone", "--depth", "1", "--branch", "release/3.11.7", "https://github.com/OpenVPN/openvpn3.git", CORE)
    actual = run("git", "-C", CORE, "rev-parse", "HEAD", capture_output=True, text=True).stdout.strip()
    if actual != COMMIT:
        raise SystemExit("Unexpected OpenVPN Core commit. Remove vendor/openvpn3 and prepare again.")

def configure():
    prepare()
    run("cmake", "-S", ROOT / "native", "-B", ROOT / "native/build", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_PREFIX_PATH=/opt/homebrew;/opt/homebrew/opt/openssl@3", "-DCMAKE_OSX_ARCHITECTURES=arm64")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["prepare", "build", "test"])
    args = parser.parse_args()
    if args.action == "prepare":
        prepare()
    else:
        configure()
        targets = ["native-unit-tests", "core-unit-tests", "engine-unit-tests", "network-unit-tests"] if args.action == "test" else ["vuevpn-helper"]
        run("cmake", "--build", ROOT / "native/build", "--target", *targets, "-j", min(os.cpu_count() or 2, 6))
        if args.action == "test":
            run("ctest", "--test-dir", ROOT / "native/build", "--output-on-failure")

if __name__ == "__main__":
    main()
