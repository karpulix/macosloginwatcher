# MacOSLoginWatcher

A macOS utility that monitors system login events and sends notifications to Telegram when your Mac is unlocked.

## Features

- Monitors system login events in real-time
- Sends notifications to Telegram when your Mac is unlocked
- Supports autostart on system login
- Easy setup and configuration
- Secure storage of Telegram credentials

## Installation

### Option 1: Direct Installation

1. Download the script:
```bash
curl -O https://raw.githubusercontent.com/karpulix/macosloginwatcher/main/macosloginwatcher.sh
```

2. Make it executable:
```bash
chmod +x macosloginwatcher.sh
```

3. Move it to a directory in your PATH (optional):
```bash
sudo mv macosloginwatcher.sh /usr/local/bin/macosloginwatcher
```

### Option 2: Homebrew Installation

1. Add the tap:
```bash
brew tap karpulix/homebrew-tools
```

2. Install the formula:
```bash
brew install karpulix/homebrew-tools/macosloginwatcher
```

## Setup

1. Create a Telegram Bot:
   - Open Telegram and search for "@BotFather"
   - Send `/newbot` command
   - Follow the instructions to create a new bot
   - Save the bot token provided by BotFather

2. Get your Telegram Chat ID:
   - Open Telegram and search for "@userinfobot"
   - Send any message to the bot
   - The bot will reply with your chat ID

3. Run the setup wizard:
```bash
macosloginwatcher --setup
```

4. Follow the prompts to:
   - Enter your Telegram Bot Token
   - Enter your Telegram Chat ID
   - Choose whether to enable autostart on system login
   - Choose whether to start the process immediately

## Usage

### Start Monitoring

The script will automatically start monitoring after setup if you chose to start it immediately. Otherwise, you can start it manually:

```bash
macosloginwatcher
```

### Disable Monitoring

To stop monitoring and disable autostart:

```bash
macosloginwatcher --disable
```

### Reconfigure

To change your Telegram settings or autostart preferences:

```bash
macosloginwatcher --setup
```

## How It Works

1. The script monitors system logs for unlock events
2. When your Mac is unlocked, it sends a notification to your Telegram
3. The notification includes:
   - Timestamp of the unlock
   - Username of the person who unlocked the Mac

## Requirements

- macOS 10.12 or later
- Telegram account
- sudo privileges (for log monitoring)
  - You will be prompted for your password when the script first runs
  - This is required to monitor system logs for unlock events

## Troubleshooting

### Common Issues

1. **Script not found after installation**
   - Make sure the script is in your PATH
   - Try using the full path to the script

2. **No notifications received**
   - Verify your Telegram Bot Token and Chat ID
   - Check if the bot is started in Telegram
   - Ensure you have an active internet connection

3. **Permission denied or sudo password prompt**
   - The script requires sudo access to monitor system logs
   - You will be prompted for your password when the script first runs
   - If you see "Error: This script requires sudo privileges", enter your password when prompted
   - If you want to avoid password prompts, you can add the following line to your sudoers file (use `visudo`):
     ```
     yourusername ALL=(ALL) NOPASSWD: /usr/bin/log stream
     ```

4. **Script stops after some time**
   - This might happen if the sudo session expires
   - Consider adding the NOPASSWD rule to sudoers as mentioned above

## Security

- Your Telegram Bot Token and Chat ID are stored in `~/.config/macosloginwatcher/config`
- The script requires sudo privileges only for log monitoring
- No data is sent to any servers other than Telegram

## Contributing

Feel free to submit issues and enhancement requests!

## License

This project is licensed under the MIT License - see the LICENSE file for details. 