#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# Build a complete Smart Room Pi OS image from scratch
#
# Uses Raspberry Pi's official pi-gen tool to create a custom .img
# No physical Pi needed — builds on any Linux machine (or Docker).
#
# Usage:
#   sudo bash build-image.sh          # On Debian/Ubuntu or VPS
#
# Works on:
#   - VPS (Ubuntu/Debian) — uses Docker (recommended)
#   - Local Linux machine — Docker or native
#   - Docker is REQUIRED on x86_64 (VPS/PC) — handles ARM emulation
#
# Requirements:
#   - Linux (Ubuntu/Debian) with Docker installed
#   - ~10GB free disk space
#   - Internet connection
#   - Takes 30-60 minutes
#
# Output:
#   ./deploy/smart-room-YYYYMMDD.img.xz
# ══════════════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/pi-gen-smartroom"
IMAGE_NAME="smart-room-$(date +%Y%m%d)"

echo "═══════════════════════════════════════════════"
echo "  Smart Room Pi OS Image Builder"
echo "═══════════════════════════════════════════════"

# ── 0. Pre-flight checks ──────────────────────────────────────────
ARCH=$(uname -m)
echo ""
echo "  Host:  $(hostname) ($ARCH)"
echo "  OS:    $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Unknown")"
echo ""

# Docker is required on x86_64 (VPS/PC) for ARM cross-compilation
if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "amd64" ]; then
    if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker is required on x86_64 machines."
        echo ""
        echo "Install Docker:"
        echo "  curl -fsSL https://get.docker.com | sudo sh"
        echo "  sudo usermod -aG docker \$USER"
        echo ""
        echo "Then re-run: sudo bash build-image.sh"
        exit 1
    fi
    echo "  Docker: $(docker --version | head -1)"

    # Ensure Docker is running
    if ! docker info &>/dev/null; then
        echo "  Starting Docker..."
        systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
        sleep 3
        if ! docker info &>/dev/null; then
            echo "ERROR: Docker is installed but not running."
            echo "  Try: sudo systemctl start docker"
            exit 1
        fi
    fi
fi

# Check disk space (need ~10GB)
AVAIL_KB=$(df /tmp --output=avail 2>/dev/null | tail -1 | tr -d ' ')
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt 8000000 ]; then
    echo "WARNING: Less than 8GB free in /tmp. Build may fail."
    echo "  Available: $((AVAIL_KB / 1024))MB"
fi

echo ""

# ── 1. Clone pi-gen ──────────────────────────────────────────────
if [ ! -d "$BUILD_DIR" ]; then
    echo "[1/4] Cloning pi-gen..."
    git clone --depth 1 --branch bookworm https://github.com/RPi-Distro/pi-gen.git "$BUILD_DIR"
else
    echo "[1/4] pi-gen already exists at $BUILD_DIR"
fi

cd "$BUILD_DIR"

# ── 2. Write pi-gen config ───────────────────────────────────────
echo "[2/4] Writing configuration..."

cat > config << EOF
IMG_NAME="$IMAGE_NAME"
RELEASE=bookworm
TARGET_HOSTNAME=smart-room
FIRST_USER_NAME=pi
FIRST_USER_PASS=smartroom
ENABLE_SSH=1
LOCALE_DEFAULT=en_GB.UTF-8
KEYBOARD_KEYMAP=us
KEYBOARD_LAYOUT="English (US)"
TIMEZONE_DEFAULT=Asia/Kolkata
STAGE_LIST="stage0 stage1 stage2 stage3 stage3-smartroom"
EOF


# ── 3. Create custom stage ───────────────────────────────────────
echo "[3/4] Creating Smart Room stage..."

STAGE_DIR="$BUILD_DIR/stage3-smartroom"
mkdir -p "$STAGE_DIR/00-install-deps/files"
mkdir -p "$STAGE_DIR/01-smart-room/files"
mkdir -p "$STAGE_DIR/02-kiosk-config/files"

# ── 3a. Package installs ─────────────────────────────────────────
cat > "$STAGE_DIR/00-install-deps/00-packages" << 'EOF'
chromium
network-manager
xserver-xorg
x11-xserver-utils
xinit
openbox
lightdm
unclutter
python3
fonts-noto
fonts-noto-cjk
fonts-noto-color-emoji
python3-dbus
python3-gi
bluez
EOF

# ── 3b. Copy Smart Room files ────────────────────────────────────

# Boot script
cp "$SCRIPT_DIR/boot.py" "$STAGE_DIR/01-smart-room/files/boot.py"

# Splash page + logo
cp "$SCRIPT_DIR/kiosk-splash.html" "$STAGE_DIR/01-smart-room/files/splash.html"
cp "$SCRIPT_DIR/logo.png" "$STAGE_DIR/01-smart-room/files/logo.png"

# WiFi provisioning scripts
cp "$SCRIPT_DIR/wifi-setup.py" "$STAGE_DIR/01-smart-room/files/wifi-setup.py"
cp "$SCRIPT_DIR/bt-wifi-server.py" "$STAGE_DIR/01-smart-room/files/bt-wifi-server.py"

# Install script
cat > "$STAGE_DIR/01-smart-room/00-run.sh" << 'INSTALL'
#!/bin/bash -e

# Create install directory
install -d "${ROOTFS_DIR}/opt/smart-room"

# Copy files
install -m 755 files/boot.py "${ROOTFS_DIR}/opt/smart-room/boot.py"
install -m 644 files/splash.html "${ROOTFS_DIR}/opt/smart-room/splash.html"
install -m 644 files/logo.png "${ROOTFS_DIR}/opt/smart-room/logo.png"
install -m 755 files/wifi-setup.py "${ROOTFS_DIR}/opt/smart-room/wifi-setup.py"
install -m 755 files/bt-wifi-server.py "${ROOTFS_DIR}/opt/smart-room/bt-wifi-server.py"

# Create network watchdog
cat > "${ROOTFS_DIR}/opt/smart-room/watchdog.sh" << 'WATCHDOG'
#!/bin/bash
PING_HOST="8.8.8.8"
FAIL_COUNT=0
MAX_FAILS=3

while true; do
    if ping -c 1 -W 5 "$PING_HOST" > /dev/null 2>&1; then
        if [ "$FAIL_COUNT" -ge "$MAX_FAILS" ]; then
            echo "$(date): Network recovered, restarting Chromium"
            pkill -f chromium-browser
            sleep 2
        fi
        FAIL_COUNT=0
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$(date): Network ping failed ($FAIL_COUNT/$MAX_FAILS)"
    fi
    sleep 30
done
WATCHDOG
chmod 755 "${ROOTFS_DIR}/opt/smart-room/watchdog.sh"
INSTALL

# ── 3c. systemd services ─────────────────────────────────────────
cat > "$STAGE_DIR/01-smart-room/01-run.sh" << 'SERVICES'
#!/bin/bash -e

# Smart Room kiosk service
cat > "${ROOTFS_DIR}/etc/systemd/system/smart-room.service" << 'SVC'
[Unit]
Description=Smart Room Kiosk
After=network-online.target graphical.target
Wants=network-online.target

[Service]
Type=simple
User=pi
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/pi/.Xauthority
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/python3 /opt/smart-room/boot.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=graphical.target
SVC

# Network watchdog service
cat > "${ROOTFS_DIR}/etc/systemd/system/smart-room-watchdog.service" << 'WD'
[Unit]
Description=Smart Room Network Watchdog
After=network-online.target

[Service]
Type=simple
ExecStart=/opt/smart-room/watchdog.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
WD

# WiFi provisioning service
cat > "${ROOTFS_DIR}/etc/systemd/system/smart-room-wifi.service" << 'WIFI'
[Unit]
Description=Smart Room WiFi Provisioning
Before=smart-room.service
After=bluetooth.target
Wants=bluetooth.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/smart-room/wifi-setup.py
Restart=on-failure
RestartSec=15
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
WIFI

# Enable services
on_chroot << CHROOT
systemctl enable smart-room.service
systemctl enable smart-room-wifi.service
systemctl enable smart-room-watchdog.service
CHROOT
SERVICES

# ── 3d. Kiosk display config ─────────────────────────────────────
cat > "$STAGE_DIR/02-kiosk-config/00-run.sh" << 'KIOSK'
#!/bin/bash -e

# LightDM auto-login
install -d "${ROOTFS_DIR}/etc/lightdm/lightdm.conf.d"
cat > "${ROOTFS_DIR}/etc/lightdm/lightdm.conf.d/50-autologin.conf" << 'LDM'
[Seat:*]
autologin-user=pi
autologin-user-timeout=0
user-session=openbox
LDM

# Openbox autostart
install -d "${ROOTFS_DIR}/home/pi/.config/openbox"
cat > "${ROOTFS_DIR}/home/pi/.config/openbox/autostart" << 'OBX'
# Disable screen blanking / power saving
xset s off
xset s noblank
xset -dpms

# Hide mouse cursor
unclutter -idle 0.5 -root &

# NOTE: boot.py is launched by smart-room.service (systemd), NOT here.
# Putting it here too would launch Chromium twice.
OBX

# Chromium config (skip first-run)
install -d "${ROOTFS_DIR}/home/pi/.config/chromium/Default"
cat > "${ROOTFS_DIR}/home/pi/.config/chromium/Default/Preferences" << 'PREFS'
{
  "browser": { "has_seen_welcome_page": true, "check_default_browser": false },
  "session": { "restore_on_startup": 1 },
  "profile": { "exit_type": "Normal", "exited_cleanly": true }
}
PREFS

# Fix ownership
on_chroot << CHROOT
chown -R pi:pi /home/pi/.config
CHROOT

# Bookworm uses /boot/firmware/ instead of /boot/
BOOT_DIR="${ROOTFS_DIR}/boot/firmware"
if [ ! -d "$BOOT_DIR" ]; then
    BOOT_DIR="${ROOTFS_DIR}/boot"
fi

# GPU memory for Chromium
echo "gpu_mem=128" >> "$BOOT_DIR/config.txt"

# Enable hardware acceleration for Chromium
echo "dtoverlay=vc4-fkms-v3d" >> "$BOOT_DIR/config.txt"

# NOTE: Bluetooth kept enabled for WiFi provisioning via mobile app

# Disable screen blanking
sed -i 's/$/ consoleblank=0/' "$BOOT_DIR/cmdline.txt"

# Prevent Chromium crash recovery bar
install -d "${ROOTFS_DIR}/home/pi/.config/chromium"
cat > "${ROOTFS_DIR}/home/pi/.config/chromium/Local State" << 'LOCALSTATE'
{
  "browser": { "enabled_labs_experiments": [] },
  "profile": { "profiles_order": ["Default"] },
  "user_experience_metrics": { "reporting_enabled": false }
}
LOCALSTATE

# Fix ownership of all pi user config
on_chroot << CHROOT2
chown -R pi:pi /home/pi/.config
CHROOT2
KIOSK


# ── 4. Build ─────────────────────────────────────────────────────
echo "[4/4] Building image (this takes 30-60 minutes)..."

cd "$BUILD_DIR"

# Docker build for x86_64 (required for ARM cross-compilation)
# Native build only works on ARM hosts (e.g., another Pi or ARM VPS)
if command -v docker &>/dev/null; then
    echo "  Using Docker build (handles ARM emulation)..."
    ./build-docker.sh
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "armv7l" ]; then
    echo "  Using native ARM build..."
    ./build.sh
else
    echo "ERROR: Docker is required on $ARCH. Install Docker first."
    echo "  curl -fsSL https://get.docker.com | sudo sh"
    exit 1
fi

# ── Copy output ──────────────────────────────────────────────────
OUTPUT_DIR="$SCRIPT_DIR/deploy"
mkdir -p "$OUTPUT_DIR"

IMG_PATH=$(find "$BUILD_DIR/deploy" -name "*.img.xz" -type f | head -1)
if [ -n "$IMG_PATH" ]; then
    cp "$IMG_PATH" "$OUTPUT_DIR/"
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  Build Complete!"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "  Image: $OUTPUT_DIR/$(basename "$IMG_PATH")"
    echo "  Size:  $(du -h "$IMG_PATH" | cut -f1)"
    echo ""
    echo "  Flash with:"
    echo "    xzcat $(basename "$IMG_PATH") | sudo dd of=/dev/sdX bs=4M status=progress"
    echo "    OR use Raspberry Pi Imager → Custom Image"
    echo ""
    echo "  If built on VPS, download to your PC first:"
    echo "    scp root@your-vps:$OUTPUT_DIR/$(basename "$IMG_PATH") ."
    echo ""
    echo "  After flashing:"
    echo "    1. Insert SD into Pi → power on"
    echo "    2. No WiFi? Pi advertises via Bluetooth as 'SmartRoom-XXXX'"
    echo "    3. Open mobile app → Smart Rooms → WiFi icon → send WiFi"
    echo "    4. Pi connects → shows pairing code → enter in admin dashboard"
    echo "    5. Done! Zero manual config needed."
    echo ""
else
    echo "ERROR: No .img.xz found in $BUILD_DIR/deploy/"
    echo "Check build logs for errors."
    exit 1
fi
