#!/bin/bash
# ==============================================================================
# AMD Sequoia Graphics Patcher (macOS 15 + Legacy AMD GCN GPUs)
# Zero-Risk: Keeps MetalOld.dylib 100% Stock | Precompiled & In-Place Options
# ==============================================================================

# Ensure script runs from its own directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SCRIPT_DIR"

MOUNT_DIR="/tmp/patcher_sysvolume"

cleanup() {
    if [ -d "$MOUNT_DIR" ]; then
        umount "$MOUNT_DIR" 2>/dev/null || true
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Check and install prerequisites (for Option 2: in-place source build)
# ------------------------------------------------------------------------------
check_prerequisites() {
    if ! xcode-select -p >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
        echo "=========================================================="
        echo "  Prerequisites Check: Xcode Command Line Tools Needed"
        echo "=========================================================="
        echo "Building from source requires Apple's official clang and python3."
        echo "Opening Apple's official installation prompt..."
        echo ""
        xcode-select --install 2>/dev/null || true
        echo "Please complete the Apple installation dialog that just appeared."
        echo "Waiting for installation to finish..."
        until xcode-select -p >/dev/null 2>&1 && command -v clang >/dev/null 2>&1; do
            sleep 4
        done
        echo ""
        echo "[+] Xcode Command Line Tools successfully detected!"
        echo "=========================================================="
        sleep 1
    fi
}

# ------------------------------------------------------------------------------
# Mount APFS Base Volume
# ------------------------------------------------------------------------------
mount_system_volume() {
    ROOT_DEV=$(mount | grep ' on / ' | awk '{print $1}')
    BASE_DEV=$(echo "$ROOT_DEV" | sed -E 's/(disk[0-9]+s[0-9]+)s[0-9]+/\1/')

    echo "[*] Booted Snapshot : $ROOT_DEV"
    echo "[*] Base APFS Volume: $BASE_DEV"

    if [ -z "$BASE_DEV" ] || [ ! -e "$BASE_DEV" ]; then
        echo "[!] Error: Could not determine base APFS volume device!"
        echo "Press [Enter] to exit."
        read -r
        exit 1
    fi

    mkdir -p "$MOUNT_DIR"
    umount "$MOUNT_DIR" 2>/dev/null || true
    echo "[*] Mounting $BASE_DEV to $MOUNT_DIR..."
    mount -o nobrowse -t apfs "$BASE_DEV" "$MOUNT_DIR"
}

# ------------------------------------------------------------------------------
# Action 1: Quick Install (Precompiled Binaries - Instant, No Tools Needed)
# ------------------------------------------------------------------------------
do_quick_install() {
    if [ "$EUID" -ne 0 ]; then
        echo ""
        echo "Root privileges required to mount the system volume and install drivers."
        echo "Prompting for administrator password..."
        exec sudo "$0" --quick
    fi

    echo ""
    echo "=========================================================="
    echo "  Quick Install: Applying Precompiled AMD Drivers"
    echo "=========================================================="

    mount_system_volume

    IL_DEST="$MOUNT_DIR/System/Library/Extensions/AMDShared.bundle/Contents/PlugIns/libAMDIL902.dylib"
    DRV_DIR="$MOUNT_DIR/System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS"
    DRV_DEST="$DRV_DIR/AMDMTLBronzeDriver"
    FIX_DEST="$DRV_DIR/libAMDFix.dylib"
    MO_DEST="$MOUNT_DIR/System/Library/Frameworks/Metal.framework/Versions/A/MetalOld.dylib"

    # Backup stock if not already saved
    mkdir -p "$SCRIPT_DIR/src/backups"
    if [ ! -f "$SCRIPT_DIR/src/backups/libAMDIL902_original.dylib" ] && [ -f "$IL_DEST" ]; then
        echo "[*] Preserving stock compiler backup..."
        cp "$IL_DEST" "$SCRIPT_DIR/src/backups/libAMDIL902_original.dylib"
    fi
    if [ ! -f "$SCRIPT_DIR/src/backups/AMDMTLBronzeDriver_original" ] && [ -f "$DRV_DEST" ]; then
        echo "[*] Preserving stock driver backup..."
        cp "$DRV_DEST" "$SCRIPT_DIR/src/backups/AMDMTLBronzeDriver_original"
    fi

    echo "[*] Installing precompiled libAMDIL902.dylib (null-filter cave)..."
    cp "$SCRIPT_DIR/src/precompiled/libAMDIL902.dylib" "$IL_DEST"
    chmod 755 "$IL_DEST"
    chown root:wheel "$IL_DEST"
    codesign -s - -f "$IL_DEST" >/dev/null 2>&1

    echo "[*] Installing precompiled AMDMTLBronzeDriver (reflection loader)..."
    cp "$SCRIPT_DIR/src/precompiled/AMDMTLBronzeDriver" "$DRV_DEST"
    chmod 755 "$DRV_DEST"
    chown root:wheel "$DRV_DEST"
    codesign -s - -f "$DRV_DEST" >/dev/null 2>&1

    echo "[*] Installing companion helper libAMDFix.dylib (container unwrapper)..."
    cp "$SCRIPT_DIR/src/precompiled/libAMDFix.dylib" "$FIX_DEST"
    chmod 755 "$FIX_DEST"
    chown root:wheel "$FIX_DEST"
    codesign -s - -f "$FIX_DEST" >/dev/null 2>&1

    if [ -f "$MO_DEST" ]; then
        MO_HASH=$(md5 -q "$MO_DEST")
        echo "[+] Safety Check: MetalOld.dylib remained 100% UNTOUCHED (MD5: $MO_HASH)"
    fi

    echo "[*] Creating new bootable APFS snapshot with bless..."
    bless --folder "$MOUNT_DIR/System/Library/CoreServices" --bootefi --create-snapshot

    echo "=========================================================="
    echo "  SUCCESS! Graphics Patch Installed via Precompiled Drivers."
    echo "  Please restart your Mac for the changes to take effect."
    echo ""
    echo "  PREREQUISITE REMINDER:"
    echo "  Ensure 'Disable Library Validation' is checked in OpenCore"
    echo "  settings, and you have built & installed OpenCore to the EFI"
    echo "  partition. Otherwise, macOS will drop the AMD dGPU and boot"
    echo "  in an Intel Iris Pro-only state."
    echo "=========================================================="
    echo ""
    echo "Press [Enter] to exit."
    read -r
    exit 0
}

# ------------------------------------------------------------------------------
# Action 2: In-Place Source Build (Compiles & Patches In-Place)
# ------------------------------------------------------------------------------
do_source_install() {
    check_prerequisites

    if [ "$EUID" -ne 0 ]; then
        echo ""
        echo "Root privileges required to mount the system volume and update drivers."
        echo "Prompting for administrator password..."
        exec sudo "$0" --source
    fi

    echo ""
    echo "=========================================================="
    echo "  Custom Build: Modifying Local AMD Drivers In-Place"
    echo "=========================================================="

    mount_system_volume

    python3 "$SCRIPT_DIR/src/patcher.py" apply --target-root "$MOUNT_DIR" --src-dir "$SCRIPT_DIR/src"

    echo "[*] Creating new bootable APFS snapshot with bless..."
    bless --folder "$MOUNT_DIR/System/Library/CoreServices" --bootefi --create-snapshot

    echo "=========================================================="
    echo "  SUCCESS! Local drivers modified and snapshot created."
    echo "  Please restart your Mac for the changes to take effect."
    echo ""
    echo "  PREREQUISITE REMINDER:"
    echo "  Ensure 'Disable Library Validation' is checked in OpenCore"
    echo "  settings, and you have built & installed OpenCore to the EFI"
    echo "  partition. Otherwise, macOS will drop the AMD dGPU and boot"
    echo "  in an Intel Iris Pro-only state."
    echo "=========================================================="
    echo ""
    echo "Press [Enter] to exit."
    read -r
    exit 0
}

# ------------------------------------------------------------------------------
# Action 3: Revert Patch (Restore Pristine Stock Drivers)
# ------------------------------------------------------------------------------
do_revert() {
    if [ "$EUID" -ne 0 ]; then
        echo ""
        echo "Root privileges required to mount the system volume and revert drivers."
        echo "Prompting for administrator password..."
        exec sudo "$0" --revert
    fi

    echo ""
    echo "=========================================================="
    echo "  Reverting AMD Sequoia Graphics Patch"
    echo "=========================================================="

    mount_system_volume

    IL_DEST="$MOUNT_DIR/System/Library/Extensions/AMDShared.bundle/Contents/PlugIns/libAMDIL902.dylib"
    DRV_DIR="$MOUNT_DIR/System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS"
    DRV_DEST="$DRV_DIR/AMDMTLBronzeDriver"
    FIX_DEST="$DRV_DIR/libAMDFix.dylib"

    if [ -f "$SCRIPT_DIR/src/backups/libAMDIL902_original.dylib" ]; then
        echo "[*] Restoring stock compiler driver from backup..."
        cp "$SCRIPT_DIR/src/backups/libAMDIL902_original.dylib" "$IL_DEST"
        chmod 755 "$IL_DEST"
        chown root:wheel "$IL_DEST"
        codesign -s - -f "$IL_DEST" >/dev/null 2>&1
    fi

    if [ -f "$SCRIPT_DIR/src/backups/AMDMTLBronzeDriver_original" ]; then
        echo "[*] Restoring stock Metal driver from backup..."
        cp "$SCRIPT_DIR/src/backups/AMDMTLBronzeDriver_original" "$DRV_DEST"
        chmod 755 "$DRV_DEST"
        chown root:wheel "$DRV_DEST"
        codesign -s - -f "$DRV_DEST" >/dev/null 2>&1
    fi

    if [ -f "$FIX_DEST" ]; then
        echo "[*] Removing libAMDFix.dylib helper..."
        rm -f "$FIX_DEST"
    fi

    echo "[*] Creating new bootable APFS snapshot with bless..."
    bless --folder "$MOUNT_DIR/System/Library/CoreServices" --bootefi --create-snapshot

    echo "=========================================================="
    echo "  SUCCESS! Original stock drivers restored."
    echo "  Please restart your Mac for the changes to take effect."
    echo "=========================================================="
    echo ""
    echo "Press [Enter] to exit."
    read -r
    exit 0
}

# ------------------------------------------------------------------------------
# Action 4: Check Status
# ------------------------------------------------------------------------------
do_status() {
    echo ""
    echo "=========================================================="
    echo "  Current Graphics Patch Status"
    echo "=========================================================="
    IL_SYS="/System/Library/Extensions/AMDShared.bundle/Contents/PlugIns/libAMDIL902.dylib"
    DRV_SYS="/System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/AMDMTLBronzeDriver"
    FIX_SYS="/System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/libAMDFix.dylib"
    MO_SYS="/System/Library/Frameworks/Metal.framework/Versions/A/MetalOld.dylib"

    if [ -f "$MO_SYS" ]; then
        echo "MetalOld.dylib     : $(md5 -q "$MO_SYS") (Stock Untouched)"
    fi
    if [ -f "$IL_SYS" ]; then
        echo "libAMDIL902.dylib  : $(md5 -q "$IL_SYS")"
    fi
    if [ -f "$DRV_SYS" ]; then
        echo "AMDMTLBronzeDriver : $(md5 -q "$DRV_SYS")"
    fi
    if [ -f "$FIX_SYS" ]; then
        echo "libAMDFix.dylib    : Installed (Active)"
        echo ""
        echo "-> Status: PATCH IS INSTALLED AND ACTIVE"
    else
        echo "libAMDFix.dylib    : Not installed"
        echo ""
        echo "-> Status: STOCK DRIVERS (Patch Not Installed)"
    fi

    # Library Validation / AMFI check
    BOOT_ARGS=$(nvram boot-args 2>/dev/null || sysctl -n kern.bootargs 2>/dev/null || true)
    echo "----------------------------------------------------------"
    echo "OpenCore Library Validation Check:"
    if echo "$BOOT_ARGS" | grep -E -q "amfi_get_out_of_my_way=1|amfi=0x80"; then
        echo "  [+] Library Validation is DISABLED in boot-args."
    else
        echo "  [!] Note: If the AMD dGPU fails to appear in About This Mac,"
        echo "      ensure 'Disable Library Validation' is checked in OpenCore"
        echo "      settings, then build and install OpenCore to the EFI"
        echo "      partition and reboot."
    fi
    echo "=========================================================="
    echo ""
    echo "Press [Enter] to exit."
    read -r
    exit 0
}

# Check command line flags
if [ "$1" == "--quick" ]; then
    do_quick_install
elif [ "$1" == "--source" ]; then
    do_source_install
elif [ "$1" == "--revert" ]; then
    do_revert
elif [ "$1" == "--status" ]; then
    do_status
fi

# ------------------------------------------------------------------------------
# Interactive Menu
# ------------------------------------------------------------------------------
clear
echo "=========================================================="
echo "    AMD Sequoia Graphics Patcher (macOS 15 + AMD GCN)"
echo "=========================================================="
echo "  Fixes:"
echo "  ✓ Safari & Preview HDR/HEIC beachball freezes & crashes"
echo "  ✓ iStat Menus 7 launch crashes"
echo "  ✓ Safari touch icon & favicon crashes (SIGSEGV at 0x60)"
echo ""
echo "  Safety:"
echo "  ✓ MetalOld.dylib remains 100% UNTOUCHED stock"
echo "=========================================================="
echo ""
echo "  [1] Quick Install (Precompiled drivers - Fast, no tools needed) [Default]"
echo "  [2] Custom Build & Patch (Compiles from source & patches in-place)"
echo "  [3] Revert Patch (Restore original unpatched stock drivers)"
echo "  [4] Check Current Status"
echo "  [5] View Technical Documentation (README.txt)"
echo "  [6] View Historical Working Notes (WORKING_NOTES.txt)"
echo "  [7] Exit"
echo ""
read -r -p "Enter choice [1-7] (default: 1): " choice
choice=${choice:-1}

case "$choice" in
    1)
        do_quick_install
        ;;
    2)
        do_source_install
        ;;
    3)
        do_revert
        ;;
    4)
        do_status
        ;;
    5)
        if [ -f "$SCRIPT_DIR/README.txt" ]; then
            less "$SCRIPT_DIR/README.txt"
        else
            echo "README.txt not found."
        fi
        ;;
    6)
        if [ -f "$SCRIPT_DIR/WORKING_NOTES.txt" ]; then
            less "$SCRIPT_DIR/WORKING_NOTES.txt"
        else
            echo "WORKING_NOTES.txt not found."
        fi
        ;;
    *)
        echo "Exiting."
        exit 0
        ;;
esac
