#!/bin/sh
# Emergency release when the RPC helper is unavailable. Never disable global PF.
set -eu
umask 077
[ "$(id -u)" -eq 0 ]
sfm_root='/Library/Application Support/SFMRoutes'
sfm_state="$sfm_root/State"
sfm_plist='/Library/LaunchDaemons/io.github.tier777.sfmroutes.engine.plist'
for sfm_path in "$sfm_root" "$sfm_state" "$sfm_plist" "$sfm_state/leak-protection.json" "$sfm_state/leak-protection.json.tmp" "$sfm_state/leak-protection-profile.json" "$sfm_state/pf-token"; do
    [ ! -L "$sfm_path" ] || { echo 'Unsafe recovery path' >&2; exit 1; }
done
[ -d "$sfm_state" ] && [ "$(/usr/bin/stat -f %u "$sfm_state")" -eq 0 ]
sfm_restore_service() {
    if [ -f "$sfm_plist" ]; then /bin/launchctl bootstrap system "$sfm_plist" 2>/dev/null || true; fi
}
trap sfm_restore_service EXIT
if /bin/launchctl print system/io.github.tier777.sfmroutes.engine >/dev/null 2>&1; then
    /bin/launchctl bootout system "$sfm_plist"
fi
/sbin/pfctl -a com.apple/050.SFMRoutes -F rules
/bin/cat > "$sfm_state/leak-protection.json.tmp" <<'EOF'
{"enabled":false,"armed":false}
EOF
/bin/chmod 600 "$sfm_state/leak-protection.json.tmp"
/bin/mv "$sfm_state/leak-protection.json.tmp" "$sfm_state/leak-protection.json"
/bin/rm -f "$sfm_state/leak-protection-profile.json"
if [ -f "$sfm_state/pf-token" ]; then
    sfm_token=$(/bin/cat "$sfm_state/pf-token")
    case "$sfm_token" in ''|*[!0-9]*) echo 'Invalid saved PF reference' >&2; exit 1;; esac
    /sbin/pfctl -X "$sfm_token" 2>/dev/null || true
    /bin/rm "$sfm_state/pf-token"
fi
echo SFM_PLUS_OK
