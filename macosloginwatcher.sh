#!/bin/bash

# Более безопасная обработка ошибок
set -o pipefail
trap 'echo "Error on line $LINENO"' ERR

# Add at the beginning after other variables
VERSION="1.0.20"

CONFIG_DIR="$HOME/.config/macosloginwatcher"
CONFIG_FILE="$CONFIG_DIR/config"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_FILE="$LAUNCH_AGENT_DIR/com.macosloginwatcher.plist"
PROCESS_IDENTIFIER="macosloginwatcher_$(openssl rand -hex 8)"
PRIVILEGES_FILE="$CONFIG_DIR/.privileges_granted"
MAX_LOG_SIZE=$((5 * 1024 * 1024))  # 5MB in bytes
MAX_LOG_FILES=5  # Keep 5 rotated log files

# Function to get formatted timestamp
get_timestamp() {
    date "+%Y-%m-%d %H:%M:%S.%N %z" | sed 's/\([0-9]\{6\}\)[0-9]*/\1/' | sed 's/+//'
}

# Function to log messages with timestamp
log_message() {
    local message="$1"
    local log_file="$2"
    echo "$(get_timestamp) $message" >> "$log_file"
}

# Function to rotate logs
rotate_logs() {
    local log_file="$1"
    local max_size="$2"
    local max_files="$3"
    
    # Check if log file exists and is larger than max size
    if [ -f "$log_file" ] && [ $(stat -f%z "$log_file") -gt "$max_size" ]; then
        # Rotate existing log files
        for ((i=max_files-1; i>=0; i--)); do
            if [ $i -eq 0 ]; then
                # Move current log to .1
                mv "$log_file" "${log_file}.1" 2>/dev/null || true
            else
                # Move older logs
                mv "${log_file}.$i" "${log_file}.$((i+1))" 2>/dev/null || true
            fi
        done
        
        # Create new empty log file
        touch "$log_file"
    fi
}

# Function to check and rotate logs
check_and_rotate_logs() {
    rotate_logs "$CONFIG_DIR/error.log" "$MAX_LOG_SIZE" "$MAX_LOG_FILES"
    rotate_logs "$CONFIG_DIR/output.log" "$MAX_LOG_SIZE" "$MAX_LOG_FILES"
}

# Function to request admin privileges using osascript
request_admin_privileges() {
    if [ ! -f "$PRIVILEGES_FILE" ]; then
        log_message "Requesting admin privileges..." "$CONFIG_DIR/output.log"
        osascript -e 'do shell script "echo \"Requesting admin privileges...\"" with administrator privileges' >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            touch "$PRIVILEGES_FILE"
            log_message "Admin privileges granted" "$CONFIG_DIR/output.log"
            return 0
        fi
        log_message "Failed to obtain admin privileges" "$CONFIG_DIR/error.log"
        return 1
    fi
    return 0
}

# Function to check if we have admin privileges
check_admin_privileges() {
    # If running as a LaunchAgent, we need to request privileges each time
    if [[ "$*" == *"--process-id="* ]]; then
        osascript -e 'do shell script "echo \"Requesting admin privileges...\"" with administrator privileges' >/dev/null 2>&1
        return $?
    fi
    
    # For manual runs, check the privileges file
    if [ ! -f "$PRIVILEGES_FILE" ]; then
        echo "Error: This script requires administrator privileges"
        echo "Please run 'macosloginwatcher --setup' first to grant the necessary permissions"
        exit 1
    fi
    return 0
}

# Function to create config directory if it doesn't exist
create_config_dir() {
    mkdir -p "$CONFIG_DIR"
}

# Function to save configuration
save_config() {
    create_config_dir
    echo "BOT_TOKEN=$1" > "$CONFIG_FILE"
    echo "CHAT_ID=$2" >> "$CONFIG_FILE"
}

# Function to load configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        return 1
    fi
}

# Function to setup autostart
setup_autostart() {
    mkdir -p "$LAUNCH_AGENT_DIR"
    
    # Try to find the script in PATH first (for Homebrew installation)
    SCRIPT_PATH=$(which macosloginwatcher 2>/dev/null)
    
    # If not found in PATH, use the current script path
    if [ -z "$SCRIPT_PATH" ]; then
        SCRIPT_PATH=$(realpath "$0")
    fi
    
    cat > "$LAUNCH_AGENT_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.macosloginwatcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_PATH</string>
        <string>--process-id=$PROCESS_IDENTIFIER</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/error.log</string>
    <key>StandardOutPath</key>
    <string>$CONFIG_DIR/output.log</string>
</dict>
</plist>
EOF

    launchctl load "$LAUNCH_AGENT_FILE"
}

# Function to remove autostart
remove_autostart() {
    if [ -f "$LAUNCH_AGENT_FILE" ]; then
        launchctl unload "$LAUNCH_AGENT_FILE"
        rm "$LAUNCH_AGENT_FILE"
    fi
}

# Функция для проверки sudo прав
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo "Error: This script requires sudo privileges"
        exit 1
    fi
}

# Функция для проверки запуска процесса
check_process_started() {
    local pid=$1
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if ps -p $pid > /dev/null; then
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

# Функция для валидации конфигурации
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

# Function to check if process is already running
check_running_process() {
    local process_id="$1"
    local count=$(ps aux | grep -v grep | grep -c "$process_id")
    if [ "$count" -gt 1 ]; then
        log_message "Another instance is already running with process ID: $process_id" "$CONFIG_DIR/error.log"
        return 1
    fi
    return 0
}

# Add this check before other if statements
if [ "$1" = "--version" ]; then
    echo "macosloginwatcher version $VERSION"
    exit 0
fi

# Setup wizard
if [ "$1" = "--setup" ]; then
    echo "Welcome to macosloginwatcher Setup Wizard"
    echo "----------------------------------------"
    
    # Request admin privileges during setup
    if ! request_admin_privileges; then
        echo "Error: Failed to obtain administrator privileges"
        echo "Please run the script again and grant the requested permissions"
        exit 1
    fi
    
    # Check if config exists
    if [ -f "$CONFIG_FILE" ]; then
        # Load existing config
        source "$CONFIG_FILE"
        echo "Current configuration found:"
        echo "BOT_TOKEN: ${BOT_TOKEN:0:4}...${BOT_TOKEN: -4}"
        echo "CHAT_ID: $CHAT_ID"
        
        read -p "Do you want to change the configuration? (yes/no): " CHANGE_CONFIG
        if [[ ! "$CHANGE_CONFIG" =~ ^[Yy][Ee][Ss]$ ]]; then
            echo "Keeping existing configuration."
        else
            # Ask for new BOT_TOKEN
            read -p "Please enter your Telegram Bot Token: " BOT_TOKEN
            while [ -z "$BOT_TOKEN" ]; do
                read -p "Bot Token cannot be empty. Please enter your Telegram Bot Token: " BOT_TOKEN
            done
            
            # Ask for new CHAT_ID
            read -p "Please enter your Telegram Chat ID: " CHAT_ID
            while [ -z "$CHAT_ID" ]; do
                read -p "Chat ID cannot be empty. Please enter your Telegram Chat ID: " CHAT_ID
            done
            
            # Save new configuration
            save_config "$BOT_TOKEN" "$CHAT_ID"
            echo "Configuration updated successfully!"
        fi
    else
        # No existing config, ask for new values
        # Ask for BOT_TOKEN
        read -p "Please enter your Telegram Bot Token: " BOT_TOKEN
        while [ -z "$BOT_TOKEN" ]; do
            read -p "Bot Token cannot be empty. Please enter your Telegram Bot Token: " BOT_TOKEN
        done
        
        # Ask for CHAT_ID
        read -p "Please enter your Telegram Chat ID: " CHAT_ID
        while [ -z "$CHAT_ID" ]; do
            read -p "Chat ID cannot be empty. Please enter your Telegram Chat ID: " CHAT_ID
        done
        
        # Save configuration
        save_config "$BOT_TOKEN" "$CHAT_ID"
        echo "Configuration saved successfully!"
    fi
    
    # Ask about autostart
    read -p "Do you want to enable autostart on system login? (yes/no): " AUTOSTART
    if [[ "$AUTOSTART" =~ ^[Yy][Ee][Ss]$ ]]; then
        setup_autostart
        echo "Autostart has been enabled!"
        echo "Starting the process..."
        launchctl start com.macosloginwatcher
    fi
    
    exit 0
fi

if [ "$1" = "--disable" ]; then
    # First show and kill running processes
    echo "Found running macosloginwatcher processes:"
    ps aux | grep "macosloginwatcher" | grep -v grep || echo "No running processes found"
    pkill -f "macosloginwatcher" || true
    
    # Then remove autostart and privileges file
    remove_autostart
    rm -f "$PRIVILEGES_FILE"
    echo "Autostart has been disabled, running instances have been stopped, and privileges have been revoked!"
    
    exit 0
fi

# Main script execution
if [ "$1" = "--process-id" ]; then
    PROCESS_ID="$2"
    
    # Check if another instance is already running
    if ! check_running_process "$PROCESS_ID"; then
        exit 1
    fi
    
    # Load configuration
    if ! load_config; then
        log_message "Error: Configuration not found. Please run 'macosloginwatcher --setup' first" "$CONFIG_DIR/error.log"
        exit 1
    fi
    
    # Validate configuration
    if ! validate_config; then
        log_message "Error: Invalid configuration" "$CONFIG_DIR/error.log"
        exit 1
    fi
    
    # Check admin privileges
    if ! check_admin_privileges "$@"; then
        log_message "Error: Failed to obtain administrator privileges" "$CONFIG_DIR/error.log"
        exit 1
    fi
    
    # Create config directory if it doesn't exist
    create_config_dir
    
    # Check and rotate logs
    check_and_rotate_logs
    
    # Send startup notification
    timestamp=$(date "+%Y-%m-%d %H:%M:%S.%N %z" | sed 's/\([0-9]\{6\}\)[0-9]*/\1/' | sed 's/+//')
    user=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ {print $3}')
    startup_message="🚀 MacOSLoginWatcher started by $user at $timestamp"
    
    # Print to console
    # echo "[$timestamp] $startup_message"
    
    # Send to Telegram
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$startup_message" \
        -d "parse_mode=HTML" > /dev/null
    
    # Start monitoring
    while true; do
        # Get current user
        current_user=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ {print $3}')
        
        # If user is logged in
        if [ ! -z "$current_user" ]; then
            # Get login time
            login_time=$(last "$current_user" | head -n 1 | awk '{print $4, $5, $6, $7}')
            
            # Get IP address
            ip_address=$(curl -s https://api.ipify.org)
            
            # Get location
            location=$(curl -s "https://ipapi.co/$ip_address/json/" | jq -r '.city + ", " + .country_name')
            
            # Format message
            message="🔔 <b>New Login Detected</b>\n\n👤 User: $current_user\n⏰ Time: $login_time\n🌐 IP: $ip_address\n📍 Location: $location"
            
            # Send to Telegram
            curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                -d "chat_id=$CHAT_ID" \
                -d "text=$message" \
                -d "parse_mode=HTML" > /dev/null
            
            # Wait for 5 minutes before checking again
            sleep 300
        else
            # Wait for 1 minute before checking again
            sleep 60
        fi
    done
fi
