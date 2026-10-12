#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ]
sfm_plist='/Library/LaunchDaemons/io.github.tier777.sfmroutes.engine.plist'
sfm_state='/Library/Application Support/SFMRoutes/State'
if [ -f "$sfm_plist" ]; then
    /bin/launchctl bootout system "$sfm_plist" 2>/dev/null || true
    /bin/rm "$sfm_plist"
fi
# Leak protection rules outlive the helper by design; remove them with it.
/sbin/pfctl -a com.apple/050.SFMRoutes -F rules 2>/dev/null || true
if [ -f "$sfm_state/pf-token" ] && [ ! -L "$sfm_state/pf-token" ]; then
    sfm_token=$(/usr/bin/tr -cd '0-9' < "$sfm_state/pf-token")
    [ -z "$sfm_token" ] || /sbin/pfctl -X "$sfm_token" 2>/dev/null || true
    /bin/rm "$sfm_state/pf-token"
fi
for sfm_file in leak-protection.json leak-protection-profile.json; do
    if [ -f "$sfm_state/$sfm_file" ] && [ ! -L "$sfm_state/$sfm_file" ]; then /bin/rm "$sfm_state/$sfm_file"; fi
done
# Preserve user profiles and Tailscale login state.
if [ -f '/Library/Application Support/SFMRoutes/engine' ]; then /bin/rm '/Library/Application Support/SFMRoutes/engine'; fi
