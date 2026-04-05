# Smart Room Pi — Kiosk Setup

One-command setup for Raspberry Pi smart room kiosks.

## Quick Install

SSH into a fresh Raspberry Pi and run:

```bash
curl -sSL https://raw.githubusercontent.com/gyanendrasahu97/pi/main/setup.sh | sudo bash
```

Pi will reboot automatically after setup.

## What It Does

| Step | What |
|------|------|
| System update | `apt update && upgrade` |
| Dependencies | Chromium, Widevine DRM, X11, LightDM, Plymouth, Bluetooth |
| Boot script | `/opt/smart-room/boot.py` — auto-launches kiosk |
| Auto-login | LightDM → Openbox → Chromium (no desktop) |
| Clean boot | No rainbow screen, no boot text, branded splash with logo |
| WiFi setup | Bluetooth GATT + USB `wifi.txt` + boot partition |
| Watchdog | Network monitor, auto-restart Chromium on reconnect |
| DRM support | Widevine L3 for VdoCipher video playback |

## Boot Sequence

```
Power On → [Logo Splash] → [Chromium Kiosk] → Dashboard
```

No OS elements visible at any point. No boot text, no login screen, no desktop.

## WiFi Setup (3 Methods)

### a. Bluetooth (recommended)
1. Pi advertises as `SmartRoom-XXXX` via Bluetooth
2. Open mobile app → Smart Rooms → tap WiFi icon
3. Send WiFi credentials from phone

### b. USB Drive
1. Create `wifi.txt` on a USB drive:
   ```
   SSID=YourWiFiName
   PASSWORD=YourWiFiPassword
   COUNTRY=IN
   ```
2. Plug USB into Pi — connects automatically

### c. Boot Partition
1. Place `wifi.txt` on the SD card's boot partition (`/boot/firmware/`)
2. Reboot

## Pairing

1. Once online, Pi shows a **6-character pairing code** on screen
2. Open admin dashboard → Smart Rooms → Pair Device
3. Enter the code

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | Main installer — run this |
| `boot.py` | Kiosk boot script (Chromium launcher) |
| `bt-wifi-server.py` | Bluetooth GATT server for WiFi provisioning |
| `wifi-setup.py` | WiFi orchestrator (BT + USB + boot) |
| `kiosk-splash.html` | Loading splash shown while Chromium starts |
| `logo.png` | Brand logo (used in splash + Plymouth boot) |
| `wifi.txt` | Example WiFi config file |

## Check Status

```bash
systemctl status smart-room
journalctl -u smart-room -f
```

## Requirements

- Raspberry Pi 3/4/5
- Raspberry Pi OS (Lite or Desktop)
- Internet connection during setup
