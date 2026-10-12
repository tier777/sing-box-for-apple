# SFM Routes

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

## Leak protection

On by default (Settings › VPN, or Overview › Routing). Starting a profile arms
it; only switching the VPN off by hand disarms it. While armed, a pf anchor
`com.apple/050.SFMRoutes` lets the controlling user's processes and
`_mdnsresponder` send TCP/UDP only through the engine's own TUN interface and
the on-link local network (DHCP, link-local, multicast, the Wi-Fi subnet).
The root engine is not restricted, so it keeps reaching its servers and the
DIRECT outbound for `.ru` and other direct rules.

Engine failure, reload, profile switch, sleep/wake and a helper crash or
reinstall all keep it armed: without a live tunnel the user's traffic and DNS
are blocked instead of falling back to Wi-Fi or another VPN (for example the
regular Tailscale or FortiClient apps, whose `utun` interfaces are never
allowed). The rules live in the kernel, so they outlast the helper; a
restarted helper re-applies the block and restores the last armed profile
from its root-only state directory. The window shows "Интернет приостановлен"
with a button to switch the VPN off.

Limits: it does not cover other macOS user accounts or root/system daemons,
traffic before the helper starts at boot, or DNS names the system resolver
sends to a router on the local network while the tunnel is up (connections
still go through the tunnel). `uninstall-local-engine.sh` removes the anchor
and the pf reference.

## Local installation

Open **SFM Routes.app**, press **Настроить локальный движок** and complete the
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

Use the matching `feature/connection-health` core branch in
https://github.com/tier777/sing-box and this app branch. Core's go.mod pins the
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
uses a stub Wi-Fi monitor without the Network Extension adapter. Use separate
office/outside-office profiles to switch both routing and work DNS explicitly.
