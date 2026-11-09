# VueVPN user guide

Detailed application behavior and user-run troubleshooting. For setup and build commands, see the README.

[Back to README](../README.md)

## Running a packaged build

1. Copy `artifacts/VueVPN.app` to `/Applications`.
2. Open the app manually. Choose **App settings → Enable VPN helper**.
3. If prompted, allow VueVPN in **System Settings → General → Login Items & Extensions**, then click **Refresh status**.
4. Import a development `.ovpn` profile. Select it, review its subnets, and click **Connect to VPN**.
5. Enter your PIN/password. For an imported username/password profile without a username, enter both values on its first connection; the username is saved with the profile. Select **Remember on this Mac** to save only the password after a successful connection.

This local build targets **macOS 26.0+ arm64**, matching the native dependencies available on the build machine. The helper uses APIs available from macOS 13, but the local OpenSSL binaries require macOS 26. Supporting older macOS versions requires rebuilding native dependencies for the intended deployment target.

Closing the window hides it. The app and VPN keep running through the menu bar.
**Quit VueVPN** cleans up connections before exiting. Opening the app does not
automatically connect any profile.

## Appearance and interaction

Choose **App settings → Appearance → Light / Dark / System**. The default,
**System**, follows macOS appearance changes immediately. Light and Dark retain
the selected theme when the system appearance changes. The preference is saved
for the app, applies to every profile, and requires no restart or VPN reconnect.

Dark uses a deep green palette. Inputs, dialogs, diagrams, statistics, and toast
messages follow the app theme; native menus and the menu bar follow macOS.
Clickable controls use a pointing-hand cursor, disabled controls use an arrow,
and text inputs use an I-beam. Standard menus and window controls retain their
native macOS behavior.

Connection animations use Core Animation layers without a timer redrawing the
entire Overview every frame. Traffic and duration values update separately,
about once per second. Workspace rendering pauses when the window is hidden,
minimized, fully occluded, or covered by a dialog; menu-bar controls and VPN
connections remain active. Animation also pauses when its illustration scrolls
out of view. Low Power Mode retains normal animation, while Reduce Motion is
respected.

## System Stats

The sidebar's **Stats** section opens CPU, RAM, SSD, and Network pages with
distinct chip, memory-module, drive, and globe icons. Four compact menu-bar
controls show RAM, SSD, Network download/upload, and CPU readings in one native
Stats item. The four controls cannot be dragged or reordered separately in
macOS; the VPN item remains separate.
In Label style, RAM, SSD, and CPU align each small label with the left edge of its percentage; Network stacks
direction-labelled download and upload rates with units. Each metric keeps
its compact width as readings change; exceptionally high rates display as
`999+GB/s`. Clicking
one restores the existing VueVPN window on that page. Stats works with no VPN
connection and with the VPN helper disabled. The original VPN icon and menu
remain separate. Each Stats page has a **Show in menu bar** checkbox for its
own metric; all four are shown by default, and choices persist across restarts.
Each page also has an independent **Menu bar style: Label / Icon** choice, saved across restarts and available while hidden. Label is the default; Icon shows the value beside a green metric icon (Network keeps both rate rows beside a globe). Fixed columns keep icons steady as values change; Icon values align by their visible right edge close to the icon. Menu-bar colors follow the status item appearance independently of the window theme.
Hiding an item frees its menu-bar space while readings and history continue in
the app. Each page also has an independent **Enable monitoring** setting,
on by default and saved across restarts. Turning it off stops that domain's
Stats collection and related process or network work, hides its tray metric,
and shows a disabled state on its still-accessible page. It preserves the
separate visibility and style choices for when monitoring resumes. With all
four off, the Stats polling timer stops. VPN connections and their own polling
are independent of these controls. The sidebar scrolls when profiles extend past the window.
Switching Stats pages or hiding the window keeps the latest aggregate menu-bar
readings until the next sample; genuinely unavailable readings still show an
em dash.

Each page starts with a live summary: CPU, RAM, and SSD use a composition ring and bar with their values in the card; Network shows download and upload rates. The five-minute history and distinct details remain below. Unavailable or inconsistent compositions use a neutral track. The charts update immediately without motion; Low Power Mode changes sampling cadence as described below.

CPU shows total/system/user/idle percentages, available per-core and E/P group
readings, uptime, load averages, a five-minute chart, and accessible processes.
Live CPU frequency is **Unavailable** on Apple Silicon without a supported
public API. RAM shows pressure, App/Wired/Compressed/Free memory, swap, history,
and processes. SSD shows the internal macOS filesystem's actual available space
and used percentage, read/write rates when its driver exposes counters, history,
and processes. Reclaimable space is shown only when a reliable estimate exists;
it is never treated as already free. Disk process I/O is system-wide, not scoped
to the selected filesystem.

Network follows the active physical Wi-Fi or Ethernet interface. Use the
**Interface** control to cycle through automatic selection and available physical
interfaces. Its rates and application-session totals come from the selected
interface; VPN tunnel bytes are not added. Totals count traffic observed while
Network monitoring is enabled, are retained per interface when switching or
temporarily disabling monitoring, and reset when the app restarts. Local addresses and hardware
address appear when available; Wi-Fi name/SSID is not read. Process network I/O
is system-wide and cannot be attributed to the selected interface.

Public IPv4/IPv6 uses normal OS routing, so it describes the current routed
egress, including VPN changes. VueVPN requests plain address text over HTTPS
from `api4.ipify.org` and `api6.ipify.org` at monitoring start, physical-link or
VPN-context changes, and when **Refresh public IP** is clicked. It does not poll
these providers periodically or send profile data. The page labels pending,
stale, unavailable, and failed lookups and shows the last successful update.
Connectivity checks a configurable target, initially `1.1.1.1`, using TCP port
443 every five seconds only while Network is visible. Three failures mean that
target is unreachable; they do not establish that every internet destination is
down. Hidden periods are marked unmonitored.

Lightweight aggregate readings share one schedule: about one second normally,
two seconds in Low Power Mode. Visible-page process lists update about every
three or five seconds respectively. SSD capacity updates every 30 seconds.
Sleep/display sleep pauses collection; wake resets rate baselines. Resuming a
disabled domain also starts with fresh rate baselines and marks a gap in its
bounded history. All chart history lasts at most five minutes in memory and is cleared on quit. Low Power
Mode changes only Stats sampling; VPN animation keeps its existing behavior.
Some hardware or protected-process readings may show **Unavailable**. Actual
energy use and hardware accuracy must be checked manually on the target Mac.

## Updating the app

Quit the old VueVPN app, replace `/Applications/VueVPN.app` with the new
`artifacts/VueVPN.app`, and reopen it. **Routine updates do not require disabling
and re-enabling the helper**, including upgrades from versions without helper
version detection.

The app compares the signed helper executable's fingerprint in the bundle with
the running helper's fingerprint over XPC. If they differ, it waits for all VPN
connections to disconnect, unregisters the service, waits for macOS to confirm
that the old process has stopped, and registers it again. New connections are
allowed after the new helper's fingerprint is verified. UI-only changes with an
unchanged helper executable do not restart the helper.

When a VPN is active, **update pending** is shown and connections continue until
the user disconnects. **Disconnect all and update** is available in App settings.
Profiles and PINs stored in Keychain are preserved. Grant approval in System
Settings if macOS requests it. A deliberately disabled helper is not enabled
automatically. Wait for an update to finish before quitting.

A **not found** status with a complete bundle is treated as a registration that
needs recovery: the app checks the signed executable and plist, then attempts
automatic registration. After the previous helper stops, registration continues
with a fresh SMAppService instance. Temporary registration failures are retried
up to three times with delays; the status remains **updating** until the helper's
fingerprint is verified. A helper deliberately left unregistered still requires
Enable, unless registration was lost during an update or the user selects Retry.

Disconnect sends an asynchronous signal to the engine, including during sleep
or network changes. Core stops its event loop after shutdown so pending work
cannot keep `connect()` running indefinitely. The transport closes before its
bypass routes are released. If Disconnecting lasts 30 seconds, the app shows
**Disconnect stalled** and **Retry disconnect**. A timeout does not count as
success: session/route ownership is retained, replacement connections are
rejected, and helper updates wait for cleanup. Retry does not restart the helper
or disconnect other profiles.

Persistent update failures offer **Retry helper update**, which resumes
registration without requiring another Enable click. Unregister/register retries
are bounded. An unreachable helper is not stopped immediately because the app
cannot yet confirm the state of its connections. Bundle detection applies only
to a complete, signed `.app`; an unsigned compilation is not a ready-to-use
bundle and must not be used for live VPN testing.

## Profiles and routing

- Pritunl profiles with a client certificate/key and `password_mode: pin` use a PIN and the username from profile metadata. Standard `auth-user-pass` profiles without a client certificate/key are also supported, including profiles with inline CA and `tls-auth`. If an imported username/password profile has no username, its first Connect asks for a username and password; afterward, Connect asks only for a password unless it is remembered. The username is stored with the profile and can be changed in **Edit profile**. A client certificate and key must be supplied together; explicit client-certificate requirements remain in effect.
- Profiles containing `route-nopull` and explicit routes start in **Selected networks** mode. Other profiles start in **All IPv4 traffic** mode.
- The editor accepts prefixes (`24`, `/24`) or subnet masks (`255.255.255.0`). Addresses are normalized to network addresses.
- Only one full IPv4 tunnel can be active. Other split-tunnel profiles may run concurrently if their subnets and DNS domains do not overlap.
- The backend supports IPv4 DNS and stored domain suffixes; empty settings use server-provided values. In Selected networks mode, automatic DNS without a domain suffix is ignored, retaining system DNS without adding routes to VPN resolvers. Internal hostnames require a stored or server-provided suffix; manually configured DNS without a suffix is rejected. Resolver IPs in use are also routed through the VPN. Internal DNS controls are temporarily hidden from Overview and Profile settings. Editing a profile preserves stored DNS settings, and backend handling of server-provided DNS remains active. All IPv4 mode can use server DNS without requiring a suffix.
- Server-pushed routes do not select the routing mode: VueVPN's settings determine it.
- Saving network changes to an active profile reconnects only that profile.
- IPv6 is neither modified nor blocked. A full tunnel covers **IPv4**, except for VPN transport, local/peer interface addresses, and more-specific local-network routes owned by macOS. There is no kill switch.
- Ordinary connection failures allow five retries with 2/4/8/16/30-second backoff. Offline/sleep states pause attempts. Network changes and temporary network errors reset the counter, so waiting for network recovery is not limited to five total attempts. Authentication, certificate, and configuration errors stop retries.
- Profiles with legacy compression framing, including `comp-lzo no`, use receive-only compatibility mode. VueVPN does not compress outgoing data but can receive compressed data from these servers. Profiles without compression directives retain mode `no`; `allow-compression no` is always respected.

## Local data

Profiles are stored in `~/Library/Application Support/com.vuevpn.desktop/profiles`,
with directory permissions `0700` and file permissions `0600`. Referenced
certificate/key files are imported inline without changing the originals.
Pritunl synchronization metadata is not stored. Passwords are never written to
JSON or logs. Appearance preferences use UserDefaults, separately from Keychain
credentials.

Remembered passwords use macOS Keychain service
`com.vuevpn.desktop.credentials`. **Forget password** removes them. Passwords
rejected by the server are deleted so the next connection requests credentials
again. Without the remember option, credentials are retained only in memory for
reconnections within the current session.

The helper runs separately with administrator privileges. XPC communication
requires matching signing identifiers and Team IDs in both directions, as well
as the active console user. The UI does not run as root. The helper accepts
neither shell commands nor file paths from the UI; profiles are restricted to
supported inline configuration.

## Troubleshooting a stalled disconnect

If **Disconnect stalled** appears, choose **Retry disconnect**. The session is
not considered complete, and helper updates remain deferred until cleanup is
confirmed. If the error persists, record the Activity message and sample the
helper while it is still stuck:

```sh
rtk proxy sudo sample vuevpn-helper 5 10 -file /tmp/vuevpn-helper-disconnect.txt
```

Sampling only records thread activity. For an older helper version that is
already stuck, the user can perform a one-time service restart:

```sh
rtk proxy sudo launchctl kickstart -k system/com.vuevpn.helper
```

This disconnects **all VueVPN sessions**, including other profiles. It is a
manual recovery action, not part of routine builds, tests, or updates. Once the
helper responds again, quit the old app, replace it with the new build, and open
it manually. If recovery fails, retain the diagnostics for investigation. Do not
bulk-delete routes or delete the ownership journal.

## Support limits

Supported: IPv4 TUN with inline client certificate/key authentication (optionally with PIN/password), or username/password authentication without a client certificate.
TAP, external PKI, encrypted private keys, OTP/dynamic challenges, SSO, device
authentication, Pritunl dynamic firewall, scripts/plugins, proxies, and chained
external configurations are not supported. Specific errors are reported during
import or native validation before connecting.

## Uninstalling

Choose **App settings → Disable helper and disconnect all**, then Quit. Delete
`/Applications/VueVPN.app` afterward. Remove profiles through the UI first if you
also want their Keychain credentials deleted; original `.ovpn` files are
preserved. The helper's route journal at
`/var/run/com.vuevpn.helper/routes.json` stores route ownership only, without
credentials.

If route cleanup fails, the app reports an error and does not claim cleanup has
finished. Complete cleanup or helper recovery before deleting the app; see the
troubleshooting section above.
