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
# Wait for Network (important for classrooms)
# ─────────────────────────────────────────────
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
# Main
# ─────────────────────────────────────────────
def main():
    hw_id = get_hardware_id()
    url = f"{WEB_URL}/kiosk-auth#hardware_id={hw_id}"

    print(f"[BOOT] Hardware ID: {hw_id}")
    print("[BOOT] Waiting for network...")
    wait_for_network()

    restart_count = 0

    while True:
        print("[BOOT] Launching Chromium...")
        exit_code = launch_chromium(url)

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