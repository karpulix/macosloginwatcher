#!/bin/bash

# Более безопасная обработка ошибок
set -o pipefail
trap 'echo "Error on line $LINENO"' ERR

# Add at the beginning after other variables
VERSION="1.0.29"

CONFIG_DIR="$HOME/.config/macosloginwatcher"
CONFIG_FILE="$CONFIG_DIR/config"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_FILE="$LAUNCH_AGENT_DIR/com.macosloginwatcher.plist"
PROCESS_IDENTIFIER="macosloginwatcher_$(openssl rand -hex 8)"
PRIVILEGES_FILE="$CONFIG_DIR/.privileges_granted"
PID_FILE="$CONFIG_DIR/.pid"
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

# Function to request admin privileges
request_admin_privileges() {
    # Check if we're already running as root
    if [ "$(id -u)" = "0" ]; then
        return 0
    fi
    
    # Check if we're running in a terminal
    if [ -t 1 ]; then
        # Request admin privileges using osascript
        osascript -e "do shell script \"$0 $*\" with administrator privileges" >/dev/null 2>&1
        return $?
    else
        # If not in terminal, just return success
        return 0
    fi
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
    
    # Generate new process ID
    PROCESS_IDENTIFIER="macosloginwatcher_$(openssl rand -hex 8)"
    
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
    <false/>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/error.log</string>
    <key>StandardOutPath</key>
    <string>$CONFIG_DIR/output.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$CONFIG_DIR</string>
</dict>
</plist>
EOF

    # Unload if already loaded
    launchctl unload "$LAUNCH_AGENT_FILE" 2>/dev/null || true
    
    # Load the new configuration
    launchctl load "$LAUNCH_AGENT_FILE"
    
    # Start the process immediately
    launchctl start com.macosloginwatcher
    
    log_message "LaunchAgent setup completed and started" "$CONFIG_DIR/output.log"
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
    # Проверяем, есть ли другой процесс с таким же ID
    if pgrep -f "$process_id" | grep -v "$$" > /dev/null; then
        log_message "Another instance is already running with process ID: $process_id" "$CONFIG_DIR/error.log"
        return 1
    fi
    return 0
}

# Function to cleanup on exit
cleanup() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ "$pid" = "$$" ]; then
            rm -f "$PID_FILE"
        fi
    fi
}

# Register cleanup function
trap cleanup EXIT

# Add this check before other if statements
if [ "$1" = "--version" ]; then
    echo "macosloginwatcher version $VERSION"
    exit 0
fi

# Main script logic
if [ "$1" = "--process-id" ]; then
    # This is a child process, no need to request admin privileges
    PROCESS_IDENTIFIER="$2"
    if [ -z "$PROCESS_IDENTIFIER" ]; then
        echo "Error: Process ID is required"
        exit 1
    fi
    
    # Check if another instance is running
    if pgrep -f "macosloginwatcher.*$PROCESS_IDENTIFIER" | grep -v "$$" > /dev/null; then
        echo "Another instance is already running"
        exit 1
    fi
    
    # Start monitoring
    monitor_login_activity
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
        echo "Autostart has been enabled and process started!"
    fi
    
    exit 0
fi

if [ "$1" = "--disable" ]; then
    # First show and kill running processes
    echo "Found running macosloginwatcher processes:"
    ps aux | grep macosloginwatcher | grep -v grep || echo "No running processes found"
    pkill -f "macosloginwatcher" || true
    
    # Then remove autostart and privileges file
    remove_autostart
    rm -f "$PRIVILEGES_FILE"
    echo "Autostart has been disabled, running instances have been stopped, and privileges have been revoked!"
    
    exit 0
fi

# If no arguments provided, start as a child process
if [ $# -eq 0 ]; then
    # Generate a unique process ID
    PROCESS_IDENTIFIER="macosloginwatcher_$(openssl rand -hex 8)"
    
    # Start a new instance with the process ID
    "$0" --process-id "$PROCESS_IDENTIFIER" &
    exit 0
fi
