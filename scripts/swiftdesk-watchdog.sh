#!/usr/bin/env bash
# Keeps SwiftDesk running on an unattended Host: a per-user LaunchAgent checks every minute and reopens the app if it
# is not running. SwiftDesk itself starts listening on launch when "Start listening when SwiftDesk opens" is on.
#
#   swiftdesk-watchdog.sh install     # install + load the LaunchAgent (runs at login and every INTERVAL_SECONDS)
#   swiftdesk-watchdog.sh uninstall   # unload + remove it
#   swiftdesk-watchdog.sh status | once | daemon
#
# A LaunchAgent (not a LaunchDaemon) on purpose: screen capture and input injection need the logged-in GUI session.
set -euo pipefail

SWIFTDESK_APP="${SWIFTDESK_APP:-/Applications/SwiftDesk.app}"
LOG_FILE="${HOME}/Library/Logs/swiftdesk-watchdog.log"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"
PLIST_LABEL="com.swiftdesk.watchdog"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCRIPT_PATH="${HOME}/scripts/swiftdesk-watchdog.sh"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG_FILE"
}

is_running() {
  pgrep -f "${SWIFTDESK_APP}/Contents/MacOS/SwiftDesk" >/dev/null 2>&1
}

launch_swiftdesk() {
  if [[ ! -d "$SWIFTDESK_APP" ]]; then
    log "ERROR: SwiftDesk not found at ${SWIFTDESK_APP}"
    exit 1
  fi
  # -g: do not bring it to the front over whatever the user is doing.
  open -g "$SWIFTDESK_APP"
  log "Launched SwiftDesk"
}

check_and_launch() {
  if is_running; then
    return
  fi
  log "SwiftDesk is not running, launching..."
  launch_swiftdesk
}

run_daemon() {
  log "Watchdog daemon started (interval: ${INTERVAL_SECONDS}s)"
  while true; do
    check_and_launch
    sleep "$INTERVAL_SECONDS"
  done
}

install_launch_agent() {
  mkdir -p "${HOME}/Library/LaunchAgents" "${HOME}/scripts" "$(dirname "$LOG_FILE")"
  if [[ "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" != "$SCRIPT_PATH" ]]; then
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
  fi

  cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_PATH}</string>
    <string>once</string>
  </array>
  <key>StartInterval</key>
  <integer>${INTERVAL_SECONDS}</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  launchctl enable "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true

  log "Installed LaunchAgent (${PLIST_PATH})"
  echo "Installed. SwiftDesk will be checked every ${INTERVAL_SECONDS} seconds."
  echo "Log: ${LOG_FILE}"
}

uninstall_launch_agent() {
  launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  log "Removed LaunchAgent"
  echo "Uninstalled swiftdesk watchdog."
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  once        Check once and launch SwiftDesk if needed (default)
  daemon      Run loop in foreground, check every ${INTERVAL_SECONDS} seconds
  install     Install macOS LaunchAgent (recommended)
  uninstall   Remove LaunchAgent
  status      Show whether SwiftDesk is running
EOF
}

case "${1:-once}" in
  once) check_and_launch ;;
  daemon) run_daemon ;;
  install) install_launch_agent ;;
  uninstall) uninstall_launch_agent ;;
  status)
    if is_running; then echo "SwiftDesk is running"; else echo "SwiftDesk is not running"; fi
    ;;
  -h | --help | help) usage ;;
  *)
    usage
    exit 1
    ;;
esac
