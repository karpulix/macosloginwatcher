#!/bin/bash

set -euo pipefail

VERSION="1.0.33"

APP_NAME="macosloginwatcher"
CONFIG_DIR="$HOME/.config/$APP_NAME"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_FILE="$CONFIG_DIR/$APP_NAME.log"
PLIST_FILE="$HOME/Library/LaunchAgents/com.$APP_NAME.plist"

get_current_user() {
    id -un
}

check_admin_privileges() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "Root privileges are required. Requesting with sudo..."
        exec sudo --preserve-env=PATH "$0" "$@"
    fi
}

create_config_dir() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        BOT_TOKEN=$(grep '^BOT_TOKEN=' "$CONFIG_FILE" | cut -d= -f2-)
        CHAT_ID=$(grep '^CHAT_ID=' "$CONFIG_FILE" | cut -d= -f2-)
        PRIVILEGES_FILE=$(grep '^PRIVILEGES_FILE=' "$CONFIG_FILE" | cut -d= -f2-)
        [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" && -n "$PRIVILEGES_FILE" ]]
    else
        echo "Config file not found."
        return 1
    fi
}

check_and_rotate_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
    fi
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$message" \
        -o /dev/null
}

setup_autostart() {
    create_config_dir
    check_and_rotate_logs

    local plist_content="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple Computer//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>com.$APP_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$0</string>
        <string>--process-id=$(uuidgen)</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$CONFIG_DIR</string>
</dict>
</plist>"

    echo "$plist_content" > "$PLIST_FILE"
    chmod 644 "$PLIST_FILE"
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    launchctl load "$PLIST_FILE"
    echo "Autostart enabled."
}

remove_autostart() {
    if [[ -f "$PLIST_FILE" ]]; then
        launchctl unload "$PLIST_FILE" || true
        rm -f "$PLIST_FILE"
        echo "Autostart removed."
    else
        echo "No LaunchAgent to remove."
    fi
}

print_usage() {
    echo "Usage: $0 [--setup | --disable | --process-id=UUID]"
    exit 1
}

main() {
    case "${1:-}" in
        --setup)
            check_admin_privileges "$@"
            setup_autostart
            ;;

        --disable)
            check_admin_privileges "$@"
            remove_autostart
            ;;

        --process-id=*)
            if load_config; then
                check_admin_privileges "$@"
                check_and_rotate_logs
                local user
                user=$(get_current_user)
                local hostname
                hostname=$(scutil --get LocalHostName)
                local uuid="${1#--process-id=}"
                send_telegram_message "🔒 $APP_NAME: User $user logged in to $hostname [$uuid]"
            else
                echo "Failed to load config. Exiting."
                exit 1
            fi
            ;;

        *)
            print_usage
            ;;
    esac
}

main "$@"
