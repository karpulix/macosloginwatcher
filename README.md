# MacOSLoginWatcher

A macOS daemon that monitors system login events and sends notifications to Telegram when the system is unlocked.

## Features

- 🔔 Sends Telegram notifications when your Mac is unlocked
- 🚀 Sends startup notification when the service starts
- 🔄 Automatically retries sending messages if internet is not available
- 📝 Maintains detailed logs of all events
- 🔒 Secure configuration storage
- ⚡ Runs as a system daemon
- 🛠️ Easy installation and setup

## Installation

### Using Homebrew

```bash

brew tap karpulix/homebrew-tools
brew install karpulix/homebrew-tools/macosloginwatcher

```

### Manual Installation

1. Download the latest release from the [releases page](https://github.com/karpulix/macosloginwatcher/releases)
2. Make the script executable:
   ```bash
   chmod +x macosloginwatcher.sh
   ```
3. Move it to a directory in your PATH:
   ```bash
   sudo mv macosloginwatcher.sh /usr/local/bin/macosloginwatcher
   ```

## Setup

1. Create a Telegram bot using [@BotFather](https://t.me/BotFather) and get the bot token
2. Get your Telegram chat ID (you can use [@userinfobot](https://t.me/userinfobot))
3. Run the setup wizard:
   ```bash
   sudo macosloginwatcher --setup
   ```
4. Follow the prompts to enter your bot token and chat ID

## Usage

### Start the Service

```bash
sudo macosloginwatcher --start
```

### Stop the Service

```bash
sudo macosloginwatcher --stop
```

### Check Version

```bash
macosloginwatcher --version
```

## Configuration

The configuration is stored in `~/.config/macosloginwatcher/config` (you need root privileges for access) with the following format:
```
BOT_TOKEN=your_bot_token
CHAT_ID=your_chat_id
```

## Logs

Logs are stored in `~/.config/macosloginwatcher/`:
- `output.log` - Contains successful operations
- `error.log` - Contains error messages

Logs are automatically rotated when they reach 5MB in size, with a maximum of 5 log files.

## Features in Detail

### Telegram Notifications

- 🔓 Unlock notifications: Sent when your Mac is unlocked
- 🚀 Startup notifications: Sent when the service starts
- 🔄 Automatic retry: If internet is not available, the service will retry sending messages up to 30 times with 10-second intervals

### Security

- Configuration files are stored with restricted permissions (600)
- The daemon runs as root to ensure proper system access
- All sensitive information is stored in the user's home directory

### Logging

- Detailed timestamps for all events
- Automatic log rotation
- Separate logs for successful operations and errors
- Maximum log size: 5MB
- Maximum number of log files: 5

## Troubleshooting

If you're having issues:

1. Check the logs:
   ```bash
   sudo cat ~/.config/macosloginwatcher/error.log
   sudo cat ~/.config/macosloginwatcher/output.log
   ```

2. Verify the service is running:
   ```bash
   ps aux | grep macosloginwatcher | grep -v grep
   ```
   Note: You should see two processes - the main daemon and a child process for message handling.

3. Check the LaunchDaemon status:
   ```bash
   sudo launchctl list | grep macosloginwatcher
   ```
   Note: Status 0 is normal - it means the daemon successfully started and spawned its child process.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details. 