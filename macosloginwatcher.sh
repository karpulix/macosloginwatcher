#!/bin/bash

# Более безопасная обработка ошибок
set -o pipefail
trap 'echo "Error on line $LINENO"' ERR

# Add at the beginning after other variables
VERSION="1.0.32"

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

# Function to validate script path
validate_script_path() {
    local script_path="$1"
    if [ ! -f "$script_path" ] || [ ! -x "$script_path" ]; then
        log_message "Invalid script path: $script_path" "$CONFIG_DIR/error.log"
        return 1
    fi
    return 0
}

# Function to escape XML special characters
escape_xml() {
    local string="$1"
    string="${string//&/&amp;}"
    string="${string//</&lt;}"
    string="${string//>/&gt;}"
    string="${string//\"/&quot;}"
    string="${string//\'/&apos;}"
    echo "$string"
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
    
    # Validate script path
    if ! validate_script_path "$SCRIPT_PATH"; then
        echo "Error: Invalid script path"
        return 1
    fi
    
    # Generate new process ID
    PROCESS_IDENTIFIER="macosloginwatcher_$(openssl rand -hex 8)"
    
    # Escape special characters in paths
    ESCAPED_SCRIPT_PATH=$(escape_xml "$SCRIPT_PATH")
    ESCAPED_CONFIG_DIR=$(escape_xml "$CONFIG_DIR")
    
    cat > "$LAUNCH_AGENT_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.macosloginwatcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>$ESCAPED_SCRIPT_PATH</string>
        <string>--process-id=$PROCESS_IDENTIFIER</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardErrorPath</key>
    <string>$ESCAPED_CONFIG_DIR/error.log</string>
    <key>StandardOutPath</key>
    <string>$ESCAPED_CONFIG_DIR/output.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$ESCAPED_CONFIG_DIR</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>ExitTimeOut</key>
    <integer>10</integer>
</dict>
</plist>
EOF

    # Set secure permissions
    chmod 644 "$LAUNCH_AGENT_FILE"
    
    # Unload if already loaded
    launchctl unload "$LAUNCH_AGENT_FILE" 2>/dev/null || true
    
    # Wait a bit to ensure the service is unloaded
    sleep 2
    
    # Load the new configuration
    if ! launchctl load "$LAUNCH_AGENT_FILE"; then
        log_message "Failed to load LaunchAgent" "$CONFIG_DIR/error.log"
        return 1
    fi
    
    # Start the process immediately
    if ! launchctl start com.macosloginwatcher; then
        log_message "Failed to start process" "$CONFIG_DIR/error.log"
        return 1
    fi
    
    log_message "LaunchAgent setup completed and started" "$CONFIG_DIR/output.log"
    
    # Get current user and timestamp for manual startup message
    user=$(get_current_user) || {
        log_message "Failed to get current user" "$CONFIG_DIR/error.log"
        return 1
    }
    timestamp=$(get_timestamp)
    
    startup_message="🚀 MacOSLoginWatcher started (manual) by $user at $timestamp"
    # Send to Telegram
    if ! send_telegram_message "$startup_message"; then
        log_message "Failed to send startup notification" "$CONFIG_DIR/error.log"
        return 1
    fi
    
    return 0
}

# Function to remove autostart
remove_autostart() {
    if [ -f "$LAUNCH_AGENT_FILE" ]; then
        # Unload the service first
        launchctl unload "$LAUNCH_AGENT_FILE" 2>/dev/null || true
        
        # Wait a bit to ensure the service is unloaded
        sleep 2
        
        # Remove the file
        rm -f "$LAUNCH_AGENT_FILE"
        
        # Verify removal
        if [ -f "$LAUNCH_AGENT_FILE" ]; then
            log_message "Failed to remove LaunchAgent file" "$CONFIG_DIR/error.log"
            return 1
        fi
    fi
    return 0
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

# Function to handle process termination
handle_termination() {
    local pid
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ "$pid" = "$$" ]; then
            rm -f "$PID_FILE"
        fi
    fi
    # Kill any child processes
    pkill -P $$ 2>/dev/null || true
    exit 0
}

# Function to check if process is already running
check_running_process() {
    local process_id="$1"
    # Check PID file first
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && ps -p "$pid" > /dev/null 2>&1; then
            log_message "Process already running with PID: $pid" "$CONFIG_DIR/error.log"
            return 1
        fi
    fi
    
    # Check for other instances
    if pgrep -f "macosloginwatcher.*--process-id" | grep -v "$$" > /dev/null; then
        log_message "Another instance is already running" "$CONFIG_DIR/error.log"
        return 1
    fi
    return 0
}

# Register termination handler
trap handle_termination SIGTERM SIGINT

# Add this check before other if statements
if [ "$1" = "--version" ]; then
    echo "macosloginwatcher version $VERSION"
    exit 0
fi

# Function to send Telegram message with error handling
send_telegram_message() {
    local message="$1"
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$message" \
        -d "parse_mode=HTML" 2>&1)
    
    if [ $? -ne 0 ]; then
        log_message "Failed to send Telegram message: $response" "$CONFIG_DIR/error.log"
        return 1
    fi
    return 0
}

# Function to get current user with error handling
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

# Function to set secure permissions
set_secure_permissions() {
    chmod 700 "$CONFIG_DIR" 2>/dev/null || true
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    chmod 600 "$PRIVILEGES_FILE" 2>/dev/null || true
    chmod 600 "$PID_FILE" 2>/dev/null || true
}

# Main script logic
if [ "$1" = "--process-id" ]; then
    # This is a child process, no need to request admin privileges
    PROCESS_IDENTIFIER="$2"
    if [ -z "$PROCESS_IDENTIFIER" ]; then
        echo "Error: Process ID is required"
        exit 1
    fi
    
    # Check if process is already running
    if ! check_running_process "$PROCESS_IDENTIFIER"; then
        exit 1
    fi
    
    # Save PID
    echo "$$" > "$PID_FILE"
    
    # Load configuration
    if ! load_config; then
        log_message "Error: Configuration not found. Please run 'macosloginwatcher --setup' first" "$CONFIG_DIR/error.log"
        rm -f "$PID_FILE"
        exit 1
    fi
    
    # Validate configuration
    if ! validate_config; then
        log_message "Error: Invalid configuration" "$CONFIG_DIR/error.log"
        rm -f "$PID_FILE"
        exit 1
    fi
    
    # Create config directory if it doesn't exist
    create_config_dir
    
    # Set secure permissions
    set_secure_permissions
    
    # Check and rotate logs
    check_and_rotate_logs
    
    # Send startup notification
    timestamp=$(get_timestamp)
    user=$(get_current_user) || {
        rm -f "$PID_FILE"
        exit 1
    }
    startup_message="🚀 MacOSLoginWatcher started (autostart) by $user at $timestamp"
    
    # Send to Telegram
    if ! send_telegram_message "$startup_message"; then
        log_message "Failed to send startup notification" "$CONFIG_DIR/error.log"
        rm -f "$PID_FILE"
        exit 1
    fi
    
    # Start monitoring login events
    log stream --style syslog --predicate 'eventMessage CONTAINS "CA sending unlock success to dispatch"' 2>> "$CONFIG_DIR/error.log" | while read -r line; do
        if [[ "$line" != *"com.apple.loginwindow.logging:Standard"* ]]; then
            continue
        fi

        # Extract date (1st and 2nd fields)
        timestamp=$(get_timestamp)
        user=$(get_current_user) || continue
        message="🔓 Mac unlocked by $user at $timestamp"

        # Send to Telegram
        if ! send_telegram_message "$message"; then
            log_message "Failed to send unlock notification" "$CONFIG_DIR/error.log"
        fi
    done
    
    # Cleanup on exit
    rm -f "$PID_FILE"
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
    
    # Create config directory if it doesn't exist
    create_config_dir
    
    # Check if config exists
    if [ -f "$CONFIG_FILE" ]; then
        # Load existing config
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
    
    # Set secure permissions
    set_secure_permissions
    
    # Ask about autostart
    read -p "Do you want to enable autostart on system login? (yes/no): " AUTOSTART
    if [[ "$AUTOSTART" =~ ^[Yy][Ee][Ss]$ ]]; then
        # Stop any existing instances first
        if [ -f "$PID_FILE" ]; then
            local pid=$(cat "$PID_FILE" 2>/dev/null)
            if [ -n "$pid" ]; then
                kill "$pid" 2>/dev/null || true
            fi
            rm -f "$PID_FILE"
        fi
        pkill -f "macosloginwatcher.*--process-id" || true
        
        if ! setup_autostart; then
            echo "Error: Failed to setup autostart"
            exit 1
        fi
        echo "Autostart has been enabled and process started!"
    fi
    
    exit 0
fi

if [ "$1" = "--disable" ]; then
    # First show and kill running processes
    echo "Found running macosloginwatcher processes:"
    ps aux | grep macosloginwatcher | grep -v grep || echo "No running processes found"
    
    # Kill processes and remove PID file
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
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
    
    # Check if process is already running
    if ! check_running_process "$PROCESS_IDENTIFIER"; then
        echo "Another instance is already running"
        exit 1
    fi
    
    # Start a new instance with the process ID
    "$0" --process-id "$PROCESS_IDENTIFIER" &
    exit 0
fi
