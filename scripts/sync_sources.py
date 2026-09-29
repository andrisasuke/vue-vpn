#!/usr/bin/env python3
"""Keep the native Xcode targets in sync with Swift sources."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
project = ROOT / "macos/VueVPN.xcodeproj/project.pbxproj"
source = project.read_text()
entries, references, builds = [], [], []
source = re.sub(r"^  [BC][0-9A-F]{23} = .*\n", "", source, flags=re.M)
source = re.sub(r"B[0-9A-F]{23}, ", "", source)
paths = sorted((ROOT / "macos/Sources/Core").glob("*.swift")) + sorted((ROOT / "macos/CoreTests").glob("*.swift"))
for index, path in enumerate(paths):
    reference, build = f"B{index:023X}", f"C{index:023X}"
    references.append(reference)
    builds.append(build)
    entries += [f'  {reference} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path.relative_to(ROOT / "macos")}; sourceTree = "<group>";}};',
                f"  {build} = {{isa = PBXBuildFile; fileRef = {reference};}};"]
source = source.replace(" objects = {", " objects = {\n" + "\n".join(entries))
source = source.replace("children = (A00000000000000000000005,", "children = (" + ", ".join(references) + ", A00000000000000000000005,")
source = re.sub(r"(D00000000000000000000003 = \{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = )\([^)]*\)",
                lambda match: match[1] + "(" + ", ".join(builds) + ")", source)
project.write_text(source)

# Native application: no test target depends on it, so `test` never starts it.
source = re.sub(r"^  [789][0-9A-F]{23} = .*\n", "", source, flags=re.M)
source = re.sub(r"[789][0-9A-F]{23}, ", "", source)
entries, references, builds = [], [], []
paths = sorted((ROOT / "macos/Sources").rglob("*.swift")) + [ROOT / "native/src/AppBridge.mm"]
for index, path in enumerate(paths):
    reference, build = f"7{index:023X}", f"8{index:023X}"
    relative = path.relative_to(ROOT).as_posix()
    relative = relative[len("macos/"):] if relative.startswith("macos/") else "../" + relative
    file_type = "sourcecode.cpp.objcpp" if path.suffix == ".mm" else "sourcecode.swift"
    references.append(reference); builds.append(build)
    entries += [f'  {reference} = {{isa = PBXFileReference; lastKnownFileType = {file_type}; path = "{relative}"; sourceTree = "<group>";}};',
                f"  {build} = {{isa = PBXBuildFile; fileRef = {reference};}};"]
entries += [
    '  900000000000000000000001 = {isa = PBXNativeTarget; buildConfigurationList = 900000000000000000000002; buildPhases = (900000000000000000000003, 900000000000000000000004, 900000000000000000000008); buildRules = (); dependencies = (); name = VueVPN; productName = VueVPN; productReference = 900000000000000000000005; productType = "com.apple.product-type.application";};',
    '  900000000000000000000002 = {isa = XCConfigurationList; buildConfigurations = (900000000000000000000006, 900000000000000000000007); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;};',
    '  900000000000000000000003 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ', '.join(builds) + '); runOnlyForDeploymentPostprocessing = 0;};',
    '  900000000000000000000004 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;};',
    '  900000000000000000000005 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = VueVPN.app; sourceTree = BUILT_PRODUCTS_DIR;};',
    '  900000000000000000000008 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (90000000000000000000000A, 90000000000000000000000C); runOnlyForDeploymentPostprocessing = 0;};',
    '  900000000000000000000009 = {isa = PBXFileReference; lastKnownFileType = image.icns; path = Resources/VueVPN.icns; sourceTree = "<group>";};',
    '  90000000000000000000000A = {isa = PBXBuildFile; fileRef = 900000000000000000000009;};',
    '  90000000000000000000000B = {isa = PBXFileReference; lastKnownFileType = folder; path = Resources/ThirdPartyLicenses; sourceTree = "<group>";};',
    '  90000000000000000000000C = {isa = PBXBuildFile; fileRef = 90000000000000000000000B;};',
]
settings = ('PRODUCT_BUNDLE_IDENTIFIER = com.vuevpn.desktop; PRODUCT_NAME = VueVPN; '
            'INFOPLIST_FILE = Info.plist; GENERATE_INFOPLIST_FILE = NO; CODE_SIGNING_ALLOWED = NO; '
            'SWIFT_OBJC_BRIDGING_HEADER = Sources/Bridge/AppBridge.h; '
            'HEADER_SEARCH_PATHS = "$(SRCROOT)/../native/include"; CLANG_ENABLE_OBJC_ARC = YES; '
            'CLANG_CXX_LANGUAGE_STANDARD = "c++17"; '
            'OTHER_LDFLAGS = ("$(inherited)", "-framework", AppKit, "-framework", Security, '
            '"-framework", ServiceManagement, "-framework", LocalAuthentication); '
            'LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";')
for identifier, name, optimization in [(6, "Debug", "-Onone"), (7, "Release", "-O")]:
    entries.append(f'  90000000000000000000000{identifier} = {{isa = XCBuildConfiguration; buildSettings = {{{settings} SWIFT_OPTIMIZATION_LEVEL = "{optimization}";}}; name = {name};}};')
source = source.replace(" objects = {", " objects = {\n" + "\n".join(entries))
source = source.replace("targets = (", "targets = (900000000000000000000001, ")
source = source.replace("children = (A00000000000000000000006,", "children = (900000000000000000000005, A00000000000000000000006,")
source = source.replace("A00000000000000000000030,", "A00000000000000000000030, " + ", ".join(references) + ", 900000000000000000000009, 90000000000000000000000B,")
project.write_text(source)

# UI sources are compiled by the hostless visual target, including the AppKit
# adapters. Their constructors do not install a menu item or open a window.
source = re.sub(r"^  [EF][0-9A-F]{23} = .*\n", "", source, flags=re.M)
source = re.sub(r"E[0-9A-F]{23}, ", "", source)
entries, references, builds = [], [], []
paths = (sorted((ROOT / "macos/Sources/UI").glob("*.swift")) + sorted((ROOT / "macos/Sources/Core").glob("*.swift"))
         + [p for p in sorted((ROOT / "macos/VisualTests").glob("*.swift")) if p.name != "OffscreenTests.swift"])
for index, path in enumerate(p for p in paths if p.name != "VisualPrimitives.swift"):
    reference, build = f"E{index:023X}", f"F{index:023X}"
    references.append(reference)
    builds.append(build)
    entries += [f'  {reference} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path.relative_to(ROOT / "macos")}; sourceTree = "<group>";}};',
                f"  {build} = {{isa = PBXBuildFile; fileRef = {reference};}};"]
source = source.replace(" objects = {", " objects = {\n" + "\n".join(entries))
source = source.replace("A00000000000000000000030,", "A00000000000000000000030, " + ", ".join(references) + ",")
source = re.sub(r"(A00000000000000000000012 = \{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = )\([^)]*\)",
                lambda match: match[1] + "(A00000000000000000000008, A00000000000000000000031, " + ", ".join(builds) + ")", source)
project.write_text(source)
