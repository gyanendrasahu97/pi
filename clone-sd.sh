#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# Clone a configured Pi's SD card to a distributable .img file
#
# Usage (on any Linux/Mac with SD card reader):
#   1. Shut down the configured Pi
#   2. Insert its SD card into this computer
#   3. Run: sudo bash clone-sd.sh
#
# The output .img can be flashed to any number of SD cards.
# Each Pi will auto-identify via its unique CPU serial — no per-device config.
# ══════════════════════════════════════════════════════════════════════

set -e

echo "═══════════════════════════════════════════════"
echo "  Smart Room SD Card Cloner"
echo "═══════════════════════════════════════════════"
echo ""

# Find the SD card device
echo "Available disks:"
if command -v lsblk &>/dev/null; then
    lsblk -d -o NAME,SIZE,MODEL | grep -v "loop"
elif command -v diskutil &>/dev/null; then
    diskutil list external
fi

echo ""
read -rp "Enter SD card device (e.g., /dev/sdb or /dev/disk2): " SD_DEVICE

if [ -z "$SD_DEVICE" ]; then
    echo "ERROR: No device specified"
    exit 1
fi

if [ ! -b "$SD_DEVICE" ]; then
    echo "ERROR: $SD_DEVICE is not a block device"
    exit 1
fi

OUTPUT="smart-room-$(date +%Y%m%d).img"

echo ""
echo "Cloning $SD_DEVICE → $OUTPUT"
echo "This may take 10-30 minutes..."
echo ""

# Clone
dd if="$SD_DEVICE" of="$OUTPUT" bs=4M status=progress

# Shrink (optional, Linux only)
if command -v pishrink.sh &>/dev/null; then
    echo ""
    echo "Shrinking image..."
    pishrink.sh "$OUTPUT"
fi

# Compress
echo ""
echo "Compressing..."
gzip -k "$OUTPUT"

echo ""
echo "═══════════════════════════════════════════════"
echo "  Done!"
echo "═══════════════════════════════════════════════"
echo ""
echo "  Image:      $OUTPUT"
echo "  Compressed: ${OUTPUT}.gz"
echo "  Size:       $(du -h "$OUTPUT" | cut -f1)"
echo ""
echo "  Flash to new SD cards with:"
echo "    sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress"
echo "    OR use Raspberry Pi Imager → Custom Image"
echo ""
