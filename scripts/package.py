#!/usr/bin/env python3
"""Create a signed personal-use .app. Does not launch it or register the helper."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "artifacts/VueVPN.app"

def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), cwd=ROOT, check=True, **kwargs)

def signing_identity():
    configured = os.environ.get("VUEVPN_SIGNING_IDENTITY")
    if configured:
        return configured
    listing = run("security", "find-identity", "-v", "-p", "codesigning", capture_output=True, text=True).stdout
    identities = re.findall(r'\b([A-F0-9]{40})\s+"(?:Apple Development|Developer ID Application):[^\n]+"', listing)
    if len(identities) != 1:
        raise SystemExit("Set VUEVPN_SIGNING_IDENTITY to the SHA-1 of an Apple Development or Developer ID Application identity. Both app and helper require the same Team ID.")
    return identities[0]

def dependencies(binary):
    listing = run("otool", "-L", binary, capture_output=True, text=True).stdout
    return [line.strip().split(" (", 1)[0] for line in listing.splitlines()[1:] if " (" in line]

def bundle_libraries(helper, frameworks):
    frameworks.mkdir(parents=True, exist_ok=True)
    pending = [helper]
    copied = {}
    origins = {}
    while pending:
        binary = pending.pop()
        for source in dependencies(binary):
            if source.startswith(("/System/", "/usr/lib/", "@")):
                continue
            library = Path(source)
            if not library.is_file():
                raise SystemExit(f"Cannot bundle dependency: {library.name}")
            destination = frameworks / library.name
            if source not in copied:
                canonical = library.resolve()
                if destination.name in origins and origins[destination.name] != canonical:
                    raise SystemExit(f"Dependency filename collision: {library.name}")
                copied[source] = destination
                if destination.name not in origins:
                    origins[destination.name] = canonical
                    shutil.copy2(canonical, destination)
                    destination.chmod(0o755)
                    run("install_name_tool", "-id", f"@rpath/{destination.name}", destination, capture_output=True)
                    pending.append(destination)
            # The helper and all nested libraries resolve within Contents/Frameworks.
            run("install_name_tool", "-change", source, f"@rpath/{destination.name}", binary, capture_output=True)
    run("install_name_tool", "-add_rpath", "@executable_path/../Frameworks", helper, capture_output=True)
    for library in copied.values():
        for dep in dependencies(library):
            if dep in copied:
                run("install_name_tool", "-change", dep, f"@rpath/{copied[dep].name}", library, capture_output=True)
    return list(dict.fromkeys(copied.values()))

def sign(path, identity, identifier=None):
    args = ["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp=none"]
    if identifier:
        args += ["--identifier", identifier]
    # Never print certificate identity details in build logs.
    run(*args, path, capture_output=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-build", action="store_true", help="Repackage existing compiled outputs")
    args = parser.parse_args()
    identity = signing_identity()
    if not args.skip_build:
        run(sys.executable, "scripts/native.py", "build")
        env = os.environ.copy()
        env.pop("APPLE_SIGNING_IDENTITY", None)
        run("npm", "run", "tauri", "--", "build", "--bundles", "app", env=env)
    source = ROOT / "src-tauri/target/release/bundle/macos/VueVPN.app"
    if not source.exists():
        raise SystemExit("Build output not found. Run npm run package first.")
    # Replace only the generated staging artifact, never an installed application.
    OUTPUT.parent.mkdir(exist_ok=True)
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    shutil.copytree(source, OUTPUT, symlinks=True)
    contents = OUTPUT / "Contents"
    helper = contents / "MacOS/vuevpn-helper"
    shutil.copy2(ROOT / "native/build/vuevpn-helper", helper)
    helper.chmod(0o755)
    daemon_dir = contents / "Library/LaunchDaemons"
    daemon_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "native/com.vuevpn.helper.plist", daemon_dir)
    libs = bundle_libraries(helper, contents / "Frameworks")
    licenses = contents / "Resources/ThirdPartyLicenses"
    licenses.mkdir(parents=True, exist_ok=True)
    for source in (ROOT / "vendor/openvpn3").glob("*LICENSE*"):
        if source.is_file(): shutil.copy2(source, licenses / source.name)
    for source in (ROOT / "vendor/openvpn3").glob("COPYING*"):
        if source.is_file(): shutil.copy2(source, licenses / source.name)
    shutil.copytree(ROOT / "vendor/openvpn3/LICENSES", licenses / "OpenVPN-LICENSES", dirs_exist_ok=True)
    shutil.copy2(ROOT / "docs/THIRD_PARTY.md", licenses)
    for library in libs:
        sign(library, identity)
    sign(helper, identity, "com.vuevpn.helper")
    sign(OUTPUT, identity, "com.vuevpn.desktop")
    run("codesign", "--verify", "--deep", "--strict", OUTPUT, capture_output=True)
    # Verify the helper has no build-machine-only dependency left.
    for binary in [helper, *libs]:
        if any(dep.startswith(("/opt/", "/usr/local/")) for dep in dependencies(binary)):
            raise SystemExit(f"Unbundled dependency in {binary.name}")
    print(f"Signed application created: {OUTPUT}")
    print("App and helper were not launched. Copy VueVPN.app to /Applications for manual testing.")

if __name__ == "__main__":
    main()
