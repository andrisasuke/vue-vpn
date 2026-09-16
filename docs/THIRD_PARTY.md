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

Application dependencies include Vue (MIT), Tauri (MIT or Apache-2.0),
and their transitive dependencies. Exact versions are recorded in
`package-lock.json` and `src-tauri/Cargo.lock`.

This build is intended for private use. Review the complete dependency
license obligations before any redistribution.
