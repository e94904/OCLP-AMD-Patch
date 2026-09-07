================================================================================
AMD SEQUOIA GRAPHICS DRIVER PATCHER
================================================================================
Documentation for running macOS 15 Sequoia on legacy AMD GCN 1–3 GPUs
(MacBook Pro 15" Mid-2015, Mac Pro 2013, iMac 5K 2014–2015) using OCLP.

This guide documents each of the 5 patches: the trigger, the crash log forensics,
the exact assembly instructions, and the code transformation pipeline.

All original crash reports and stackshot spindumps referenced in this guide
are provided in src/dump logs/ for reference and forensic verification.

For historical development logs and earlier iterations, see WORKING_NOTES.txt.

--------------------------------------------------------------------------------
TABLE OF CONTENTS
--------------------------------------------------------------------------------
1. Architecture Overview & File Roles
2. Prerequisite: OpenCore Library Validation & EFI Rebuild
3. Patch 1: Compiler Null-Dereference at 0x7DC05 (libAMDIL902.dylib)
4. Patch 2: Reflection Deserializer Container Mismatch at 0x910E0 (MetalOld.dylib)
5. Patch 3: SceneKit Render Pipeline Reflection Crash (iStat Menus 7)
6. Patch 4: Indirect Argument Buffer Divide-by-Zero SIGFPE (Safari Touch Icons)
7. Patch 5: Indirect Argument Buffer AVX Store at 0x60 SIGSEGV (Safari Matrix Stores)
8. The Code Transformation Pipeline (patcher.py & libAMDFix.m)
9. Offline Verification Test Suite (test_end_to_end.m)

--------------------------------------------------------------------------------
1. ARCHITECTURE OVERVIEW & FILE ROLES
--------------------------------------------------------------------------------
To maintain boot stability and complete auditability, the system uses two
cooperating components:

1. Metal Shading Language Compiler (libAMDIL902.dylib):
   - In-place binary patch.
   - Relative jump from 0x7DC02 to code cave at 0xAD0430.
   - Tests if argument metadata is NULL before dereferencing.

2. Metal Reflection / Pipeline Framework (MetalOld.dylib):
   - 100% UNTOUCHED stock on disk to isolate changes to AMD and protect other Macs!
   - Guarded dynamically in memory by libAMDFix.dylib via AMDMTLBronzeDriver.

3. AMDMTLBronzeDriver.bundle (Dynamic Userland Driver):
   - Injected with LC_LOAD_DYLIB pointing to @loader_path/libAMDFix.dylib.

4. libAMDFix.dylib (Companion Library):
   - Automatically loaded into applications when the AMD driver is instantiated.
   - Strips 80-byte macOS 15 container envelope from reflection buffers (Patches 2 & 3).
   - Enforces indirect argument encoder alignment >= 16 to prevent SIGFPE (Patch 4).
   - Backs constantDataAtIndex:3 with 4096-byte safe buffer to prevent SIGSEGV (Patch 5).

--------------------------------------------------------------------------------
2. PREREQUISITE: OPENCORE LIBRARY VALIDATION & EFI REBUILD
--------------------------------------------------------------------------------
Because the patched AMDMTLBronzeDriver and companion libAMDFix.dylib are
ad-hoc signed (codesign -f -s -), macOS Apple Mobile File Integrity (AMFI)
blocks them from loading if Library Validation remains active.

When AMFI blocks the patched driver, dyld drops the driver bundle without
an on-screen prompt, and macOS falls back to an Intel Iris Pro-only
configuration. The discrete AMD GPU never initializes.

A. How to Disable Library Validation in OpenCore Legacy Patcher (OCLP):
   1. Launch OpenCore-Patcher.app.
   2. Click Settings (gear icon) -> Security.
   3. Check the box for Disable Library Validation.
   4. Return to the main menu.
   5. Click Build and Install OpenCore.
   6. When prompted, select your internal disk (e.g. disk0) and choose its
      EFI partition (e.g. disk0s1).
   7. Once the installation writes to EFI, reboot your Mac.

   CRITICAL: Toggling "Disable Library Validation" in the OCLP settings GUI
   only changes an internal app preference. You must click "Build and Install
   OpenCore" and write it to the internal EFI partition. If you skip installing
   to the EFI partition, the bootloader configuration remains unchanged on
   reboot, and the AMD driver will not load.

B. Symptoms of a Missing dGPU (Iris-Only State):
   If you skip building and installing OpenCore to the EFI partition, verify
   your state with these four checks:

   1. About This Mac / System Information:
      - Apple menu -> About This Mac -> More Info... -> System Report -> Graphics/Displays.
      - If Library Validation blocked the driver, only "Intel Iris Pro 1536 MB" appears.
        "AMD Radeon R9 M370X" is completely missing from the display list.

   2. Video Playback (YouTube in Safari or Chrome):
      - Play a 1440p or 4K 60fps video on YouTube.
      - Without discrete GPU acceleration, the CPU handles all rendering and
        software decode. You will see heavy dropped frames, visible stuttering,
        and CPU usage spiking toward 100%.

   3. iStat Menus / Menu Bar GPU Monitors:
      - The AMD GPU sensor is missing from the menu bar monitor; only the
        integrated Intel GPU appears.

   4. Console / Unified Log Output:
      - Run in Terminal:
        log show --predicate 'process == "Safari" || senderImagePath contains "AMD"' --last 5m
      - If AMFI rejected the driver, the log reports explicit validation failures:
        code signature in <...> not valid for use in process: library validation failed
        dyld: Library not loaded: @loader_path/libAMDFix.dylib
          Reason: tried: '.../libAMDFix.dylib' (code signature in <...> not valid for use in process: library validation failed)

--------------------------------------------------------------------------------
3. PATCH 1: COMPILER NULL-DEREFERENCE AT 0x7DC05 (libAMDIL902.dylib)
--------------------------------------------------------------------------------

A. The Trigger & Crash Reproducer:
   - Reproducer: src/reproducers/crash_reproducer.html (or any Display P3 / HDR image in Safari).
   - Command: open -a Safari "src/reproducers/crash_reproducer.html"
   - Symptom: Safari locked up into an indefinite spinning beachball.

B. Spindump Forensics:
   - Captured stackshot: src/dump logs/safari_freeze_spindump.txt
   - Safari main thread was stuck on semaphore_wait_trap waiting on MTLCompilerService.
   - Background service com.apple.MTLCompilerService crashed with SIGSEGV
     (full report: src/dump logs/MTLCompilerService-2026-09-03-113557.ips):
     llvm::ILMetadataPropagation::initializeIABArgTypeSet(llvm::Argument*) + 73
   - Base address of libAMDIL902.dylib: 0x5e6423000
   - Crash instruction pointer: 0x5e64a0c05
   - File offset calculation:
     0x5e64a0c05 - 0x5e6423000 = 0x7DC05

C. Disassembly (otool -tvV):
   0x7DBFE:  leaq    -0x48(%rbp), %r15
   0x7DC02:  movq    0x80(%rax), %rax       ## Read argument metadata pointer
   0x7DC05:  movq    (%rax), %rdx           ## DEREFERENCE: If NULL -> SIGSEGV!
   0x7DC08:  movq    %r15, %rdi
   0x7DC0B:  movq    %r12, %rsi
   0x7DC0E:  callq   0x7DC82                ## llvm::SmallPtrSetImpl::insert

   Why was 0x80(%rax) NULL? Why are we discussing tcIn?
   ImageIO's compute shader xdr::convert_image_to_image_loop has arguments:
     #0: imgIn (buffer 1)
     #1: imgOut (buffer 2)
     #2: tcIn (buffer 5) - struct xdr::TransferCharacteristics
     #3: tcOut (buffer 7) - struct xdr::TransferCharacteristics
   In macOS 15, Apple modernized the compiler for Metal 3: for complex structs like
   tcIn, it no longer populates the legacy 2015 descriptor pointer at 0x80(%rax),
   leaving it NULL (0x0).
   On argument #2 (tcIn), 0x80(%rax) reads 0x0. movq (%rax), %rdx dereferences 0x0,
   crashing MTLCompilerService.

D. Why We Use a Code Cave and Why We Use NOPs:
   - The null-check logic requires 22 bytes of machine code.
   - At 0x7DC02, the two instructions being replaced are:
     0x7DC02: movq 0x80(%rax), %rax (7 bytes: 48 8b 80 80 00 00 00)
     0x7DC05: movq (%rax), %rdx     (3 bytes: 48 8b 10)
     Total space: 7 + 3 = 10 bytes. Next instruction is at 0x7DC08.
   - Writing 22 bytes in place would clobber 0x7DC08, 0x7DC0B, and 0x7DC0E.
   - We located zeroed alignment padding in the __TEXT,__text segment at 0xAD0430.
     Because it is inside __TEXT, it has execute permissions (r-x).
   - Relative displacement to cave:
     disp32 = 0xAD0430 - (0x7DC02 + 5) = 0xA52829 -> E9 29 28 A5 00 (5 bytes).
   - Why NOPs (0x90) are required:
     The jump takes 5 bytes, but we replaced 10 bytes of code.
     We pad the remaining 5 bytes with NOPs (90 90 90 90 90) so instruction
     boundaries align perfectly with 0x7DC08!
   - Cave at 0xAD0430:
     movq 0x80(%rax), %rax; testq %rax, %rax; jz 0xAD0443;
     movq (%rax), %rdx; jmpq 0x7DC08; xorq %rdx, %rdx; jmpq 0x7DC08;

--------------------------------------------------------------------------------
4. PATCH 2: REFLECTION DESERIALIZER CONTAINER MISMATCH AT 0x910E0 (MetalOld.dylib)
--------------------------------------------------------------------------------

A. The Trigger & Crash Reproducer:
   - Reproducer: Navigating to theanimecommunity.com or opening src/reproducers/crash_reproducer_mirruro_based.html in Safari.
   - Crash report: src/dump logs/safari crash 2.txt (SIGSEGV at 0x10b7f70e0).
   - File offset: 0x10b7f70e0 - 0x10b766000 (base) = 0x910E0.

B. Disassembly Analysis:
   0x9109E:  movabsq $0x4e494253504c544d, %rcx  ## ASCII "MTLPSBIN"
   0x910A8:  cmpq    %rcx, (%rax)               ## Check byte 0 for "MTLPSBIN"!
   0x910AB:  jne     0x910C3                    ## If NOT equal, jump to legacy fallback!

   Decoding 0x4e494253504c544d in ASCII (little-endian):
   4D='M', 54='T', 4C='L', 50='P', 53='S', 42='B', 49='I', 4E='N' -> "MTLPSBIN".

C. Evolution of Reflection Headers & Fatal Fallback Reader:
   1. macOS 10.13 High Sierra / 10.14 Mojave:
      Reflection buffers had no magic header. The buffer started directly with
      a 32-bit integer indicating argument count.
   2. macOS 10.15 Catalina through macOS 12 Monterey:
      Apple introduced the modern reflection binary format. Every buffer began
      with the 8-byte ASCII header "MTLPSBIN". If byte 0 did not match "MTLPSBIN",
      MetalOld.dylib jumped to the pre-Catalina 10.13 fallback reader at 0x910C3.
   3. macOS 15 Sequoia:
      Apple wrapped reflection data inside an 80-byte outer container starting
      with magic bytes 0xef13c710. The actual "MTLPSBIN" header shifted to offset 80 (0x50).
   4. The Fatal Crash:
      Because byte 0 started with 0xef13c710 instead of "MTLPSBIN", the cmpq check
      failed, branching to the 10.13 fallback reader. The fallback reader read the
      first 4 bytes (0xef13c710) as a 32-bit argument count: 4,011,048,720 arguments.
      It entered a loop indexing stack memory for 4 billion elements, generating an
      invalid address and crashing with SIGSEGV at 0x910E0 (+222).

D. Why We Strip 80 Bytes Off:
   - Slicing off the first 80 bytes places "MTLPSBIN" back at byte 0.
   - The cmpq check succeeds, and MetalOld.dylib executes its modern deserializer.

E. Why MetalOld.dylib Remains Untouched on Disk:
   - Initial Speculation vs. Reality (The 25% Boot Hang in Attempt 9):
     In Attempt 9, we tested patching MetalOld.dylib on disk with a cave at 0x1df000.
     The system hung at the 25% Apple logo. We initially speculated this was boot
     signature validation. Disassembly proved otherwise: there is no boot-time
     signature validation on MetalOld.dylib (OCLP injects AMFIPass and disables SSV).
     Instead, the cave was placed outside executable memory sections, corrupted the
     stack frame (-0xf0(%rbp)), and caused WindowServer to crash with SIGSEGV in a
     loop on boot. Attempt 9 was abandoned to avoid altering shared frameworks.

   - Three Reasons We Keep MetalOld.dylib 100% Stock on Disk:
     1. MetalOld.dylib is not defective: It parses standard MTLPSBIN buffers in
        milliseconds. The issue is macOS 15's outer 80-byte 0xef13c710 envelope,
        which we strip dynamically before passing data to MetalOld.dylib.
     2. Cross-GPU safety: MetalOld.dylib is shared across multiple legacy GPUs
        (Nvidia Kepler, Intel HD 4000). Touching it on disk risks regressions
        on other Macs. Keeping the fix inside libAMDFix.dylib isolates changes
        strictly to AMD systems.
     3. OCLP update resilience: OCLP root patches overwrite MetalOld.dylib on
        system updates. An in-driver companion survives without conflicts.

--------------------------------------------------------------------------------
5. PATCH 3: SCENEKIT RENDER PIPELINE REFLECTION CRASH (iStat Menus 7)
--------------------------------------------------------------------------------

A. The Trigger & Forensics:
   - Trigger: Launching iStat Menus 7 on stock drivers.
   - Log: src/dump logs/istats freeze no crash.txt:
     MTLCompilerService throttled after OS_REASON_METAL
     -[MTLRenderPipelineReflectionInternal initWithVertexData:fragmentData:...] + 207
     MTLInputStageReflectionReader::deserialize(...) + 222 (0x910E0)

B. Root Cause: Separate Entry Point for Render Pipelines:
   - In Patch 2, Safari only created Compute Pipelines via
     -[MTLFunctionReflectionInternal initWithDevice:reflectionData:functionType:options:].
   - iStat Menus 7 uses SceneKit 3D graphics for its status dials and meters.
     SceneKit creates Render Pipelines (linking vertex and fragment shaders) via
     -[MTLRenderPipelineReflectionInternal initWithVertexData:fragmentData:serializedVertexDescriptor:device:options:flags:].
   - macOS 15 wraps both vertexData and fragmentData inside the 80-byte envelope.
   - Because Patch 2 only intercepted the compute entry point, SceneKit passed raw
     envelopes into the render pipeline initializer, crashing MetalOld.dylib at the
     exact same deserializer instruction 0x910E0.

C. The Fix in libAMDFix.dylib:
   - Intercepts -[MTLRenderPipelineReflectionInternal initWithVertexData:fragmentData:...].
   - Passes both vertexData and fragmentData through unwrap_reflection() before
     calling the original implementation.

--------------------------------------------------------------------------------
6. PATCH 4: ARGUMENT ENCODER DIVIDE-BY-ZERO SIGFPE (Safari Touch Icons)
--------------------------------------------------------------------------------

A. The Trigger & Forensics:
   - Trigger: Opening pages with <link rel="apple-touch-icon"> or src/reproducers/crash_reproducer_mirruro_based.html.
   - Log: src/dump logs/Safari-2026-09-05-101320.ips (EXC_ARITHMETIC / SIGFPE).
   - Crashed thread:
     ImageIO -[HDRImageConverter_Metal convertImage:transform:toImage:transform:] + 353
     WebCore::createIconDataFromBitmaps

B. Disassembly & Root Cause:
   0x00: callq *0x3229c100(%rip)     ## [encoder alignment]
   0x06: movq  %rax, %rcx           ## %rcx = alignment
   0x09: leaq  -0x1(%rcx,%rdx), %rax
   0x0d: xorl  %edx, %edx
   0x0f: idivq %rcx                 ## HARDWARE TRAP: Divide by %rcx!

   Why alignment Returned 0 in the 2015 Bronze Driver:
   In 2015 when AMDMTLBronzeDriver was written for OS X 10.11 El Capitan, Indirect
   Argument Buffers (IAB) did not exist (Metal 1 only supported direct argument
   bindings). When Apple introduced IAB in macOS 10.13 and 10.14, Apple backported
   minimal method stubs into legacy drivers so they could satisfy the MTLArgumentEncoder
   protocol without crashing. Because 2015 Bronze had no IAB reflection table hardware
   support on GCN 1-3, -[BronzeMtlIndirectArgumentBufferEncoder alignment] was left as
   an uninitialized stub returning 0 for unmapped or unused buffer slots.

   The Hardware #DE Divide Error:
   macOS 15 Sequoia's HDRImageConverter_Metal assumes modern IAB support and calculates:
     aligned_size = ((len + align - 1) / align) * align
   Because the compiler emits an x86_64 integer division instruction (idivq %rcx)
   where %rcx holds the returned alignment value, passing 0 causes the CPU to trigger
   Interrupt Vector 0 (#DE, Divide Error). The macOS kernel delivers #DE as
   EXC_ARITHMETIC (SIGFPE), killing Safari instantly.

C. Why We Return 16 Instead of 0:
   1. Eliminates the hardware CPU divide-by-zero trap (#DE).
   2. Satisfies Metal specification 16-byte SIMD vector alignment (simd_float4).
   3. Matches Apple Silicon and modern Intel Iris driver parity.

--------------------------------------------------------------------------------
7. PATCH 5: ARGUMENT ENCODER AVX STORE AT 0x60 SIGSEGV (Safari Matrix Stores)
--------------------------------------------------------------------------------

A. The Trigger & Forensics:
   - Trigger: Opening src/reproducers/crash_reproducer_mirruro_based.html after Patch 4 was applied.
   - Log: src/dump logs/Safari-2026-09-05-111003.ips:
     EXC_BAD_ACCESS (SIGSEGV) at 0x0000000000000060 (cr2 = 96, rax = 0).
     Crashed frame: -[HDRImageConverter_Metal encodeInputImage:transform:toBuffer:offset:withArgumentEncoder:computeEncoder:index:textures:] + 398

B. Disassembly (From Crash Stream):
   0x00: movq  0x3349344f(%rip), %rsi   ## selector: constantDataAtIndex:
   0x07: movl  $0x3, %edx                ## argument 1: index 3
   0x0c: movq  -0x30(%rbp), %rdi         ## receiver: argumentEncoder
   0x10: callq *0x3229c100(%rip)        ## objc_msgSend([encoder constantDataAtIndex:3])
   0x16: movq  -0x58(%rbp), %rcx         ## pointer to transform matrix
   0x1a: vmovups (%rcx), %ymm0
   0x1e: vmovups 0x20(%rcx), %ymm1
   0x23: vmovups 0x40(%rcx), %ymm2
   0x28: vmovups 0x60(%rcx), %ymm3
   0x2d: vmovups %ymm3, 0x60(%rax)      ## CRASH: %rax is NULL -> writes to 0x60!

   Why constantDataAtIndex:3 Returned NULL: Tier 1 vs. Tier 2 IAB:
   Metal defines two tiers of Indirect Argument Buffer support:
     Tier 1 (AMD GCN 1-3): IABs can hold textures, samplers, and buffers, but cannot
       store inline constant data directly inside the argument buffer structure.
     Tier 2 (AMD GCN 4+, Intel Gen 9.5+, Apple Silicon): IABs can store inline
       constant data (such as transform matrices and vectors) directly within the buffer.
   macOS 15 assumes Tier 2 IAB support and calls [encoder constantDataAtIndex:3]
   expecting a pointer to write an inline 128-byte affine color transform matrix.
   Because Bronze only implements Tier 1 IAB, its argument encoder has no internal
   backing store for inline constant data at index 3. Under the System V AMD64 ABI,
   return values are placed in register %rax. Bronze returned 0x0 (NULL) in %rax.

   The AVX Vector Store Page Fault:
   Immediately following the call, ImageIO executes four 32-byte AVX vector store
   instructions (vmovups) to copy the 128-byte matrix. With %rax = 0,
   vmovups %ymm3, 0x60(%rax) attempts to write 32 bytes to linear address 0x60.
   The MMU flags address 0x60 as unmapped user data memory, triggering page fault
   trap 14 (no mapping for user data write), delivered as EXC_BAD_ACCESS (SIGSEGV)
   with KERN_INVALID_ADDRESS at 0x60 and cr2 = 96.

C. Why Returning Static 4096-Byte Memory Is Safe:
   1. Headroom: ImageIO writes four 32-byte AVX registers = 128 bytes. 4096 bytes
      provides 32x headroom, preventing buffer overruns.
   2. Memory permissions: static char dummy[4096] resides in __DATA,__bss with full
      read/write permissions (rw-), preventing KERN_PROTECTION_FAILURE.
   3. Hardware safety: Legacy AMD GCN compute shaders sample from bound texture
      registers rather than constant slot 3. Sinking the 128-byte matrix write into
      dummy memory allows ImageIO's setup routine to complete cleanly without side effects.

--------------------------------------------------------------------------------
8. THE CODE TRANSFORMATION PIPELINE (patcher.py & libAMDFix.m)
--------------------------------------------------------------------------------

1. Backup Phase:
   - Original unpatched binaries copied to portable patcher/src/backups/

2. Patch libAMDIL902.dylib:
   - Validate stock MD5 (99d255152b9dc31d1d8a1be52e790a3a).
   - Write relative jump and NOPs at 0x7DC02: \xE9\x29\x28\xA5\x00\x90\x90\x90\x90\x90
   - Write trampoline payload at code cave 0xAD0430.
   - Re-sign: codesign -f -s -

3. Inject AMDMTLBronzeDriver:
   - Validate stock MD5 (9909289bbff9b28a97ec09eefef75f78).
   - Parse Mach-O 64-bit load commands.
   - Append LC_LOAD_DYLIB command pointing to @loader_path/libAMDFix.dylib.
   - Re-sign: codesign -f -s -

4. Compile libAMDFix.dylib (Source Option):
   - clang -dynamiclib -O2 -framework Foundation -framework Metal -lobjc -arch x86_64
   - Re-sign: codesign -f -s -

--------------------------------------------------------------------------------
9. OFFLINE VERIFICATION TEST SUITE (test_end_to_end.m)
--------------------------------------------------------------------------------
Run:
  clang -fobjc-arc -framework Metal -framework Foundation src/test_end_to_end.m -o test_end_to_end
  ./test_end_to_end

Verifies:
  [Test 1/4] Render Pipeline Reflection (iStat Menus fix) -> PASS
  [Test 2/4] Compute Pipeline Reflection (HEIC / Preview fix) -> PASS
  [Test 3/4] Argument Encoder Safety (Safari SIGFPE fix) -> PASS
  [Test 4/4] Constant Data Write Safety (Safari SIGSEGV at 0x60 fix) -> PASS
  Exit Code: 0
================================================================================
