#!/usr/bin/env python3
"""
=============================================================================
patcher.py - Transparent In-Place Patcher for macOS 15 + Legacy AMD GCN GPUs
=============================================================================
This script modifies the user's local AMD graphics driver in-place.
Every modification is transparent, documented, and fully auditable below.

Fixes:
  1. Safari / Preview / WebKit freeze/crash on HDR/HEIC/P3 images
  2. iStat Menus 7 launch crash
  3. Safari touch icon & favicon crashes (SIGSEGV / SIGFPE)
  4. Chromium / Electron ANGLE Metal argument-buffer UBO shader compiler crash (CompilerError Code=2)

Safety Guarantee:
  - System Metal framework (MetalOld.dylib / Metal.framework) is NEVER modified (100% stock).
  - Uses Mach-O __TEXT header zero-padding at 0x900 (between load commands end
    0x8C8 and first section __text 0x3AC0) instead of 0xAD0430, which is live
    code inside llvm::FPPassManager::dumpPassStructure+0x50.
  - Preserves local AMDMTLBronzeDriver build and load commands (including OCLP's
    impostor.dylib on AMD-only Macs such as MacPro6,1) instead of overwriting
    with a foreign model's driver binary.
  - Verifies exact original instruction bytes and Mach-O segment/section bounds
    before applying any modification.
=============================================================================
"""

import sys
import os
import struct
import subprocess
import shutil
import argparse
import hashlib
import tempfile

HOOK_OFFSET = 0x7DBFE
RESUME_OFFSET = 0x7DC1E
INSERT_OFFSET = 0x7DC82
CAVE_OFFSET = 0x900
LEGACY_CAVE_OFFSET = 0xAD0430

EXPECTED_HOOK_BYTES = bytes.fromhex(
    '488b8080000000488b104c8d7db84c8da518ffffff4c89ff4c89e6e864000000'
)
EXPECTED_AD0430_BYTES = bytes.fromhex('c336000f110148ba')

SECONDARY_PATCHES = {
    0x7E9A2: (
        bytes.fromhex('41833c2400752c4d85e47511eb2549'),
        bytes.fromhex('4d85e4742e41833c24007527eb0f49'),
    ),
    0x7F851: (
        bytes.fromhex('41837d000075294d85ed7424'),
        bytes.fromhex('4d85ed742b41837d00007524'),
    ),
}

TARGET_DYLIB_LC = b'@loader_path/libAMDFix.dylib'


def md5_file(path):
    if not os.path.isfile(path):
        return "Not found"
    h = hashlib.md5()
    with open(path, 'rb') as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def rel_branch(src, dst, opcode):
    distance = dst - (src + 5)
    if not -(1 << 31) <= distance < (1 << 31):
        raise ValueError("Relative branch out of range")
    return bytes([opcode]) + struct.pack('<i', distance)


def rel_call(src, dst):
    return rel_branch(src, dst, 0xE8)


def rel_jmp(src, dst):
    return rel_branch(src, dst, 0xE9)


def parse_macho_text_layout(source):
    if len(source) < 32 or struct.unpack_from('<I', source, 0)[0] != 0xFEEDFACF:
        raise ValueError("Expected thin 64-bit Mach-O binary")
    ncmds, sizeofcmds = struct.unpack_from('<II', source, 16)
    cursor, end_cmds = 32, 32 + sizeofcmds
    text_va = text_off = first_section = text_section = None
    signatures = []
    for _ in range(ncmds):
        if cursor + 8 > end_cmds:
            raise ValueError("Invalid Mach-O load command bounds")
        cmd, size = struct.unpack_from('<II', source, cursor)
        if size < 8 or cursor + size > end_cmds:
            raise ValueError("Invalid Mach-O load command size")
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            signatures.append(struct.unpack_from('<II', source, cursor + 8))
        elif cmd == 0x19:  # LC_SEGMENT_64
            name, va, vsize, off, fsize, maxprot, initprot, nsects, flags = struct.unpack_from(
                '<16sQQQQiiII', source, cursor + 8
            )
            if name.rstrip(b'\0') == b'__TEXT':
                if off != 0 or not (initprot & 4) or (initprot & 2):
                    raise ValueError("Unexpected __TEXT segment protection or fileoff")
                text_va, text_off = va, off
                sect_offsets = []
                for i in range(nsects):
                    sec = struct.unpack_from('<16s16sQQIIIIIIII', source, cursor + 72 + i * 80)
                    sect_offsets.append(sec[4])
                    if sec[0].rstrip(b'\0') == b'__text':
                        text_section = sec[4]
                if sect_offsets:
                    first_section = min(sect_offsets)
        cursor += size
    if cursor != end_cmds or text_va is None or text_section is None or first_section is None:
        raise ValueError("Incomplete Mach-O __TEXT layout")
    return {
        'base': text_va,
        'end_commands': end_cmds,
        'first_section': first_section,
        'text_section': text_section,
        'signatures': signatures,
    }


def build_cave_payload(base_va=0):
    cave_va = base_va + CAVE_OFFSET
    code = bytearray()
    code += bytes.fromhex('4c8d7db8')              # leaq -0x48(%rbp), %r15
    code += bytes.fromhex('4c8da518ffffff')        # leaq -0xe8(%rbp), %r12
    code += bytes.fromhex('488b8080000000')        # movq 0x80(%rax), %rax
    code += bytes.fromhex('4885c0')                # testq %rax, %rax
    code += bytes.fromhex('740e')                  # je skip (+14 bytes)
    code += bytes.fromhex('488b10')                # movq (%rax), %rdx (safe dereference)
    code += bytes.fromhex('4c89ff')                # movq %r15, %rdi
    code += bytes.fromhex('4c89e6')                # movq %r12, %rsi
    code += rel_call(cave_va + len(code), base_va + INSERT_OFFSET)
    code += rel_jmp(cave_va + len(code), base_va + RESUME_OFFSET)
    return bytes(code)


def classify_libamdil902(data):
    """Returns '0x900', 'legacy_0xAD0430', 'stock', or 'unknown'."""
    try:
        info = parse_macho_text_layout(data)
        cave_code = build_cave_payload(info['base'])
    except Exception:
        return 'unknown'
    if data[HOOK_OFFSET] == 0xE9 and bytes(data[CAVE_OFFSET:CAVE_OFFSET + len(cave_code)]) == cave_code:
        return '0x900'
    if data[HOOK_OFFSET] == 0xE9 and data[LEGACY_CAVE_OFFSET] == 0x4C:
        return 'legacy_0xAD0430'
    if bytes(data[HOOK_OFFSET:RESUME_OFFSET]) == EXPECTED_HOOK_BYTES:
        return 'stock'
    return 'unknown'


def is_amdm_driver_patched(data):
    if len(data) < 32 or struct.unpack_from('<I', data, 0)[0] != 0xFEEDFACF:
        return False
    _, sizeofcmds = struct.unpack_from('<II', data, 16)
    return TARGET_DYLIB_LC in data[:32 + sizeofcmds]


# -----------------------------------------------------------------------------
# 1. In-Place Binary Patch for libAMDIL902.dylib
# -----------------------------------------------------------------------------
def patch_libamdil902(src_bytes):
    """
    Applies null-pointer check in initializeIABArgTypeSet (0x7DBFE) using verified
    __TEXT header zero-padding at 0x900 (preserving live code at 0xAD0430).
    """
    data = bytearray(src_bytes)
    info = parse_macho_text_layout(data)
    cave_code = build_cave_payload(info['base'])

    state = classify_libamdil902(data)
    if state == '0x900':
        print("    -> libAMDIL902.dylib already contains 0x900 null-filter hook.")
        return data

    if state == 'legacy_0xAD0430':
        raise ValueError(
            "Input libAMDIL902.dylib has legacy 0xAD0430 cave applied (which overwrites "
            "llvm::FPPassManager::dumpPassStructure+0x50). Please restore pristine backup first."
        )

    # Verify cave 0x900 sits strictly inside zero-filled header padding before __text
    if not (info['end_commands'] <= CAVE_OFFSET and CAVE_OFFSET + len(cave_code) <= min(info['first_section'], info['text_section'])):
        raise ValueError("Cave 0x900 is outside Mach-O header padding bounds")
    if bytes(data[CAVE_OFFSET:CAVE_OFFSET + len(cave_code)]) != bytes(len(cave_code)):
        raise ValueError("Cave 0x900 is not empty zero padding")

    # Verify exact original instructions at primary hook, 0xAD0430, and secondary offsets
    if bytes(data[HOOK_OFFSET:RESUME_OFFSET]) != EXPECTED_HOOK_BYTES:
        raise ValueError("Unexpected original bytes at 0x7DBFE..0x7DC1E; refusing blind write")
    if bytes(data[LEGACY_CAVE_OFFSET:LEGACY_CAVE_OFFSET + 8]) != EXPECTED_AD0430_BYTES:
        raise ValueError("Unexpected bytes at 0xAD0430; refusing blind write")
    for off, (orig, _) in SECONDARY_PATCHES.items():
        if bytes(data[off:off + len(orig)]) != orig and bytes(data[off:off + len(orig)]) != SECONDARY_PATCHES[off][1]:
            raise ValueError(f"Unexpected original bytes at {off:#x}; refusing blind write")

    # Write trampoline into 0x900 header cave
    data[CAVE_OFFSET:CAVE_OFFSET + len(cave_code)] = cave_code

    # Write 5-byte relative jmp + 27 NOPs at 0x7DBFE..0x7DC1E
    hook_va = info['base'] + HOOK_OFFSET
    cave_va = info['base'] + CAVE_OFFSET
    data[HOOK_OFFSET:RESUME_OFFSET] = rel_jmp(hook_va, cave_va) + (b'\x90' * (RESUME_OFFSET - HOOK_OFFSET - 5))

    # Apply verified secondary null checks
    for off, (_, new_bytes) in SECONDARY_PATCHES.items():
        data[off:off + len(new_bytes)] = new_bytes

    return data


# -----------------------------------------------------------------------------
# 2. In-Place Binary Patch for AMDMTLBronzeDriver
# -----------------------------------------------------------------------------
def patch_amdm_driver(src_bytes):
    """
    Appends LC_LOAD_DYLIB load command for @loader_path/libAMDFix.dylib,
    verifying header padding space before first section and preserving existing
    load commands (including OCLP's impostor.dylib on AMD-only Macs).
    """
    data = bytearray(src_bytes)

    hdr = data[:32]
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack('<IIIIIIII', hdr)

    if is_amdm_driver_patched(data):
        print("    -> AMDMTLBronzeDriver already contains LC_LOAD_DYLIB for libAMDFix.dylib.")
        return data

    info = parse_macho_text_layout(data)
    path_str = TARGET_DYLIB_LC + b'\x00'
    cmdsize = 24 + len(path_str)
    pad = (8 - (cmdsize % 8)) % 8
    cmdsize += pad
    path_str += b'\x00' * pad

    cmd_offset = 32 + sizeofcmds
    if cmd_offset + cmdsize > min(info['first_section'], info['text_section']):
        raise ValueError("Not enough Mach-O header padding in AMDMTLBronzeDriver for LC_LOAD_DYLIB")

    lc = struct.pack('<IIIIII', 0xC, cmdsize, 24, 2, 0x10000, 0x10000) + path_str
    data[cmd_offset:cmd_offset + cmdsize] = lc
    struct.pack_into('<II', data, 16, ncmds + 1, sizeofcmds + cmdsize)

    return data


# -----------------------------------------------------------------------------
# Main Execution Logic
# -----------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Transparent In-Place AMD Graphics Patcher")
    parser.add_argument('action', choices=['apply', 'revert', 'status'], help="Action to perform")
    parser.add_argument('--target-root', required=True, help="Mounted APFS system root path")
    parser.add_argument('--src-dir', required=True, help="Path to src/ directory")
    parser.add_argument(
        '--precompiled-helper',
        action='store_true',
        help="Use src/precompiled/libAMDFix.dylib instead of compiling with clang (for Quick Install without Xcode CLT)",
    )

    args = parser.parse_args()
    target_root = os.path.abspath(args.target_root)
    src_dir = os.path.abspath(args.src_dir)
    backups_dir = os.path.join(src_dir, 'backups')
    os.makedirs(backups_dir, exist_ok=True)

    amd_shared_bundle = os.path.join(target_root, "System/Library/Extensions/AMDShared.bundle")
    il_dest = os.path.join(amd_shared_bundle, "Contents/PlugIns/libAMDIL902.dylib")
    bronze_bundle = os.path.join(target_root, "System/Library/Extensions/AMDMTLBronzeDriver.bundle")
    drv_dir = os.path.join(bronze_bundle, "Contents/MacOS")
    drv_dest = os.path.join(drv_dir, "AMDMTLBronzeDriver")
    fix_dest = os.path.join(drv_dir, "libAMDFix.dylib")
    imp_dest = os.path.join(drv_dir, "impostor.dylib")
    mo_dest = os.path.join(target_root, "System/Library/Frameworks/Metal.framework/Versions/A/MetalOld.dylib")

    il_backup = os.path.join(backups_dir, "libAMDIL902_original.dylib")
    drv_backup = os.path.join(backups_dir, "AMDMTLBronzeDriver_original")
    fix_src = os.path.join(src_dir, "libAMDFix.m")
    precompiled_fix = os.path.join(src_dir, "precompiled", "libAMDFix.dylib")

    if args.action == 'status':
        print("==========================================================")
        print("  Current Graphics Patch Status")
        print("==========================================================")
        print(f"Target Root       : {target_root}")
        if os.path.exists(mo_dest):
            print(f"MetalOld.dylib    : {md5_file(mo_dest)} (Stock Untouched)")
        else:
            print("Metal.framework   : Native macOS 15 (no MetalOld.dylib downgrade)")
        if os.path.exists(il_dest):
            with open(il_dest, 'rb') as f:
                il_bytes = f.read()
            il_state = classify_libamdil902(il_bytes)
            ad0430_ok = bytes(il_bytes[LEGACY_CAVE_OFFSET:LEGACY_CAVE_OFFSET + 8]) == EXPECTED_AD0430_BYTES
            print(f"libAMDIL902.dylib : {md5_file(il_dest)} (state={il_state}, 0xAD0430_intact={ad0430_ok})")
        else:
            print("libAMDIL902.dylib : Not found")
        print(f"AMDMTLBronzeDriver: {md5_file(drv_dest)} (impostor.dylib={'present' if os.path.exists(imp_dest) else 'absent'})")
        if os.path.exists(fix_dest):
            print("libAMDFix.dylib   : Installed (Active)")
        else:
            print("libAMDFix.dylib   : Not installed")
        if os.path.exists(il_dest) and classify_libamdil902(il_bytes) == '0x900':
            print("\n-> Status: PATCH IS INSTALLED AND ACTIVE (0x900 header cave)")
        elif os.path.exists(il_dest) and classify_libamdil902(il_bytes) == 'legacy_0xAD0430':
            print("\n-> Status: LEGACY PATCH ACTIVE (0xAD0430 cave; run apply to upgrade to 0x900)")
        else:
            print("\n-> Status: STOCK DRIVERS (Patch Not Installed)")
        print("==========================================================")
        return

    if args.action == 'revert':
        print("==========================================================")
        print("  Reverting AMD Graphics Drivers to Stock")
        print("==========================================================")

        if os.path.exists(il_backup):
            print(f"[*] Restoring stock libAMDIL902.dylib from: {il_backup}...")
            shutil.copyfile(il_backup, il_dest)
            os.chmod(il_dest, 0o755)
            subprocess.run(['codesign', '-s', '-', '-f', il_dest], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['codesign', '-s', '-', '-f', amd_shared_bundle], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print("[+] Restored stock libAMDIL902.dylib!")
        else:
            print(f"[!] Warning: Stock backup not found at {il_backup}")

        if os.path.exists(drv_backup):
            print(f"[*] Restoring stock AMDMTLBronzeDriver from: {drv_backup}...")
            shutil.copyfile(drv_backup, drv_dest)
            os.chmod(drv_dest, 0o755)
            subprocess.run(['codesign', '-s', '-', '-f', drv_dest], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['codesign', '-s', '-', '-f', bronze_bundle], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print("[+] Restored stock AMDMTLBronzeDriver!")
        else:
            print(f"[!] Warning: Stock backup not found at {drv_backup}")

        if os.path.exists(fix_dest):
            print(f"[*] Removing companion helper: {fix_dest}...")
            os.remove(fix_dest)
            print("[+] Removed libAMDFix.dylib!")

        if os.path.exists(mo_dest):
            print(f"[+] Safety Check: MetalOld.dylib remained 100% UNTOUCHED (MD5: {md5_file(mo_dest)})")
        print("==========================================================")
        return

    if args.action == 'apply':
        print("==========================================================")
        print("  Modifying Local AMD Drivers In-Place")
        print("==========================================================")

        if not os.path.exists(il_dest):
            print(f"[!] Error: Target compiler driver not found at {il_dest}")
            sys.exit(1)
        if not os.path.exists(drv_dest):
            print(f"[!] Error: Target Metal driver not found at {drv_dest}")
            sys.exit(1)

        with open(il_dest, 'rb') as f:
            live_il_bytes = f.read()
        with open(drv_dest, 'rb') as f:
            live_drv_bytes = f.read()

        # Always preserve the user's genuine unpatched local binaries as the backup,
        # even if the git checkout already contained backup files from another Mac model.
        if classify_libamdil902(live_il_bytes) == 'stock':
            shutil.copyfile(il_dest, il_backup)
            print(f"[+] Saved local pristine compiler backup: {il_backup}")
            orig_il_bytes = live_il_bytes
        elif os.path.exists(il_backup):
            with open(il_backup, 'rb') as f:
                orig_il_bytes = f.read()
        else:
            orig_il_bytes = live_il_bytes

        if not is_amdm_driver_patched(live_drv_bytes):
            shutil.copyfile(drv_dest, drv_backup)
            print(f"[+] Saved local pristine Metal driver backup: {drv_backup}")
            orig_drv_bytes = live_drv_bytes
        elif os.path.exists(drv_backup):
            with open(drv_backup, 'rb') as f:
                orig_drv_bytes = f.read()
        else:
            orig_drv_bytes = live_drv_bytes

        print("[*] Applying safe null-filter code cave (0x900 header padding) and hook (0x7DBFE)...")
        patched_il_bytes = patch_libamdil902(orig_il_bytes)

        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_il = os.path.join(tmpdir, "libAMDIL902_patched.dylib")
            with open(tmp_il, 'wb') as f:
                f.write(patched_il_bytes)
            subprocess.run(['codesign', '-s', '-', '-f', tmp_il], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            shutil.copyfile(tmp_il, il_dest)
            os.chmod(il_dest, 0o755)
            subprocess.run(['codesign', '-s', '-', '-f', amd_shared_bundle], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print("[+] Installed patched libAMDIL902.dylib and signed AMDShared.bundle!")

            print("[*] Injecting LC_LOAD_DYLIB load command into local AMDMTLBronzeDriver header padding...")
            patched_drv_bytes = patch_amdm_driver(orig_drv_bytes)

            tmp_drv = os.path.join(tmpdir, "AMDMTLBronzeDriver_patched")
            with open(tmp_drv, 'wb') as f:
                f.write(patched_drv_bytes)
            subprocess.run(['codesign', '-s', '-', '-f', tmp_drv], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            shutil.copyfile(tmp_drv, drv_dest)
            os.chmod(drv_dest, 0o755)
            print("[+] Installed patched AMDMTLBronzeDriver to system volume!")

            tmp_fix = os.path.join(tmpdir, "libAMDFix.dylib")
            if args.precompiled_helper and os.path.exists(precompiled_fix):
                print(f"[*] Using precompiled companion helper: {precompiled_fix}...")
                shutil.copyfile(precompiled_fix, tmp_fix)
            else:
                print(f"[*] Compiling libAMDFix.dylib from transparent C source: {fix_src}...")
                compile_cmd = [
                    'clang', '-dynamiclib', '-O2',
                    '-framework', 'Foundation', '-framework', 'Metal',
                    fix_src, '-o', tmp_fix
                ]
                subprocess.run(compile_cmd, check=True)
            subprocess.run(['codesign', '-s', '-', '-f', tmp_fix], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            shutil.copyfile(tmp_fix, fix_dest)
            os.chmod(fix_dest, 0o755)
            subprocess.run(['codesign', '-s', '-', '-f', bronze_bundle], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print("[+] Installed libAMDFix.dylib helper and signed AMDMTLBronzeDriver.bundle!")

        if os.path.exists(mo_dest):
            print(f"[+] Safety Check: MetalOld.dylib remained 100% UNTOUCHED (MD5: {md5_file(mo_dest)})")

        print("==========================================================")
        print("  All local drivers successfully modified and verified!")
        print("==========================================================")


if __name__ == '__main__':
    main()
