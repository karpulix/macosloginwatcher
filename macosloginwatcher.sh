#!/bin/bash

# Error handling
set -o pipefail
trap 'echo "Error on line $LINENO"' ERR

# Version
VERSION="1.1.2"

# Get script path
if [[ -L "$0" ]]; then
    # If script is a symlink, resolve it
    SCRIPT_PATH=$(readlink "$0")
    if [[ "$SCRIPT_PATH" != /* ]]; then
        # If the symlink is relative, resolve it relative to the symlink's directory
        SCRIPT_PATH="$(dirname "$0")/$SCRIPT_PATH"
    fi
else
    SCRIPT_PATH="$0"
fi

# Get absolute path
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"

# Configuration paths
CONFIG_DIR="$HOME/.config/macosloginwatcher"
CONFIG_FILE="$CONFIG_DIR/config"
LAUNCH_DAEMON_DIR="/Library/LaunchDaemons"
LAUNCH_DAEMON_FILE="$LAUNCH_DAEMON_DIR/com.macosloginwatcher.plist"
PID_FILE="$CONFIG_DIR/.pid"
MAX_LOG_SIZE=$((5 * 1024 * 1024))  # 5MB
MAX_LOG_FILES=5

# Helper functions
get_timestamp() {
    date "+%Y-%m-%d %H:%M:%S.%N %z" | sed 's/\([0-9]\{6\}\)[0-9]*/\1/' | sed 's/+//'
}

log_message() {
    local message="$1"
    local log_file="$2"
    echo "$(get_timestamp) $message" >> "$log_file"
}

rotate_logs() {
    local log_file="$1"
    local max_size="$2"
    local max_files="$3"
    
    if [ -f "$log_file" ] && [ $(stat -f%z "$log_file") -gt "$max_size" ]; then
        for ((i=max_files-1; i>=0; i--)); do
            if [ $i -eq 0 ]; then
                mv "$log_file" "${log_file}.1" 2>/dev/null || true
            else
                mv "${log_file}.$i" "${log_file}.$((i+1))" 2>/dev/null || true
            fi
        done
        touch "$log_file"
    fi
}

check_and_rotate_logs() {
    rotate_logs "$CONFIG_DIR/error.log" "$MAX_LOG_SIZE" "$MAX_LOG_FILES"
    rotate_logs "$CONFIG_DIR/output.log" "$MAX_LOG_SIZE" "$MAX_LOG_FILES"
}

create_config_dir() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
}

save_config() {
    create_config_dir
    echo "BOT_TOKEN=$1" > "$CONFIG_FILE"
    echo "CHAT_ID=$2" >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

validate_config() {
    if [[ ! "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        echo "Error: Invalid BOT_TOKEN format"
        return 1
    fi
    if [[ ! "$CHAT_ID" =~ ^-?[0-9]+$ ]]; then
        echo "Error: Invalid CHAT_ID format"
        return 1
    fi
    return 0
}

send_telegram_message() {
    local message="$1"
    local max_attempts=30  # Maximum number of attempts
    local attempt=1
    local delay=10  # Delay between attempts in seconds
    
    # Function to check internet connectivity
    check_internet() {
        ping -c 1 api.telegram.org >/dev/null 2>&1
        return $?
    }
    
    # Function to send message
    send_message() {
        local response
        response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d "chat_id=$CHAT_ID" \
            -d "text=$message" \
            -d "parse_mode=HTML" 2>&1)
        
        if [ $? -eq 0 ]; then
            return 0
        fi
        return 1
    }
    
    # Start sending in background
    (
        while [ $attempt -le $max_attempts ]; do
            if check_internet; then
                if send_message; then
                    log_message "Message sent successfully after $attempt attempts" "$CONFIG_DIR/output.log"
                    exit 0
                fi
            fi
            
            log_message "Attempt $attempt: Waiting for internet connectivity..." "$CONFIG_DIR/output.log"
            sleep $delay
            attempt=$((attempt + 1))
        done
        
        log_message "Failed to send message after $max_attempts attempts" "$CONFIG_DIR/error.log"
    ) &
    
    return 0
}

get_current_user() {
    local user
    user=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ {print $3}' 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$user" ]; then
        log_message "Failed to get current user" "$CONFIG_DIR/error.log"
        return 1
    fi
    echo "$user"
    return 0
}

setup_launch_agent() {
    # Create LaunchDaemon plist
    cat > "$LAUNCH_DAEMON_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.macosloginwatcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_PATH</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/error.log</string>
    <key>StandardOutPath</key>
    <string>$CONFIG_DIR/output.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$CONFIG_DIR</string>
    <key>UserName</key>
    <string>root</string>
    <key>GroupName</key>
    <string>wheel</string>
</dict>
</plist>
EOF

    # Set proper permissions for LaunchDaemon
    chmod 644 "$LAUNCH_DAEMON_FILE"
    chown root:wheel "$LAUNCH_DAEMON_FILE"
    
    # Create config directory with proper permissions
    create_config_dir
    
    # Unload if already loaded
    sudo launchctl unload "$LAUNCH_DAEMON_FILE" 2>/dev/null || true
    sleep 2
    
    # Load and start the daemon
    if ! sudo launchctl load "$LAUNCH_DAEMON_FILE"; then
        echo "Error: Failed to load LaunchDaemon"
        return 1
    fi
    
    sleep 1
    
    if ! sudo launchctl start com.macosloginwatcher; then
        echo "Error: Failed to start LaunchDaemon"
        return 1
    fi
    
    # Verify the daemon is running
    if ! pgrep -f "macosloginwatcher.*--daemon" > /dev/null; then
        echo "Error: Daemon failed to start"
        return 1
    fi
}

remove_launch_agent() {
    sudo launchctl unload "$LAUNCH_DAEMON_FILE" 2>/dev/null || true
    sudo rm -f "$LAUNCH_DAEMON_FILE"
}

run_daemon() {
    create_config_dir
    check_and_rotate_logs
    
    if ! load_config; then
        log_message "Error: Configuration not found" "$CONFIG_DIR/error.log"
        exit 1
    fi
    
    if ! validate_config; then
        log_message "Error: Invalid configuration" "$CONFIG_DIR/error.log"
        exit 1
    fi

    # Send startup notification
    timestamp=$(get_timestamp)
    hostname=$(hostname)
    message="🚀 MacOSLoginWatcher started on $hostname at $timestamp"
    if ! send_telegram_message "$message"; then
        log_message "Failed to send startup notification" "$CONFIG_DIR/error.log"
    fi
    
    log stream --style syslog --predicate 'eventMessage CONTAINS "CA sending unlock success to dispatch"' 2>> "$CONFIG_DIR/error.log" | while read -r line; do
        if [[ "$line" != *"com.apple.loginwindow.logging:Standard"* ]]; then
            continue
        fi

        timestamp=$(get_timestamp)
        user=$(get_current_user) || continue
        message="🔓 Mac unlocked by $user at $timestamp"

        if ! send_telegram_message "$message"; then
            log_message "Failed to send unlock notification" "$CONFIG_DIR/error.log"
        fi
    done
}

main() {
    case "${1:-}" in
        --version)
            echo "macosloginwatcher version $VERSION"
            ;;
            
        --setup)
            echo "Welcome to macosloginwatcher Setup Wizard"
            echo "----------------------------------------"
            
            # Check for root privileges
            if [ "$(id -u)" != "0" ]; then
                echo "Error: This script must be run as root for setup"
                echo "Please run: sudo macosloginwatcher --setup (or maybe: sudo $0 --setup)"
                exit 1
            fi
            
            create_config_dir
            
            if [ -f "$CONFIG_FILE" ]; then
                if ! load_config; then
                    echo "Error: Failed to load existing configuration"
                    exit 1
                fi
                
                echo "Current configuration found:"
                echo "BOT_TOKEN: ${BOT_TOKEN:0:4}...${BOT_TOKEN: -4}"
                echo "CHAT_ID: $CHAT_ID"
                
                read -p "Do you want to change the configuration? (yes/no): " CHANGE_CONFIG
                if [[ ! "$CHANGE_CONFIG" =~ ^[Yy][Ee][Ss]$ ]]; then
                    echo "Keeping existing configuration."
                    exit 0
                fi
            fi
            
            read -p "Please enter your Telegram Bot Token: " BOT_TOKEN
            while [ -z "$BOT_TOKEN" ]; do
                read -p "Bot Token cannot be empty. Please enter your Telegram Bot Token: " BOT_TOKEN
            done
            
            read -p "Please enter your Telegram Chat ID: " CHAT_ID
            while [ -z "$CHAT_ID" ]; do
                read -p "Chat ID cannot be empty. Please enter your Telegram Chat ID: " CHAT_ID
            done
            
            save_config "$BOT_TOKEN" "$CHAT_ID"
            echo "Configuration saved successfully!"
            echo "Use --start to start the service"
            echo "Use --stop to stop the service"

            ;;
            
        --start)
            if [ "$(id -u)" != "0" ]; then
                echo "Error: This script must be run as root"
                echo "Please run: sudo macosloginwatcher --start (or maybe: sudo $0 --start)"
                exit 1
            fi
            if ! setup_launch_agent; then
                echo "Error: Failed to start service (Did you run --setup?)"
                exit 1
            fi
            echo "Service started successfully!"
            ;;
            
        --stop)
            if [ "$(id -u)" != "0" ]; then
                echo "Error: This script must be run as root"
                echo "Please run: sudo macosloginwatcher --stop (or maybe: sudo $0 --stop)"
                exit 1
            fi
            remove_launch_agent
            echo "Service stopped successfully!"
            ;;
            
        --daemon)
            run_daemon
            ;;
            
        *)
            echo "Usage: $0 [--version|--setup|--start|--stop]"
            echo "  --version  Show version information"
            echo "  --setup    Run setup wizard (requires root)"
            echo "  --start    Start the service (requires root)"
            echo "  --stop     Stop the service (requires root)"
            exit 1
            ;;
    esac
}

main "$@"
