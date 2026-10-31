# SFM+

Local macOS arm64 fork of SFM 1.14.3 with separate, fresh route-health checks.
The regular Network Extension targets remain in the upstream project. The
`LOCAL_ENGINE` build uses an administrator-installed CLI process instead, so
local installation does not need a paid Apple Developer account or VPN
provisioning profile. It is ad-hoc signed, not a notarized public release.

## Behavior

- Every configured outbound/endpoint gets its own status. Successful HTTPS,
  timestamp, latency and optional Cloudflare exit IP/country are shown separately
  from the engine's lifecycle. HTTP 403 proves transport, not access to a site.
- Sleep, unavailable network, stale telemetry, reconnection, authentication and
  terminal endpoint failures take priority over a previous successful check.
  No-traffic idle time is not treated as an outage.
- Probes dial exactly the selected outbound, use normal TLS verification, and
  never fall back to another outbound or DIRECT. Probe success does not certify
  the routing policy of a different application or make protection permanent.
- Work endpoints require an explicitly chosen internal HTTPS test address.
- Tailscale login/path tools and per-outbound throughput tests are accessible
  from the route panel. Throughput tests run only on demand.
- Fortinet SMS forms preserve hidden session fields, carry the authenticated
  username when omitted, and accept visible text/number/tel OTP input. Real
  gateway sessions still require login and each server-requested OTP.

## Protected Tailscale exit selection

In SFM+, open the Tailscale connection → **Вход и путь до узла…** → **Exit Node**.
Only online, unexpired exit candidates are selectable; the local build has no
"Disabled" choice. An active kill switch and a responsive, matching helper are
required. Selection saves `exit_node: "id:<stable-peer-id>"` in the local profile
and reloads the VPN under protection. Existing engine sockets close; there is
no automatic rollback to the old exit if the replacement fails. Other routing
rules and endpoint credentials remain unchanged.

The core accepts both the original IP/name form and the stable identity form.
A configured exit cannot be changed/disabled using the legacy live preference
RPC; it requires profile replacement. Internet dials and raw TUN packets are
checked against the live peer routing source used by WireGuard: until the
configured peer identity is resolved and that peer carries the destination,
they are rejected/dropped. Tailnet peer addresses remain allowed inside Tailscale.
There is no DIRECT or another VPN alternative. This source-level behavior and
failure cases have local tests; actual switching on the Mac still requires a
live test after installation, without Claude/Anthropic requests.

## Leak protection

On by default (Settings › VPN, or Overview › Routing). The first profile start
arms protection. Stopping VPN by hand keeps it armed; only the separate
**Kill switch** toggle releases it. Enabling that toggle while VPN is stopped
blocks immediately. The pf anchor `com.apple/050.SFMRoutes` allows TCP/UDP
from the controlling user's processes and `_mdnsresponder` through the actual
TUN device owned by this engine, plus the on-link local network. The root
engine remains able to reach its servers and honor DIRECT rules such as `.ru`.

Before stop, reload or profile replacement, blocking rules are loaded before
the old tunnel is removed. The periodic reconciler cannot undo that transition.
The allowed device comes from the running TUN instance, never a coincidentally
matching IP on another VPN. If device identification fails, traffic stays blocked.
Pass rules create no floating PF states; first arming clears pre-existing states
originating from this Mac's concrete interface addresses. This can reconnect
existing sockets. Other hosts' states are not flushed.

The rules outlast a helper crash. At boot/restart the root helper restores the
block before restoring a previously active profile. A deliberate stop clears
the remembered profile, so helper restart keeps blocking without reconnecting.
There is a boot window before the helper starts; this is not a macOS managed
Always On VPN. Other accounts and root/system daemons are outside the guard.
LAN stays available; with VPN stopped, ordinary DNS/DoT ports are blocked even
to LAN resolvers. With VPN running a LAN resolver can still see DNS queries.

The policy blocks external VPN interfaces, including a separate FortiClient.
The personal setup instead has one saved profile and an optional **Рабочий VPN ·
Fortinet** switch. It is off by default. With it off, the app produces a runtime
configuration with no OpenConnect client; work traffic and work DNS rules reject
in place, ahead of `.ru` and the default route. Dependent selectors are removed,
including selectors containing DIRECT, so disabled work never chooses an alternative.
The saved profile remains intact. With it on, the original endpoint and strict
work rules are restored, and the user completes Fortinet password/SMS authentication.
No work password or session cookie is stored in the staged profile. Toggling this
module reloads the complete profile; active leak protection covers that interruption.
If the helper's state is unknown, the UI refuses to report a successful toggle.

Application launch at login uses native `SMAppService`, is registered on first
launch, and has a separate Settings toggle. At login SFM+ connects the selected
profile if the helper is not already running it.

The main window shows **Интернет заблокирован** when no allowed tunnel exists.
Use the VPN switch to reconnect, or **Отключить kill switch** to release the block.
Settings also provides **Аварийно отключить kill switch…** if the service cannot
answer: after macOS administrator authorization it stops this helper, removes
only its own anchor and PF reference, persists protection as disabled and restarts
the helper idle. It never disables global PF or flushes another tool's rules.
The installer parses both rule modes using `pfctl -n` before replacing a helper;
a parse failure leaves the old service running. Existing nonempty global PF
rules without the Apple attachment anchor are refused, not overwritten.

## Local installation

Open **SFM+.app**, press **Настроить локальный движок** and complete the
standard macOS administrator prompt. The installer creates an **idle** helper;
it does not start a tunnel, change DNS/routes, or stop other VPN apps. Start a
profile explicitly. Existing SFM is a separate application and data store.
Do not activate overlapping TUN profiles until you are ready to switch clients.

The helper is copied into `/Library/Application Support/SFMRoutes/engine` and
registered as `io.github.tier777.sfmroutes.engine`. Its private state directory
is root-owned, mode 0700. A root-owned 0711 directory under `/var/run` contains
a 0600 Unix control socket owned by the installing user. That user's processes
can control profiles. The helper accepts a restricted JSON configuration:
TUN, DIRECT/Hysteria(2)/HTTP/SOCKS/Shadowsocks/selectors, and
Tailscale/OpenConnect/WireGuard endpoints. Executable services, SSH servers,
root file paths, NTP clock changes and public management listeners are disabled.
The cache uses default helper-local storage; Tailscale `state_directory` must
be one simple basename. All privileged upstream security features are denied.

User profiles/database live in `~/Library/Application Support/SFMRoutes/User`
with a separate Tailscale identity in helper storage. A new identity may require
Tailscale browser login. No credentials or personal profiles ship in the app
bundle or source repository.

To uninstall the engine, run the bundled `uninstall-local-engine.sh` with
administrator privileges. It stops the helper and removes its executable and
launch daemon, preserving profiles and Tailscale state. No SIP or global
Gatekeeper changes are needed by the build. macOS may require an explicit
Open action for a locally built, unnotarized app.

## Build

Use the matching `feature/leak-protection` core branch in
https://github.com/tier777/sing-box with this app's `feature/redesign-leak-protection`
branch. The SFM+ implementation pairs with core commit
[`c23b4f4d`](https://github.com/tier777/sing-box/commit/c23b4f4d970415d46b37a50b99c23155e0a217df).
Core's go.mod pins the
OTP fix from https://github.com/tier777/sing-openconnect. Xcode/Go dependencies
follow upstream. Build Libbox for macOS arm64 with upstream `build_libbox`, then
symlink its `Libbox.xcframework` into this repository.

```sh
GOMAXPROCS=2 go run ./cmd/internal/build_libbox -target apple -platform macos/arm64
```

Build the CLI from the same core checkout:

```sh
GOMAXPROCS=2 go build -trimpath \
  -tags 'with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_openconnect,with_dhcp,with_tailscale,ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird,badlinkname,tfogo_checklinkname0' \
  -ldflags '-s -w -checklinkname=0' -o sfm-route-engine ./cmd/sfm-route-engine
```

In this checkout, generate the standalone project (it strips extension/widget
and legacy-helper embedding without modifying upstream targets), build, package:

```sh
python3 Tools/prepare-local-project.py
DISABLE_SWIFTLINT=1 xcodebuild -project .sfm-local.xcodeproj -scheme SFM.System \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -jobs 2 \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG LOCAL_ENGINE' \
  BASE_PACKAGE_IDENTIFIER=io.github.tier777.sfmroutes \
  APP_GROUP_IDENTIFIER=LOCAL.io.github.tier777.sfmroutes build
sh Tools/package-local-app.sh build/Build/Products/Debug/SFM.app \
  /path/to/sfm-route-engine /path/to/SFM-Routes.app
```

## Validation and remaining live checks

Swift state-machine tests cover freshness, lifecycle/auth precedence and safe
protobuf defaults. Go tests cover explicit-outbound HTTPS/TLS/error behavior,
root-profile restrictions, and isolated helper IDLE/start/rejected replacement/
wake deduplication/stop via its Unix socket. OTP parser tests cover 40 variants.
The helper test deliberately contains no TUN or remote authentication.

Live TUN routing, close-lid recovery and actual Fortinet SMS completion still
need a user-controlled activation on the Mac. The helper has an app wake signal
and a deduplicated wall-clock-gap fallback, not a guarantee against every sleep
or network fault. Zero-success probes remain visibly unverified.

No throughput claim is made: an internal userspace Tailscale stack can add
processing, and `detour` configures its dialer/HTTP client, so TCP relay/control
paths can travel through another proxy. UDP peer paths can differ. Compare
per-route measurements and direct/DERP ping before changing transport settings.
SSID matching is unavailable in the current local CLI backend: upstream macOS
uses a stub Wi-Fi monitor without the Network Extension adapter. The unified
personal profile does not depend on SSID detection and always pins work addresses
to Fortinet while its optional module is enabled.
