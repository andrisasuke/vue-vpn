# Embedded Core patches

`scripts/native.py prepare` applies these patches to the pinned OpenVPN Core
release/3.11.7 commit. Already-applied patches are accepted; conflicts stop the
build. Keep patches tracked here because `vendor/` is ignored.

`0001-validate-remote-endpoints.patch`:

- Makes a numeric remote immediately available without system resolution, also
  after cache reset/reconnect. Preserves the configured transport family, port,
  and Core's multiple-remote selection.
- Returns whether resolver results provide a usable endpoint. UDP and TCP record
  a `RESOLVE_ERROR` statistic and report retryable `TRANSPORT_ERROR` if a successful
  lookup yields no compatible addresses, instead of throwing
  `current remote server endpoint is undefined`. The connection controller does
  not support `RESOLVE_ERROR` as a fatal transport code, so use its existing
  transport-error event and VueVPN's bounded retry policy.
- Leaves hostname lookup and selection of compatible DNS answers with Core.

The regression tests use in-memory endpoint lists, including empty, IPv6-only,
and mixed answers. IPv6-only resolver output reproduces the reported exception
in the unpatched Core; it does not establish what the user's system resolver
actually returned. No system DNS lookup or VPN connection is used by these tests.

The patch modifies OpenVPN source under the license in each upstream file.
