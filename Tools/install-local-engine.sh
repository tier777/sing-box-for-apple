#!/bin/sh
set -eu
umask 077
# Fresh installation starts idle. An armed helper update restores protection.
sfm_app_path=${1:?Missing app path}
sfm_user_id=${2:?Missing controller UID}
case "$sfm_user_id" in ''|*[!0-9]*) echo 'Invalid UID' >&2; exit 1;; esac
[ "$sfm_user_id" -gt 0 ]
[ "$(id -u)" -eq 0 ]
sfm_root='/Library/Application Support/SFMRoutes'
sfm_plist='/Library/LaunchDaemons/io.github.tier777.sfmroutes.engine.plist'
sfm_source="$sfm_app_path/Contents/Resources/sfm-route-engine"
[ -f "$sfm_source" ]
# Never follow a pre-existing symlink while running as root.
for sfm_path in "$sfm_root" "$sfm_root/State" "$sfm_root/engine" "$sfm_root/engine.new" "$sfm_root/engine.log" "$sfm_plist"; do
    [ ! -L "$sfm_path" ] || { echo 'Unsafe installation path' >&2; exit 1; }
done
for sfm_path in "$sfm_root" "$sfm_root/State"; do
    if [ -e "$sfm_path" ]; then
        [ -d "$sfm_path" ] && [ "$(/usr/bin/stat -f %u "$sfm_path")" -eq 0 ] || { echo 'Unsafe installation directory' >&2; exit 1; }
    fi
done
/bin/mkdir -p "$sfm_root/State"
/usr/sbin/chown root:wheel "$sfm_root" "$sfm_root/State"
/bin/chmod 755 "$sfm_root"
/bin/chmod 700 "$sfm_root/State"
/usr/bin/install -o root -g wheel -m 755 "$sfm_source" "$sfm_root/engine.new"
# Validate the actual macOS PF grammar before stopping the installed helper.
# -n only parses; it does not load rules or alter the live firewall.
if ! "$sfm_root/engine.new" --check-firewall --uid "$sfm_user_id"; then
    /bin/rm "$sfm_root/engine.new"
    echo 'SFM+ firewall validation failed; existing engine left running.' >&2
    exit 1
fi
if /bin/launchctl print system/io.github.tier777.sfmroutes.engine >/dev/null 2>&1; then
    # Do not replace the executable while an older helper could still answer
    # RPCs using the old stop/disarm semantics.
    /bin/launchctl bootout system "$sfm_plist"
fi
/bin/mv "$sfm_root/engine.new" "$sfm_root/engine"
/bin/cat > "$sfm_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>io.github.tier777.sfmroutes.engine</string>
<key>ProgramArguments</key><array><string>$sfm_root/engine</string><string>--uid</string><string>$sfm_user_id</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
<key>StandardOutPath</key><string>$sfm_root/engine.log</string>
<key>StandardErrorPath</key><string>$sfm_root/engine.log</string>
</dict></plist>
EOF
/usr/sbin/chown root:wheel "$sfm_plist"
/bin/chmod 644 "$sfm_plist"
/usr/bin/plutil -lint "$sfm_plist"
/bin/launchctl bootstrap system "$sfm_plist"
echo SFM_PLUS_OK
