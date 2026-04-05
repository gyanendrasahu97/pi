#!/usr/bin/env python3
"""
Smart Room Pi Boot Script (Production Version)

- Reads CPU serial as hardware_id
- Waits for network
- Shows branded splash while loading
- Launches Chromium in kiosk mode with DRM support
- Auto-restarts Chromium if it crashes
- Designed for 200+ Raspberry Pi 3 deployments
"""

import subprocess
import sys
import time
import os
import shutil
import urllib.request

WEB_URL = "https://app.maheshee.online"
SPLASH_PATH = "/opt/smart-room/splash.html"


# ─────────────────────────────────────────────
# Hardware ID
# ─────────────────────────────────────────────
def get_hardware_id():
    try:
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if line.startswith("Serial"):
                    serial = line.strip().split(":")[1].strip()
                    if serial and serial != "0" * len(serial):
                        return serial
    except Exception:
        pass

    try:
        with open("/etc/machine-id", "r") as f:
            return f.read().strip()
    except Exception:
        pass

    return "unknown"


# ─────────────────────────────────────────────
# Network & IP
# ─────────────────────────────────────────────
def get_ip_address():
    try:
        # Try hostname -I first
        result = subprocess.run(["hostname", "-I"], capture_output=True, text=True)
        ips = result.stdout.strip().split()
        if ips:
            return ips[0]
            
        # Fallback to ip route get
        result = subprocess.run(["ip", "route", "get", "1.1.1.1"], capture_output=True, text=True)
        if result.returncode == 0:
            parts = result.stdout.split("src ")
            if len(parts) > 1:
                return parts[1].split()[0]
    except Exception:
        pass
    return "Offline"

def get_ssh_key():
    try:
        # Prefer ed25519
        with open("/etc/ssh/ssh_host_ed25519_key.pub", "r") as f:
            return f.read().strip().split()[1] # returns the base64 part
    except Exception:
        pass
    try:
        # Fallback to rsa
        with open("/etc/ssh/ssh_host_rsa_key.pub", "r") as f:
            return f.read().strip().split()[1]
    except Exception:
        return ""

def wait_for_network(timeout=60):
    start = time.time()
    while time.time() - start < timeout:
        result = subprocess.run(
            ["ip", "-4", "route", "show", "default"],
            capture_output=True,
            text=True,
        )
        if "default" in result.stdout:
            print("[BOOT] Network detected")
            return True
        time.sleep(2)

    print("[BOOT] Network not detected (continuing anyway)")
    return False


# ─────────────────────────────────────────────
# Launch Chromium
# ─────────────────────────────────────────────
CHROMIUM_FLAGS = [
    "--kiosk",
    "--noerrdialogs",
    "--disable-translate",
    "--no-first-run",
    "--disable-infobars",
    "--disable-features=TranslateUI,HardwareMediaKeyHandling",
    "--disable-session-crashed-bubble",
    "--disable-component-update",
    "--autoplay-policy=no-user-gesture-required",
    "--check-for-update-interval=31536000",
    "--disable-pinch",
    "--overscroll-history-navigation=0",
    "--no-sandbox",
    # DRM / Widevine — needed for VdoCipher video playback
    "--enable-features=EncryptedMedia",
    "--enable-cdm-host-verification",
    # GPU acceleration — improves video decode on Pi
    "--use-gl=egl",
    "--enable-gpu-rasterization",
    "--ignore-gpu-blocklist",
    "--enable-features=VaapiVideoDecoder",
]


def launch_chromium(url):
    # Try both binary names (varies by Pi OS version)
    for binary in ["chromium-browser", "chromium"]:
        try:
            subprocess.run([binary, "--version"], capture_output=True, check=True)
            return subprocess.call([binary] + CHROMIUM_FLAGS + [url])
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
    print("[BOOT] ERROR: Chromium not found")
    return 1


# ─────────────────────────────────────────────
# Prepare Splash Screen
# ─────────────────────────────────────────────
def prepare_splash_screen(hw_id, ip, target_url):
    boot_splash_path = "/opt/smart-room/splash_boot.html"
    
    # Check if original template exists
    if not os.path.exists(SPLASH_PATH):
        # Fallback ultra-basic splash
        with open(boot_splash_path, "w") as f:
            f.write(f"<html><body style='background:black;color:white;'><h1>Starting...</h1><p>IP: {ip}</p><script>setTimeout(()=>window.location.replace('{target_url}'), 2500);</script></body></html>")
        return f"file://{boot_splash_path}"
        
    try:
        with open(SPLASH_PATH, "r") as f:
            content = f.read()
            
        content = content.replace("<!--IP_ADDRESS-->", ip)
        content = content.replace("<!--TARGET_URL-->", target_url)
        content = content.replace("Connecting to classroom", "Connecting to classroom...")
        
        with open(boot_splash_path, "w") as f:
            f.write(content)
            
        return f"file://{boot_splash_path}"
    except Exception as e:
        print(f"[BOOT] Failed to prepare splash: {e}")
        return target_url

# ─────────────────────────────────────────────
# Auto Update
# ─────────────────────────────────────────────
def auto_update():
    boot_url = "https://raw.githubusercontent.com/gyanendrasahu97/pi/main/boot.py"
    try:
        req = urllib.request.Request(boot_url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=10) as response:
            remote_code = response.read().decode('utf-8')
            
        with open(__file__, "r") as f:
            local_code = f.read()
            
        # Check if the code is identical or a valid script
        if remote_code and "def main()" in remote_code and local_code != remote_code:
            print("[BOOT] Update available! Downloading and restarting...")
            with open(__file__, "w") as f:
                f.write(remote_code)
            
            # Hand over process to new script
            os.execv(sys.executable, [sys.executable] + sys.argv)
    except Exception as e:
        print(f"[BOOT] Auto-update check failed: {e}")

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
def main():
    hw_id = get_hardware_id()
    
    print(f"[BOOT] Hardware ID: {hw_id}")
    print("[BOOT] Waiting for network...")
    wait_for_network()
    
    # Check for script updates and apply them autonomously
    auto_update()
    
    ip = get_ip_address()
    print(f"[BOOT] IP Address: {ip}")
    
    ssh_key = get_ssh_key()
    if ssh_key:
        print("[BOOT] Got SSH public key")
    
    # Pass IP and SSH key as hash parameters so the frontend web app can capture them
    target_url = f"{WEB_URL}/kiosk-auth#hardware_id={hw_id}&ip={ip}&ssh_key={ssh_key}"
    
    # Prepare local html file that shows splash logic then redirects
    local_url = prepare_splash_screen(hw_id, ip, target_url)

    restart_count = 0

    while True:
        print(f"[BOOT] Launching Chromium with {local_url}...")
        exit_code = launch_chromium(local_url)

        print(f"[BOOT] Chromium exited with code {exit_code}")

        restart_count += 1

        # If repeated fast crashes → cooldown
        if restart_count >= 5:
            print("[BOOT] Too many crashes. Cooling down 30 seconds...")
            time.sleep(30)
            restart_count = 0
        else:
            time.sleep(3)


if __name__ == "__main__":
    main()