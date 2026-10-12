#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ]
sfm_plist='/Library/LaunchDaemons/io.github.tier777.sfmroutes.engine.plist'
if [ -f "$sfm_plist" ]; then
    /bin/launchctl bootout system "$sfm_plist" 2>/dev/null || true
    /bin/rm "$sfm_plist"
fi
# Preserve user profiles and Tailscale login state.
if [ -f '/Library/Application Support/SFMRoutes/engine' ]; then /bin/rm '/Library/Application Support/SFMRoutes/engine'; fi
