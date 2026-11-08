#!/bin/bash
# ==============================================================================
# AMD Sequoia Graphics Patcher (macOS 15 + Legacy AMD GCN GPUs)
# Zero-Risk: Keeps MetalOld.dylib 100% Stock | Precompiled & In-Place Options
# ==============================================================================

set -e

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
# Base-OS Perl In-Place Patcher (works without Xcode Command Line Tools)
# Applies the verified 0x900 Mach-O header cave to libAMDIL902.dylib (preserving
# live code at 0xAD0430) and injects LC_LOAD_DYLIB into the user's local
# AMDMTLBronzeDriver (preserving OCLP's impostor.dylib on MacPro6,1 / iMac).
# ------------------------------------------------------------------------------
perl_inplace_patch() {
    /usr/bin/perl - "$1" "$2" << 'EOF'
use strict;
use warnings;

my ($mode, $path) = @ARGV;
open(my $fh, '+<:raw', $path) or die "Cannot open $path: $!";
local $/;
my $data = <$fh>;

if ($mode eq 'check_il') {
    my $cave = pack('H*', '4c8d7db84c8da518ffffff488b80800000004885c0740e488b104c89ff4c89e6e85dd30700e9f4d20700');
    my $exp_hook = pack('H*', '488b8080000000488b104c8d7db84c8da518ffffff4c89ff4c89e6e864000000');
    if (substr($data, 0x7DBFE, 1) eq "\xE9" && substr($data, 0x900, length($cave)) eq $cave) {
        print "0x900\n";
    } elsif (substr($data, 0x7DBFE, 1) eq "\xE9" && substr($data, 0xAD0430, 1) eq "\x4C") {
        print "legacy_0xAD0430\n";
    } elsif (substr($data, 0x7DBFE, 32) eq $exp_hook) {
        print "stock\n";
    } else {
        print "unknown\n";
    }
    exit 0;
} elsif ($mode eq 'check_drv') {
    my ($magic, $cpu, $sub, $ft, $ncmds, $sizeofcmds) = unpack('V6', substr($data, 0, 24));
    my $target = "\@loader_path/libAMDFix.dylib";
    if ($magic == 0xFEEDFACF && index(substr($data, 0, 32 + $sizeofcmds), $target) != -1) {
        print "patched\n";
    } else {
        print "stock\n";
    }
    exit 0;
} elsif ($mode eq 'il') {
    my $cave = pack('H*', '4c8d7db84c8da518ffffff488b80800000004885c0740e488b104c89ff4c89e6e85dd30700e9f4d20700');
    if (substr($data, 0x7DBFE, 1) eq "\xE9" && substr($data, 0x900, length($cave)) eq $cave) {
        exit 0;
    }
    my $exp_hook = pack('H*', '488b8080000000488b104c8d7db84c8da518ffffff4c89ff4c89e6e864000000');
    die "Unexpected hook bytes at 0x7DBFE\n" unless substr($data, 0x7DBFE, 32) eq $exp_hook;
    die "Cave 0x900 not zero\n" unless substr($data, 0x900, length($cave)) eq ("\x00" x length($cave));
    die "0xAD0430 unexpected bytes\n" unless substr($data, 0xAD0430, 8) eq pack('H*', 'c336000f110148ba');

    substr($data, 0x900, length($cave)) = $cave;
    substr($data, 0x7DBFE, 32) = pack('H*', 'e9fd2cf8ff') . ("\x90" x 27);
    substr($data, 0x7E9A2, 15) = pack('H*', '4d85e4742e41833c24007527eb0f49');
    substr($data, 0x7F851, 12) = pack('H*', '4d85ed742b41837d00007524');
} elsif ($mode eq 'drv') {
    my ($magic, $cpu, $sub, $ft, $ncmds, $sizeofcmds) = unpack('V6', substr($data, 0, 24));
    die "Not Mach-O 64\n" unless $magic == 0xFEEDFACF;
    my $target = "\@loader_path/libAMDFix.dylib";
    if (index(substr($data, 0, 32 + $sizeofcmds), $target) != -1) {
        exit 0;
    }
    my $pstr = $target . "\x00";
    my $cmdsize = 24 + length($pstr);
    my $pad = (8 - ($cmdsize % 8)) % 8;
    $cmdsize += $pad;
    $pstr .= "\x00" x $pad;
    my $lc = pack('V6', 0xC, $cmdsize, 24, 2, 0x10000, 0x10000) . $pstr;
    substr($data, 32 + $sizeofcmds, $cmdsize) = $lc;
    substr($data, 16, 8) = pack('V2', $ncmds + 1, $sizeofcmds + $cmdsize);
}
seek($fh, 0, 0) or die $!;
print $fh $data;
truncate($fh, length($data)) or die $!;
close($fh);
EOF
}

# ------------------------------------------------------------------------------
# Action 1: Quick Install (In-Place Binary Patch + Precompiled Helper, No CLT)
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
    echo "  Quick Install: Applying AMD Sequoia Graphics Patch"
    echo "=========================================================="

    mount_system_volume

    AMD_SHARED_BUNDLE="$MOUNT_DIR/System/Library/Extensions/AMDShared.bundle"
    IL_DEST="$AMD_SHARED_BUNDLE/Contents/PlugIns/libAMDIL902.dylib"
    BRONZE_BUNDLE="$MOUNT_DIR/System/Library/Extensions/AMDMTLBronzeDriver.bundle"
    DRV_DIR="$BRONZE_BUNDLE/Contents/MacOS"
    DRV_DEST="$DRV_DIR/AMDMTLBronzeDriver"
    FIX_DEST="$DRV_DIR/libAMDFix.dylib"
    MO_DEST="$MOUNT_DIR/System/Library/Frameworks/Metal.framework/Versions/A/MetalOld.dylib"

    mkdir -p "$SCRIPT_DIR/src/backups"
    IL_BACKUP="$SCRIPT_DIR/src/backups/libAMDIL902_original.dylib"
    DRV_BACKUP="$SCRIPT_DIR/src/backups/AMDMTLBronzeDriver_original"

    # Always preserve the user's genuine unpatched local binaries as the backup,
    # even if the git checkout already contained backup files from another Mac model.
    if [ -f "$IL_DEST" ] && [ "$(perl_inplace_patch check_il "$IL_DEST")" == "stock" ]; then
        echo "[*] Preserving local stock compiler backup..."
        cp "$IL_DEST" "$IL_BACKUP"
    fi
    if [ -f "$DRV_DEST" ] && [ "$(perl_inplace_patch check_drv "$DRV_DEST")" == "stock" ]; then
        echo "[*] Preserving local stock Metal driver backup..."
        cp "$DRV_DEST" "$DRV_BACKUP"
    fi

    echo "[*] Patching local libAMDIL902.dylib (0x900 header cave, preserving 0xAD0430)..."
    if [ -f "$IL_BACKUP" ] && [ "$(perl_inplace_patch check_il "$IL_BACKUP")" == "stock" ]; then
        cp "$IL_BACKUP" "$IL_DEST"
    fi
    perl_inplace_patch il "$IL_DEST"
    chmod 755 "$IL_DEST"
    chown root:wheel "$IL_DEST"
    codesign -s - -f "$IL_DEST" >/dev/null 2>&1
    codesign -s - -f "$AMD_SHARED_BUNDLE" >/dev/null 2>&1

    echo "[*] Patching local AMDMTLBronzeDriver in-place (preserving local load commands)..."
    if [ -f "$DRV_BACKUP" ] && [ "$(perl_inplace_patch check_drv "$DRV_BACKUP")" == "stock" ]; then
        cp "$DRV_BACKUP" "$DRV_DEST"
    fi
    perl_inplace_patch drv "$DRV_DEST"
    chmod 755 "$DRV_DEST"
    chown root:wheel "$DRV_DEST"
    codesign -s - -f "$DRV_DEST" >/dev/null 2>&1

    echo "[*] Installing companion helper libAMDFix.dylib..."
    cp "$SCRIPT_DIR/src/precompiled/libAMDFix.dylib" "$FIX_DEST"
    chmod 755 "$FIX_DEST"
    chown root:wheel "$FIX_DEST"
    codesign -s - -f "$FIX_DEST" >/dev/null 2>&1
    codesign -s - -f "$BRONZE_BUNDLE" >/dev/null 2>&1

    if [ -f "$MO_DEST" ]; then
        MO_HASH=$(md5 -q "$MO_DEST")
        echo "[+] Safety Check: MetalOld.dylib remained 100% UNTOUCHED (MD5: $MO_HASH)"
    fi

    echo "[*] Creating new bootable APFS snapshot with bless..."
    bless --folder "$MOUNT_DIR/System/Library/CoreServices" --bootefi --create-snapshot

    echo "=========================================================="
    echo "  SUCCESS! Graphics Patch Installed."
    echo "  Please restart your Mac for the changes to take effect."
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

    AMD_SHARED_BUNDLE="$MOUNT_DIR/System/Library/Extensions/AMDShared.bundle"
    IL_DEST="$AMD_SHARED_BUNDLE/Contents/PlugIns/libAMDIL902.dylib"
    BRONZE_BUNDLE="$MOUNT_DIR/System/Library/Extensions/AMDMTLBronzeDriver.bundle"
    DRV_DIR="$BRONZE_BUNDLE/Contents/MacOS"
    DRV_DEST="$DRV_DIR/AMDMTLBronzeDriver"
    FIX_DEST="$DRV_DIR/libAMDFix.dylib"

    if [ -f "$SCRIPT_DIR/src/backups/libAMDIL902_original.dylib" ]; then
        echo "[*] Restoring stock compiler driver from backup..."
        cp "$SCRIPT_DIR/src/backups/libAMDIL902_original.dylib" "$IL_DEST"
        chmod 755 "$IL_DEST"
        chown root:wheel "$IL_DEST"
        codesign -s - -f "$IL_DEST" >/dev/null 2>&1
        codesign -s - -f "$AMD_SHARED_BUNDLE" >/dev/null 2>&1
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
    codesign -s - -f "$BRONZE_BUNDLE" >/dev/null 2>&1

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
    IMP_SYS="/System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/impostor.dylib"
    MO_SYS="/System/Library/Frameworks/Metal.framework/Versions/A/MetalOld.dylib"

    if [ -f "$MO_SYS" ]; then
        echo "MetalOld.dylib     : $(md5 -q "$MO_SYS") (Stock Untouched)"
    else
        echo "Metal.framework    : Native macOS 15 (impostor.dylib=$( [ -f "$IMP_SYS" ] && echo 'present' || echo 'absent' ))"
    fi
    if [ -f "$IL_SYS" ]; then
        IL_STATE=$(perl_inplace_patch check_il "$IL_SYS" 2>/dev/null || echo "unknown")
        echo "libAMDIL902.dylib  : $(md5 -q "$IL_SYS") (state=$IL_STATE)"
    fi
    if [ -f "$DRV_SYS" ]; then
        echo "AMDMTLBronzeDriver : $(md5 -q "$DRV_SYS")"
    fi
    if [ -f "$FIX_SYS" ]; then
        echo "libAMDFix.dylib    : Installed (Active)"
    else
        echo "libAMDFix.dylib    : Not installed"
    fi

    if [ "${IL_STATE:-}" == "0x900" ]; then
        echo ""
        echo "-> Status: PATCH IS INSTALLED AND ACTIVE (0x900 header cave)"
    elif [ "${IL_STATE:-}" == "legacy_0xAD0430" ]; then
        echo ""
        echo "-> Status: LEGACY PATCH ACTIVE (0xAD0430 cave; re-run install to upgrade to 0x900)"
    else
        echo ""
        echo "-> Status: STOCK DRIVERS (Patch Not Installed)"
    fi

    # Library Validation / AMFI check
    BOOT_ARGS=$(nvram boot-args 2>/dev/null || sysctl -n kern.bootargs 2>/dev/null || true)
    AMFI_POLICY=$(sysctl -n security.mac.amfi.force_policy 2>/dev/null || echo "")
    echo "----------------------------------------------------------"
    echo "OpenCore AMFI / Library Validation Check:"
    if kextstat 2>/dev/null | grep -q "com.dhinakg.AMFIPass" || [ "$AMFI_POLICY" == "0" ]; then
        echo "  [+] OCLP AMFIPass is ACTIVE (security.mac.amfi.force_policy=${AMFI_POLICY:-0})."
    elif echo "$BOOT_ARGS" | grep -E -q "amfi_get_out_of_my_way=1|amfi=0x80"; then
        echo "  [+] Library Validation is DISABLED in boot-args."
    else
        echo "  [!] Note: If the AMD dGPU fails to appear in About This Mac,"
        echo "      ensure AMFIPass is loaded or 'Disable Library Validation' is"
        echo "      checked in OpenCore settings."
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
echo "  ✓ Chromium / Electron ANGLE Metal WebGL2 UBO shader crash"
echo ""
echo "  Safety:"
echo "  ✓ MetalOld.dylib remains 100% UNTOUCHED stock"
echo "  ✓ Uses 0x900 Mach-O header cave (preserves 0xAD0430 code)"
echo "  ✓ Preserves local AMDMTLBronzeDriver (including impostor.dylib)"
echo "=========================================================="
echo ""
echo "  [1] Quick Install (In-place driver patch + precompiled helper) [Default]"
echo "  [2] Custom Build & Patch (Compiles helper from source & patches in-place)"
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
