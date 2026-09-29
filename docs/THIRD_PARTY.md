# Third-party components

VueVPN embeds OpenVPN 3 Core release/3.11.7, commit
`18edfae7e7fd8051c93bd4746ec69be91eb02dbb`. It does not invoke or bundle
the OpenVPN command-line client. The upstream repository contains the
applicable MPL-2.0 / AGPL-3.0 with OpenSSL exception license texts.
The packaging script includes those upstream license files.

Native dependencies used by this personal build:

- OpenVPN 3 Core — OpenVPN, Inc.; see included upstream licenses.
- OpenSSL — Apache License 2.0.
- standalone Asio — Boost Software License 1.0.
- LZ4 — BSD 2-Clause license (library).

The application UI uses Apple's AppKit, CoreGraphics, CoreText and CoreImage
frameworks, with Swift and an Objective-C++ bridge. Vue, Tauri and their
JavaScript/Rust dependencies have been removed.

Native SVG arc and shadow rendering math is adapted from WebKit. Copyright
notices and the applicable LGPL-2 and BSD terms are included in
`macos/Resources/ThirdPartyLicenses/WebKit.txt` and `COPYING.LIB`, copied into
the application resources. This does not link or embed a WebKit UI/runtime.

Frozen test PNGs were produced from this project's previous UI; they are test
inputs only and are not bundled with the application.
