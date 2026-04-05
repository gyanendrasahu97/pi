#!/usr/bin/env python3
"""
Smart Room Bluetooth WiFi Provisioning Server

Runs on Pi when no WiFi is available. Advertises via BLE so the mobile app
can discover the Pi and send WiFi credentials over Bluetooth.

Flow:
  1. Pi boots → no internet → this script starts
  2. Advertises as "SmartRoom-XXXX" (last 4 of hardware ID)
  3. Mobile app discovers it → connects → writes WiFi SSID+password
  4. Pi receives credentials → configures WiFi → confirms via read characteristic
  5. Once connected to WiFi → stops advertising

Uses BlueZ D-Bus API (standard Linux Bluetooth stack).

Custom GATT Service:
  Service UUID:        12345678-1234-5678-1234-56789abcdef0
  WiFi Write Char:     12345678-1234-5678-1234-56789abcdef1  (Write)
    - Write JSON: {"ssid": "...", "password": "...", "country": "IN"}
  Status Read Char:    12345678-1234-5678-1234-56789abcdef2  (Read, Notify)
    - Returns JSON: {"status": "waiting|configuring|connected|failed", "ssid": "...", "ip": "..."}
  HardwareID Read:     12345678-1234-5678-1234-56789abcdef3  (Read)
    - Returns hardware_id string
"""
from dbus.mainloop.glib import DBusGMainLoop
import dbus
import dbus.exceptions
import dbus.mainloop.glib
import dbus.service
import json
import subprocess
import sys
import os
import time
import threading

try:
    from gi.repository import GLib
except ImportError:
    import glib as GLib

# ── UUIDs ────────────────────────────────────────────────────────────
SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef0"
WIFI_WRITE_UUID = "12345678-1234-5678-1234-56789abcdef1"
STATUS_READ_UUID = "12345678-1234-5678-1234-56789abcdef2"
HWID_READ_UUID = "12345678-1234-5678-1234-56789abcdef3"

# ── D-Bus constants ──────────────────────────────────────────────────
BLUEZ_SERVICE = "org.bluez"
ADAPTER_IFACE = "org.bluez.Adapter1"
LE_ADVERTISING_MANAGER_IFACE = "org.bluez.LEAdvertisingManager1"
LE_ADVERTISEMENT_IFACE = "org.bluez.LEAdvertisement1"
GATT_MANAGER_IFACE = "org.bluez.GattManager1"
GATT_SERVICE_IFACE = "org.bluez.GattService1"
GATT_CHRC_IFACE = "org.bluez.GattCharacteristic1"
DBUS_OM_IFACE = "org.freedesktop.DBus.ObjectManager"
DBUS_PROP_IFACE = "org.freedesktop.DBus.Properties"

mainloop = None


def get_hardware_id():
    """Read CPU serial."""
    try:
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if line.startswith("Serial"):
                    return line.strip().split(":")[1].strip()
    except Exception:
        pass
    try:
        with open("/etc/machine-id", "r") as f:
            return f.read().strip()[:16]
    except Exception:
        return "unknown"


def is_network_connected():
    """Check if any interface (wlan0 or eth0) has internet."""
    for iface in ["wlan0", "eth0"]:
        try:
            result = subprocess.run(
                ["ip", "-4", "addr", "show", iface],
                capture_output=True, text=True
            )
            if "inet " in result.stdout:
                return True
        except Exception:
            pass
    return False


def get_wifi_ip():
    """Get current WiFi IP address."""
    try:
        result = subprocess.run(
            ["hostname", "-I"],
            capture_output=True, text=True
        )
        return result.stdout.strip().split()[0] if result.stdout.strip() else ""
    except Exception:
        return ""


def apply_wifi_credentials(ssid, password, country="IN"):
    """Apply WiFi credentials. Returns (success, message)."""
    print(f"[BT-WiFi] Applying: SSID={ssid}, Country={country}")

    # Set country
    try:
        subprocess.run(
            ["raspi-config", "nonint", "do_wifi_country", country],
            check=False, capture_output=True
        )
    except FileNotFoundError:
        pass

    # Try nmcli first (Pi OS Bookworm+)
    try:
        result = subprocess.run(["nmcli", "--version"], capture_output=True)
        if result.returncode == 0:
            # Remove old connection
            subprocess.run(
                ["nmcli", "connection", "delete", ssid],
                capture_output=True, check=False
            )
            # Connect
            cmd = ["nmcli", "device", "wifi", "connect", ssid]
            if password:
                cmd += ["password", password]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                return True, "Connected via NetworkManager"
            else:
                return False, result.stderr.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"[BT-WiFi] nmcli not available: {e}")

    # Fallback: wpa_supplicant
    try:
        wpa_conf = "/etc/wpa_supplicant/wpa_supplicant.conf"
        content = f"""ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country={country}

network={{
    ssid="{ssid}"
"""
        if password:
            content += f'    psk="{password}"\n'
        else:
            content += "    key_mgmt=NONE\n"
        content += "}\n"

        with open(wpa_conf, "w") as f:
            f.write(content)

        subprocess.run(["wpa_cli", "-i", "wlan0", "reconfigure"],
                       capture_output=True, check=False)
        subprocess.run(["systemctl", "restart", "dhcpcd"],
                       capture_output=True, check=False)

        # Wait for connection
        for i in range(20):
            time.sleep(1)
            if is_network_connected():
                return True, "Connected via wpa_supplicant"

        return False, "Timeout waiting for connection"
    except Exception as e:
        return False, str(e)


# ══════════════════════════════════════════════════════════════════════
# BLE Advertisement
# ══════════════════════════════════════════════════════════════════════

class Advertisement(dbus.service.Object):
    PATH_BASE = "/org/bluez/smartroom/advertisement"

    def __init__(self, bus, index, ad_type, local_name):
        self.path = f"{self.PATH_BASE}{index}"
        self.bus = bus
        self.ad_type = ad_type
        self.local_name = local_name
        self.service_uuids = [SERVICE_UUID]
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self):
        return {
            LE_ADVERTISEMENT_IFACE: {
                "Type": self.ad_type,
                "LocalName": dbus.String(self.local_name),
                "ServiceUUIDs": dbus.Array(self.service_uuids, signature="s"),
                "Includes": dbus.Array(["tx-power"], signature="s"),
            }
        }

    def get_path(self):
        return dbus.ObjectPath(self.path)

    @dbus.service.method(DBUS_PROP_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != LE_ADVERTISEMENT_IFACE:
            raise dbus.exceptions.DBusException(
                "org.freedesktop.DBus.Error.InvalidArgs")
        return self.get_properties()[LE_ADVERTISEMENT_IFACE]

    @dbus.service.method(LE_ADVERTISEMENT_IFACE, in_signature="", out_signature="")
    def Release(self):
        print(f"[BT-WiFi] Advertisement released")


# ══════════════════════════════════════════════════════════════════════
# GATT Application
# ══════════════════════════════════════════════════════════════════════

class Application(dbus.service.Object):
    def __init__(self, bus):
        self.path = "/org/bluez/smartroom"
        self.services = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_service(self, service):
        self.services.append(service)

    @dbus.service.method(DBUS_OM_IFACE, out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        response = {}
        for service in self.services:
            response[service.get_path()] = service.get_properties()
            for chrc in service.characteristics:
                response[chrc.get_path()] = chrc.get_properties()
        return response


class Service(dbus.service.Object):
    PATH_BASE = "/org/bluez/smartroom/service"

    def __init__(self, bus, index, uuid, primary):
        self.path = f"{self.PATH_BASE}{index}"
        self.bus = bus
        self.uuid = uuid
        self.primary = primary
        self.characteristics = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self):
        return {
            GATT_SERVICE_IFACE: {
                "UUID": self.uuid,
                "Primary": self.primary,
            }
        }

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_characteristic(self, chrc):
        self.characteristics.append(chrc)


class Characteristic(dbus.service.Object):
    def __init__(self, bus, index, uuid, flags, service):
        self.path = f"{service.path}/char{index}"
        self.bus = bus
        self.uuid = uuid
        self.flags = flags
        self.service = service
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self):
        return {
            GATT_CHRC_IFACE: {
                "Service": self.service.get_path(),
                "UUID": self.uuid,
                "Flags": self.flags,
            }
        }

    def get_path(self):
        return dbus.ObjectPath(self.path)

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, options):
        return []

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="aya{sv}")
    def WriteValue(self, value, options):
        pass


# ── Custom Characteristics ───────────────────────────────────────────

class WiFiWriteCharacteristic(Characteristic):
    """Receives WiFi credentials as JSON from mobile app."""

    def __init__(self, bus, index, service, status_chrc):
        Characteristic.__init__(self, bus, index, WIFI_WRITE_UUID,
                                ["write", "write-without-response"], service)
        self.status_chrc = status_chrc

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="aya{sv}")
    def WriteValue(self, value, options):
        raw = bytes(value).decode("utf-8")
        print(f"[BT-WiFi] Received: {raw}")

        try:
            data = json.loads(raw)
            ssid = data.get("ssid", "")
            password = data.get("password", "")
            country = data.get("country", "IN")

            if not ssid:
                self.status_chrc.set_status("failed", error="Missing SSID")
                return

            self.status_chrc.set_status("configuring", ssid=ssid)

            # Apply in a thread so BLE stays responsive
            def do_apply():
                success, msg = apply_wifi_credentials(ssid, password, country)
                if success:
                    ip = get_wifi_ip()
                    self.status_chrc.set_status("connected", ssid=ssid, ip=ip)
                    print(f"[BT-WiFi] WiFi connected! IP: {ip}")

                    # Stop advertising after 10s (let app read final status)
                    time.sleep(10)
                    if mainloop:
                        GLib.idle_add(mainloop.quit)
                else:
                    self.status_chrc.set_status("failed", ssid=ssid, error=msg)
                    print(f"[BT-WiFi] WiFi failed: {msg}")

            threading.Thread(target=do_apply, daemon=True).start()

        except json.JSONDecodeError as e:
            self.status_chrc.set_status("failed", error=f"Invalid JSON: {e}")


class StatusReadCharacteristic(Characteristic):
    """Returns current WiFi provisioning status."""

    def __init__(self, bus, index, service):
        Characteristic.__init__(self, bus, index, STATUS_READ_UUID,
                                ["read", "notify"], service)
        self._status = {
            "status": "waiting",
            "ssid": "",
            "ip": "",
            "hardware_id": get_hardware_id(),
            "error": "",
        }

    def set_status(self, status, ssid="", ip="", error=""):
        self._status["status"] = status
        if ssid:
            self._status["ssid"] = ssid
        if ip:
            self._status["ip"] = ip
        if error:
            self._status["error"] = error

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, options):
        data = json.dumps(self._status).encode("utf-8")
        return dbus.Array(data, signature="y")


class HardwareIDCharacteristic(Characteristic):
    """Returns the Pi hardware ID."""

    def __init__(self, bus, index, service):
        Characteristic.__init__(self, bus, index, HWID_READ_UUID,
                                ["read"], service)
        self.hw_id = get_hardware_id()

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, options):
        return dbus.Array(self.hw_id.encode("utf-8"), signature="y")


# ══════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════

def find_adapter(bus):
    """Find the first Bluetooth adapter."""
    proxy = bus.get_object(BLUEZ_SERVICE, "/")
    manager = dbus.Interface(proxy, DBUS_OM_IFACE)
    objects = manager.GetManagedObjects()

    for path, interfaces in objects.items():
        if ADAPTER_IFACE in interfaces:
            return path

    return None


def main():
    global mainloop

    # Skip if already connected (WiFi or LAN)
    if is_network_connected():
        print("[BT-WiFi] Network already connected (WiFi or LAN). Exiting.")
        return

    print("[BT-WiFi] No network detected. Starting Bluetooth provisioning...")

    hw_id = get_hardware_id()
    device_name = f"SmartRoom-{hw_id[-4:]}"
    print(f"[BT-WiFi] Advertising as: {device_name}")

    # Initialize D-Bus
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    adapter_path = find_adapter(bus)
    if not adapter_path:
        print("[BT-WiFi] ERROR: No Bluetooth adapter found!")
        sys.exit(1)

    # Power on adapter
    adapter_props = dbus.Interface(
        bus.get_object(BLUEZ_SERVICE, adapter_path), DBUS_PROP_IFACE)
    adapter_props.Set(ADAPTER_IFACE, "Powered", dbus.Boolean(True))
    adapter_props.Set(ADAPTER_IFACE, "Alias", dbus.String(device_name))

    # Create GATT application
    app = Application(bus)
    service = Service(bus, 0, SERVICE_UUID, True)

    status_chrc = StatusReadCharacteristic(bus, 1, service)
    wifi_chrc = WiFiWriteCharacteristic(bus, 0, service, status_chrc)
    hwid_chrc = HardwareIDCharacteristic(bus, 2, service)

    service.add_characteristic(wifi_chrc)
    service.add_characteristic(status_chrc)
    service.add_characteristic(hwid_chrc)
    app.add_service(service)

    # Register GATT application
    gatt_manager = dbus.Interface(
        bus.get_object(BLUEZ_SERVICE, adapter_path), GATT_MANAGER_IFACE)
    gatt_manager.RegisterApplication(
        app.get_path(), {},
        reply_handler=lambda: print("[BT-WiFi] GATT registered"),
        error_handler=lambda e: print(f"[BT-WiFi] GATT error: {e}"))

    # Create and register advertisement
    adv = Advertisement(bus, 0, "peripheral", device_name)
    ad_manager = dbus.Interface(
        bus.get_object(BLUEZ_SERVICE, adapter_path),
        LE_ADVERTISING_MANAGER_IFACE)
    ad_manager.RegisterAdvertisement(
        adv.get_path(), {},
        reply_handler=lambda: print("[BT-WiFi] Advertising started"),
        error_handler=lambda e: print(f"[BT-WiFi] Advertising error: {e}"))

    print(f"[BT-WiFi] Ready. Waiting for mobile app connection...")

    mainloop = GLib.MainLoop()
    try:
        mainloop.run()
    except KeyboardInterrupt:
        pass
    finally:
        print("[BT-WiFi] Shutting down.")


if __name__ == "__main__":
    main()
