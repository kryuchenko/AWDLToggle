#!/bin/bash
set -e

# Parse arguments
DEBUG_MODE=false
for arg in "$@"; do
    case $arg in
        --debug|-d)
            DEBUG_MODE=true
            ;;
    esac
done

echo "🔧 Installing AWDL Toggle..."

# Ask for sudo upfront
sudo -v

# Create temp directory
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

# Download source
echo "📥 Downloading..."
curl -sL https://github.com/kryuchenko/AWDLToggle/archive/refs/heads/main.tar.gz | tar xz
cd AWDLToggle-main

# Build helper
echo "🔨 Building helper..."
clang -O2 -o awdl-helper Helper/helper.c

# Build app
echo "🔨 Building app..."
swift build -c release

# Create app bundle
echo "📦 Creating app bundle..."
mkdir -p AWDLToggle.app/Contents/MacOS
mkdir -p AWDLToggle.app/Contents/Resources
cp .build/release/AWDLKiller AWDLToggle.app/Contents/MacOS/AWDLToggle
cp awdl-helper AWDLToggle.app/Contents/MacOS/
cp pkg_root/Applications/AWDLToggle.app/Contents/Info.plist AWDLToggle.app/Contents/
cp pkg_root/Applications/AWDLToggle.app/Contents/Resources/* AWDLToggle.app/Contents/Resources/ 2>/dev/null || true

# Install
echo "🔐 Installing (requires sudo)..."
sudo rm -rf /Applications/AWDLToggle.app
sudo mv AWDLToggle.app /Applications/
sudo chown root:wheel /Applications/AWDLToggle.app/Contents/MacOS/awdl-helper
sudo chmod 4755 /Applications/AWDLToggle.app/Contents/MacOS/awdl-helper

# Create LaunchAgent
echo "⚙️ Setting up auto-start..."
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.local.awdltoggle.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.awdltoggle</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/AWDLToggle.app/Contents/MacOS/AWDLToggle</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

# Enable debug logging if requested
if [ "$DEBUG_MODE" = true ]; then
    echo "🐛 Enabling debug logging..."
    defaults write com.local.awdltoggle debugEnabled -bool true
fi

# Start app
echo "🚀 Starting..."
launchctl load ~/Library/LaunchAgents/com.local.awdltoggle.plist 2>/dev/null || true

# Cleanup
cd /
rm -rf "$TMPDIR"

echo "✅ Done! AWDL Toggle is now in your menu bar."
