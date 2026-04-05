#!/usr/bin/env python3
"""
Smart Room WiFi Provisioning Orchestrator

Runs on every boot via systemd (smart-room-wifi.service).
Tries to get network connected in this order:

  1. Already connected (WiFi or Ethernet/LAN)? → done
  2. wifi.txt on USB drive / boot partition / config dir? → apply → done
  3. No network at all? → Start Bluetooth GATT server for mobile app provisioning

wifi.txt format (plain text, any of the 3 locations):
  SSID=MyNetworkName
  PASSWORD=MyPassword123
  COUNTRY=IN
"""
import os
import sys
import glob
import time
import subprocess

WIFI_FILENAME = "wifi.txt"
CONFIG_PATH = "/opt/smart-room"
BT_SERVER = "/opt/smart-room/bt-wifi-server.py"
LOG_PREFIX = "[WiFi]"

BOOT_PATHS = ["/boot/firmware", "/boot"]
USB_MOUNT_BASE = "/media"


def log(msg):
    print(f"{LOG_PREFIX} {msg}", flush=True)


def is_network_connected():
    """Check if any interface (wlan0 or eth0) has internet."""
    # Check wlan0
    try:
        result = subprocess.run(
            ["ip", "-4", "addr", "show", "wlan0"],
            capture_output=True, text=True
        )
        if "inet " in result.stdout:
            return True
    except Exception:
        pass
    # Check eth0 (LAN cable)
    try:
        result = subprocess.run(
            ["ip", "-4", "addr", "show", "eth0"],
            capture_output=True, text=True
        )
        if "inet " in result.stdout:
            return True
    except Exception:
        pass
    return False


def find_wifi_txt():
    """Search for wifi.txt in USB drives, boot partition, config dir."""
    # 1. USB drives
    if os.path.isdir(USB_MOUNT_BASE):
        for user_dir in os.listdir(USB_MOUNT_BASE):
            user_path = os.path.join(USB_MOUNT_BASE, user_dir)
            if os.path.isdir(user_path):
                for mount in os.listdir(user_path):
                    path = os.path.join(user_path, mount, WIFI_FILENAME)
                    if os.path.isfile(path):
                        log(f"Found on USB: {path}")
                        return path

    for mnt in glob.glob("/mnt/*/"):
        path = os.path.join(mnt, WIFI_FILENAME)
        if os.path.isfile(path):
            log(f"Found in /mnt: {path}")
            return path

    # 2. Boot partition
    for boot in BOOT_PATHS:
        path = os.path.join(boot, WIFI_FILENAME)
        if os.path.isfile(path):
            log(f"Found on boot: {path}")
            return path

    # 3. Config dir
    path = os.path.join(CONFIG_PATH, WIFI_FILENAME)
    if os.path.isfile(path):
        log(f"Found in config: {path}")
        return path

    return None


def parse_wifi_txt(filepath):
    """Parse wifi.txt → dict."""
    config = {}
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                config[key.strip().upper()] = val.strip()
    return config if "SSID" in config else None


def apply_wifi(ssid, password="", country="IN"):
    """Configure WiFi. Returns True on success."""
    log(f"Applying: SSID={ssid}, Country={country}")

    # Set country
    subprocess.run(
        ["raspi-config", "nonint", "do_wifi_country", country],
        capture_output=True, check=False
    )

    # Try nmcli
    try:
        r = subprocess.run(["nmcli", "--version"], capture_output=True)
        if r.returncode == 0:
            subprocess.run(["nmcli", "connection", "delete", ssid],
                           capture_output=True, check=False)
            cmd = ["nmcli", "device", "wifi", "connect", ssid]
            if password:
                cmd += ["password", password]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if r.returncode == 0:
                log("Connected via nmcli")
                return True
            log(f"nmcli failed: {r.stderr.strip()}")
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    # Fallback: wpa_supplicant
    wpa = f"""ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country={country}

network={{
    ssid="{ssid}"
    {"psk=" + '"' + password + '"' if password else "key_mgmt=NONE"}
}}
"""
    with open("/etc/wpa_supplicant/wpa_supplicant.conf", "w") as f:
        f.write(wpa)
    subprocess.run(["wpa_cli", "-i", "wlan0", "reconfigure"],
                   capture_output=True, check=False)
    subprocess.run(["systemctl", "restart", "dhcpcd"],
                   capture_output=True, check=False)

    for _ in range(20):
        time.sleep(1)
        if is_network_connected():
            log("Connected via wpa_supplicant")
            return True

    log("Connection timeout")
    return False


def main():
    log("Starting network provisioning...")
    time.sleep(3)  # Wait for USB mounts / DHCP on eth0

    # Step 1: Already connected (WiFi or LAN)?
    if is_network_connected():
        log("Network already connected (WiFi or LAN). Done.")
        return

    # Step 2: Check for wifi.txt
    wifi_path = find_wifi_txt()
    if wifi_path:
        config = parse_wifi_txt(wifi_path)
        if config:
            success = apply_wifi(
                config["SSID"],
                config.get("PASSWORD", ""),
                config.get("COUNTRY", "IN")
            )
            if success:
                # Delete file (don't leave password on disk)
                try:
                    os.remove(wifi_path)
                    log(f"Deleted {wifi_path}")
                except Exception:
                    pass
                return
            else:
                log("wifi.txt credentials failed")
        else:
            log("Invalid wifi.txt format")

    # Step 3: No network — start Bluetooth server
    if os.path.isfile(BT_SERVER):
        log("No network (WiFi or LAN). Starting Bluetooth provisioning server...")
        os.execv(sys.executable, [sys.executable, BT_SERVER])
    else:
        log(f"ERROR: {BT_SERVER} not found. Cannot start BT provisioning.")
        sys.exit(1)


if __name__ == "__main__":
    main()
