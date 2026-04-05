#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# Smart Room Pi Setup Script
# Run on a fresh Raspberry Pi OS (Lite or Desktop) to configure kiosk.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/gyanendrasahu97/pi/main/setup.sh | sudo bash
#   OR
#   sudo bash setup.sh
# ══════════════════════════════════════════════════════════════════════

set -e

do_setup() {
    local INSTALL_DIR="/opt/smart-room"
    local SERVICE_NAME="smart-room"
    
    # Dynamically detect the non-root user (Raspberry Pi OS default user has UID 1000)
    local PI_USER="${SUDO_USER:-}"
    if [ -z "$PI_USER" ] || [ "$PI_USER" = "root" ]; then
        PI_USER=$(id -un 1000 2>/dev/null || echo "pi")
    fi

echo "═══════════════════════════════════════════════"
echo "  Smart Room Pi Setup"
echo "═══════════════════════════════════════════════"

# ── 1. System Update ──────────────────────────────────────────────
echo ""
echo "[1/7] Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# ── 2. Install Dependencies ──────────────────────────────────────
echo "[2/8] Installing dependencies..."
apt-get install -y -qq \
    chromium \
    libwidevinecdm0 \
    network-manager \
    xserver-xorg \
    x11-xserver-utils \
    xinit \
    openbox \
    lightdm \
    lightdm-gtk-greeter \
    unclutter \
    plymouth \
    plymouth-themes \
    x11-xserver-utils \
    python3 \
    python3-dbus \
    python3-gi \
    bluez \
    curl \
    fonts-noto \
    fonts-noto-cjk \
    fonts-noto-color-emoji

# ── 3. Create Install Directory ──────────────────────────────────
echo "[3/8] Installing Smart Room files..."
mkdir -p "$INSTALL_DIR"

# Copy boot script
# Download production boot.py from repo (has DRM flags, crash restart, network wait)
REPO_RAW_BOOT="https://raw.githubusercontent.com/gyanendrasahu97/pi/main"
curl -sSL "$REPO_RAW_BOOT/boot.py" -o "$INSTALL_DIR/boot.py" 2>/dev/null || true

# Fallback: create boot.py inline if download failed
if [ ! -f "$INSTALL_DIR/boot.py" ] || [ ! -s "$INSTALL_DIR/boot.py" ]; then
cat > "$INSTALL_DIR/boot.py" << 'BOOT_EOF'
#!/usr/bin/env python3
import subprocess, sys, time

WEB_URL = "https://app.maheshee.online"

def get_hardware_id():
    try:
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if line.startswith("Serial"):
                    serial = line.strip().split(":")[1].strip()
                    if serial and serial != "0" * len(serial):
                        return serial
    except Exception: pass
    try:
        with open("/etc/machine-id", "r") as f:
            return f.read().strip()
    except Exception: pass
    return "unknown"

def wait_for_network(timeout=60):
    start = time.time()
    while time.time() - start < timeout:
        r = subprocess.run(["ip", "-4", "route", "show", "default"], capture_output=True, text=True)
        if "default" in r.stdout: return True
        time.sleep(2)
    return False

def launch_chromium(url):
    flags = [
        "--kiosk", "--noerrdialogs", "--no-first-run", "--disable-infobars",
        "--disable-translate", "--disable-session-crashed-bubble",
        "--disable-component-update", "--disable-pinch",
        "--autoplay-policy=no-user-gesture-required",
        "--check-for-update-interval=31536000",
        "--overscroll-history-navigation=0", "--no-sandbox",
        "--disable-features=TranslateUI,HardwareMediaKeyHandling",
        "--enable-features=EncryptedMedia,VaapiVideoDecoder",
        "--enable-cdm-host-verification",
        "--use-gl=egl", "--enable-gpu-rasterization", "--ignore-gpu-blocklist",
    ]
    for binary in ["chromium-browser", "chromium"]:
        try:
            subprocess.run([binary, "--version"], capture_output=True, check=True)
            return subprocess.call([binary] + flags + [url])
        except (FileNotFoundError, subprocess.CalledProcessError): continue
    return 1

def main():
    hw_id = get_hardware_id()
    url = f"{WEB_URL}/kiosk-auth#hardware_id={hw_id}"
    wait_for_network()
    restart_count = 0
    while True:
        exit_code = launch_chromium(url)
        restart_count += 1
        if restart_count >= 5:
            time.sleep(30)
            restart_count = 0
        else:
            time.sleep(3)

if __name__ == "__main__":
    main()
BOOT_EOF
fi

chmod +x "$INSTALL_DIR/boot.py"

# Copy splash page + logo (shown while Chromium loads)
REPO_RAW_BASE="https://raw.githubusercontent.com/gyanendrasahu97/pi/main"
curl -sSL "$REPO_RAW_BASE/kiosk-splash.html" -o "$INSTALL_DIR/splash.html" 2>/dev/null || true
curl -sSL "$REPO_RAW_BASE/logo.png" -o "$INSTALL_DIR/logo.png" 2>/dev/null || true

# Fallback: if download failed, create minimal splash inline
if [ ! -f "$INSTALL_DIR/splash.html" ]; then
cat > "$INSTALL_DIR/splash.html" << 'SPLASH_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Smart Room</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { background: #0A0A0F; color: white; font-family: -apple-system, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; }
  .brand { font-size: 32px; font-weight: 700; background: linear-gradient(135deg, #F97316, #EC4899, #8B5CF6, #3B82F6); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
  .sub { color: rgba(255,255,255,0.4); font-size: 14px; margin-top: 12px; }
  .spinner { width: 24px; height: 24px; border: 3px solid rgba(255,255,255,0.08); border-top-color: #F97316; border-radius: 50%; animation: s 0.8s linear infinite; display: inline-block; vertical-align: middle; margin-right: 8px; }
  @keyframes s { to { transform: rotate(360deg); } }
</style>
</head>
<body>
  <div style="text-align:center">
    <div class="brand">Maheshee</div>
    <p class="sub"><span class="spinner"></span>Starting Smart Room...</p>
  </div>
</body>
</html>
SPLASH_EOF
fi

# ── 4. Configure Auto-Login ──────────────────────────────────────
echo "[4/8] Configuring auto-login..."

# LightDM auto-login
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf << EOF
[Seat:*]
autologin-user=$PI_USER
autologin-user-timeout=0
user-session=openbox
greeter-session=lightdm-gtk-greeter
greeter-hide-users=true
EOF

# Hide LightDM greeter completely (black background, no logo)
mkdir -p /etc/lightdm
cat > /etc/lightdm/lightdm-gtk-greeter.conf << EOF
[greeter]
background=#000000
theme-name=Adwaita
hide-user-image=true
default-user-image=
EOF

# Openbox autostart — hide cursor, make background black, disable screensaver
OPENBOX_DIR="/home/$PI_USER/.config/openbox"
mkdir -p "$OPENBOX_DIR"
cat > "$OPENBOX_DIR/autostart" << EOF
# Set background pitch black immediately
xsetroot -solid black

# Disable screen blanking / power saving
xset s off
xset s noblank
xset -dpms

# Hide mouse cursor after 0.5 seconds of inactivity
unclutter -idle 0.5 -root &

# NOTE: boot.py is launched by smart-room.service (systemd), NOT here.
EOF
chown -R "$PI_USER:$PI_USER" "/home/$PI_USER/.config"

# Force X11 instead of Wayland (fixes desktop showing up in Bookworm)
raspi-config nonint do_wayland W1 2>/dev/null || true
# Force Boot to Desktop with Auto-login
raspi-config nonint do_boot_behaviour B4 2>/dev/null || true

# ── 5. Install systemd Service (backup method) ──────────────────
echo "[5/8] Installing systemd service..."
cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Smart Room Kiosk
After=network-online.target graphical.target
Wants=network-online.target

[Service]
Type=simple
User=$PI_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$PI_USER/.Xauthority
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/python3 /opt/smart-room/boot.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable ${SERVICE_NAME}.service

# ── 6. System Hardening for Kiosk ────────────────────────────────
echo "[6/9] Configuring kiosk optimizations..."

# ── CLEAN BOOT: Hide ALL boot text and OS screens ────────────────
# cmdline.txt: quiet splash + other kiosk params
CMDLINE="/boot/cmdline.txt"
# Also check Pi 5 / newer location
[ ! -f "$CMDLINE" ] && CMDLINE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE" ]; then
    # Add quiet + splash + consoleblank + hide logo + hide cursor
    for param in "quiet" "splash" "consoleblank=0" "logo.nologo" "vt.global_cursor_default=0" "loglevel=0"; do
        if ! grep -q "$param" "$CMDLINE"; then
            sed -i "s/$/ $param/" "$CMDLINE"
        fi
    done
fi

# config.txt: disable rainbow splash + GPU settings
CONFIG="/boot/config.txt"
[ ! -f "$CONFIG" ] && CONFIG="/boot/firmware/config.txt"
if [ -f "$CONFIG" ]; then
    # Disable rainbow splash screen at power-on
    if ! grep -q "^disable_splash=" "$CONFIG"; then
        echo "disable_splash=1" >> "$CONFIG"
    else
        sed -i 's/^disable_splash=.*/disable_splash=1/' "$CONFIG"
    fi

    # GPU memory — more for Chromium rendering
    if grep -q "^gpu_mem=" "$CONFIG"; then
        sed -i 's/^gpu_mem=.*/gpu_mem=128/' "$CONFIG"
    else
        echo "gpu_mem=128" >> "$CONFIG"
    fi

    # Enable hardware acceleration
    if ! grep -q "^dtoverlay=vc4-kms-v3d" "$CONFIG"; then
        echo "dtoverlay=vc4-kms-v3d" >> "$CONFIG"
    fi

    # Disable boot activity LED blinking (less distracting)
    if ! grep -q "^dtparam=act_led_trigger=" "$CONFIG"; then
        echo "dtparam=act_led_trigger=none" >> "$CONFIG"
        echo "dtparam=act_led_activelow=on" >> "$CONFIG"
    fi
fi

# ── Plymouth branded boot splash (shown during kernel boot) ──────
echo "[7/9] Configuring boot splash..."

# Create custom Plymouth theme
PLY_DIR="/usr/share/plymouth/themes/smart-room"
mkdir -p "$PLY_DIR"

# Copy logo for Plymouth
cp "$INSTALL_DIR/logo.png" "$PLY_DIR/logo.png" 2>/dev/null || true

cat > "$PLY_DIR/smart-room.plymouth" << 'PLYEOF'
[Plymouth Theme]
Name=Smart Room
Description=Clean boot splash for Smart Room kiosk
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/smart-room
ScriptFile=/usr/share/plymouth/themes/smart-room/smart-room.script
PLYEOF

cat > "$PLY_DIR/smart-room.script" << 'SCRIPTEOF'
# Simple black screen with logo
Window.SetBackgroundTopColor(0.04, 0.03, 0.02);
Window.SetBackgroundBottomColor(0.04, 0.03, 0.02);

logo_image = Image("logo.png");
logo_scaled = logo_image.Scale(96, 96);
logo_sprite = Sprite(logo_scaled);
logo_sprite.SetX(Window.GetWidth() / 2 - 48);
logo_sprite.SetY(Window.GetHeight() / 2 - 48);
logo_sprite.SetOpacity(1);
SCRIPTEOF

# Set as default Plymouth theme
plymouth-set-default-theme -R smart-room 2>/dev/null || true

# ── Disable unused services to speed up boot ─────────────────────
echo "[8/9] Disabling unused services..."
systemctl disable triggerhappy.service 2>/dev/null || true
systemctl disable hciuart.service 2>/dev/null || true
systemctl disable avahi-daemon.service 2>/dev/null || true
systemctl disable cups.service 2>/dev/null || true
systemctl disable ModemManager.service 2>/dev/null || true
# Note: bluetooth.service KEPT for WiFi provisioning

# NOTE: Bluetooth is KEPT enabled for WiFi provisioning via mobile app

# Set timezone to IST
timedatectl set-timezone Asia/Kolkata 2>/dev/null || true

# Create Chromium profile directory to avoid first-run prompts
CHROMIUM_DIR="/home/$PI_USER/.config/chromium"
mkdir -p "$CHROMIUM_DIR/Default"
cat > "$CHROMIUM_DIR/Default/Preferences" << 'PREFS'
{
  "browser": {
    "has_seen_welcome_page": true,
    "check_default_browser": false
  },
  "session": {
    "restore_on_startup": 1
  },
  "profile": {
    "exit_type": "Normal",
    "exited_cleanly": true
  }
}
PREFS
chown -R "$PI_USER:$PI_USER" "$CHROMIUM_DIR"

# Prevent Chromium crash recovery bar
CHROMIUM_LOCAL="/home/$PI_USER/.config/chromium/Local State"
cat > "$CHROMIUM_LOCAL" << 'LOCAL'
{
  "browser": {
    "enabled_labs_experiments": []
  },
  "profile": {
    "profiles_order": ["Default"]
  },
  "user_experience_metrics": {
    "reporting_enabled": false
  }
}
LOCAL
chown "$PI_USER:$PI_USER" "$CHROMIUM_LOCAL"

# ── 7. WiFi Provisioning (Bluetooth + USB + boot partition) ──────
echo "[7/8] Installing WiFi provisioning..."

# WiFi setup orchestrator
cat > "$INSTALL_DIR/wifi-setup.py" << 'WIFISETUP_EOF'
#!/usr/bin/env python3
"""Network provisioning: checks WiFi/LAN, USB/boot wifi.txt, falls back to BT server."""
import os, sys, glob, time, subprocess

WIFI_FILENAME = "wifi.txt"
CONFIG_PATH = "/opt/smart-room"
BT_SERVER = "/opt/smart-room/bt-wifi-server.py"

def is_network_connected():
    for iface in ["wlan0", "eth0"]:
        try:
            r = subprocess.run(["ip", "-4", "addr", "show", iface], capture_output=True, text=True)
            if "inet " in r.stdout: return True
        except: pass
    return False

def find_wifi_txt():
    for base in ["/media"]:
        if os.path.isdir(base):
            for ud in os.listdir(base):
                up = os.path.join(base, ud)
                if os.path.isdir(up):
                    for m in os.listdir(up):
                        p = os.path.join(up, m, WIFI_FILENAME)
                        if os.path.isfile(p): return p
    for m in glob.glob("/mnt/*/"):
        p = os.path.join(m, WIFI_FILENAME)
        if os.path.isfile(p): return p
    for b in ["/boot/firmware", "/boot"]:
        p = os.path.join(b, WIFI_FILENAME)
        if os.path.isfile(p): return p
    p = os.path.join(CONFIG_PATH, WIFI_FILENAME)
    if os.path.isfile(p): return p
    return None

def parse(path):
    cfg = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"): continue
            if "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip().upper()] = v.strip()
    return cfg if "SSID" in cfg else None

def apply(ssid, pw="", country="IN"):
    subprocess.run(["raspi-config", "nonint", "do_wifi_country", country], capture_output=True, check=False)
    try:
        r = subprocess.run(["nmcli", "--version"], capture_output=True)
        if r.returncode == 0:
            subprocess.run(["nmcli", "connection", "delete", ssid], capture_output=True, check=False)
            cmd = ["nmcli", "device", "wifi", "connect", ssid]
            if pw: cmd += ["password", pw]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if r.returncode == 0: return True
    except: pass
    wpa = f'ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev\nupdate_config=1\ncountry={country}\n\nnetwork={{\n    ssid="{ssid}"\n    {"psk=" + chr(34) + pw + chr(34) if pw else "key_mgmt=NONE"}\n}}\n'
    with open("/etc/wpa_supplicant/wpa_supplicant.conf", "w") as f: f.write(wpa)
    subprocess.run(["wpa_cli", "-i", "wlan0", "reconfigure"], capture_output=True, check=False)
    for _ in range(20):
        time.sleep(1)
        if is_network_connected(): return True
    return False

if __name__ == "__main__":
    time.sleep(3)
    if is_network_connected(): sys.exit(0)
    p = find_wifi_txt()
    if p:
        cfg = parse(p)
        if cfg and apply(cfg["SSID"], cfg.get("PASSWORD", ""), cfg.get("COUNTRY", "IN")):
            try: os.remove(p)
            except: pass
            sys.exit(0)
    if os.path.isfile(BT_SERVER):
        os.execv(sys.executable, [sys.executable, BT_SERVER])
WIFISETUP_EOF
chmod +x "$INSTALL_DIR/wifi-setup.py"

# Bluetooth WiFi GATT server — download from repo
REPO_RAW="https://raw.githubusercontent.com/gyanendrasahu97/pi/main"
curl -sSL "$REPO_RAW/bt-wifi-server.py" -o "$INSTALL_DIR/bt-wifi-server.py" 2>/dev/null || true
chmod +x "$INSTALL_DIR/bt-wifi-server.py"

# WiFi provisioning systemd service (runs before kiosk, ensures WiFi first)
cat > /etc/systemd/system/smart-room-wifi.service << EOF
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
EOF

systemctl daemon-reload
systemctl enable smart-room-wifi.service

# ── 8. Network Watchdog ──────────────────────────────────────────
echo "[8/8] Installing network watchdog..."

cat > "$INSTALL_DIR/watchdog.sh" << 'WATCHDOG'
#!/bin/bash
# Network watchdog — restarts Chromium if connectivity lost and recovered
PING_HOST="8.8.8.8"
FAIL_COUNT=0
MAX_FAILS=3

while true; do
    if ping -c 1 -W 5 "$PING_HOST" > /dev/null 2>&1; then
        if [ "$FAIL_COUNT" -ge "$MAX_FAILS" ]; then
            # Network recovered after failure — restart Chromium
            echo "$(date): Network recovered, restarting Chromium"
            pkill -f chromium-browser
            sleep 2
            # Openbox autostart or systemd will restart it
        fi
        FAIL_COUNT=0
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$(date): Network ping failed ($FAIL_COUNT/$MAX_FAILS)"
    fi
    sleep 30
done
WATCHDOG
chmod +x "$INSTALL_DIR/watchdog.sh"

# Watchdog service
cat > /etc/systemd/system/smart-room-watchdog.service << EOF
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
EOF

systemctl daemon-reload
systemctl enable smart-room-watchdog.service

# ── Done ─────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "  Setup Complete!"
echo "═══════════════════════════════════════════════"
echo ""
echo "  Installed to:  $INSTALL_DIR"
echo "  Web URL:       https://app.maheshee.online"
echo "  Service:       $SERVICE_NAME.service"
echo "  WiFi:          smart-room-wifi.service"
echo "  Watchdog:      smart-room-watchdog.service"
echo ""
echo "  Hardware ID will be read from CPU serial on boot."
echo ""
echo "  WiFi Setup (3 methods):"
echo "    a. Bluetooth: Open mobile app → Smart Rooms → WiFi icon"
echo "    b. USB: Put wifi.txt on USB drive, plug into Pi"
echo "    c. Boot: Put wifi.txt on SD boot partition"
echo ""
echo "  Next steps:"
echo "    1. Reboot:  sudo reboot"
echo "    2. If no WiFi: Pi advertises via Bluetooth as SmartRoom-XXXX"
echo "       → Use mobile app to send WiFi credentials"
echo "    3. Once online: Pi shows pairing code on screen"
echo "    4. Open admin dashboard → Smart Rooms → Pair Device"
echo "    5. Enter the pairing code"
echo ""
echo "  To check status:"
echo "    systemctl status smart-room"
echo "    journalctl -u smart-room -f"
echo ""
echo "  Rebooting in 5 seconds..."
sleep 5
reboot
}

# Execute the main setup function
do_setup
