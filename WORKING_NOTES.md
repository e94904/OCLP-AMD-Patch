# AMD Sequoia Graphics Patcher: Development Working Notes & Historical Log

Historical notes, research logs, and development timeline for macOS 15 Sequoia on legacy AMD GCN GPUs.

> [!NOTE]
> For the primary technical documentation and reverse-engineering guide, see [**`README.md`**](README.md) (or `README.txt`).

---

## Table of Contents
1. [Symptoms: What Broke on macOS 15 Sequoia](#1-symptoms-what-broke-on-macos-15-sequoia)
2. [Supported Hardware & Cross-GPU Compatibility](#2-supported-hardware--cross-gpu-compatibility)
3. [Phase 1: Spindump & Crash Log Forensic Analysis](#3-phase-1-spindump--crash-log-forensic-analysis)
4. [Phase 2: Isolating the Shader (`xdr::convert_image_to_image_loop`)](#4-phase-2-isolating-the-shader-xdrconvert_image_to_image_loop)
5. [Phase 3: Bug 1 — Compiler Crash at `0x7DC05` (`libAMDIL902.dylib`)](#5-phase-3-bug-1--compiler-crash-at-0x7dc05-libamdil902dylib)
6. [Phase 4: Bug 2 — Reflection Crash at `0x910E0` (`MetalOld.dylib`)](#6-phase-4-bug-2--reflection-crash-at-0x910e0-metalolddylib)
7. [The Core Problem: Unexpected Struct Layouts & Container Envelopes](#7-the-core-problem-unexpected-struct-layouts--container-envelopes)
8. [Phase 5: Bug 3 — iStat Menus 7 & SceneKit Render Pipeline Crash](#8-phase-5-bug-3--istat-menus-7--scenekit-render-pipeline-crash)
9. [Phase 6: Bug 4 — Safari `SIGFPE` Divide-by-Zero in `HDRImageConverter_Metal`](#9-phase-6-bug-4--safari-sigfpe-divide-by-zero-in-hdrimageconverter_metal)
10. [Phase 7: Bug 5 — Safari `SIGSEGV` at `0x60` in `HDRImageConverter_Metal encodeInputImage:`](#10-phase-7-bug-5--safari-sigsegv-at-0x60-in-hdrimageconverter_metal-encodeinputimage)
11. [Phase 8: Boot Safety & The 25% Apple Logo Hang](#11-phase-8-boot-safety--the-25-apple-logo-hang)
12. [Phase 9: The Solution — In-Driver Companion (`libAMDFix.dylib`)](#12-phase-9-the-solution--in-driver-companion-libamdfixdylib)
13. [How to Verify Offline (`test_end_to_end.m`)](#13-how-to-verify-offline-test_end_to_endm)
14. [How to Use the Patcher](#14-how-to-use-the-patcher)

---

## 1. Symptoms: What Broke on macOS 15 Sequoia

When running macOS 15 Sequoia on legacy AMD GCN graphics via OCLP, several major issues appeared:
1. **Safari & Preview Freezes**: Opening wide-color (Display P3) websites or viewing `.HEIC` photos in Preview triggered a permanent beachball freeze.
2. **Safari Crash on Specific Websites**: Visiting websites like `theanimecommunity.com` or loading WebKit touch icons caused Safari to instantly crash with `EXC_ARITHMETIC (SIGFPE)`.
3. **Safari Crash on Touch Icons / Favicons**: Processing web icons in WebKit triggered `EXC_BAD_ACCESS (SIGSEGV)` at address `0x0000000000000060`.
4. **iStat Menus 7 Launch Crash**: Crashed with `SIGSEGV` immediately on startup inside SceneKit / `MTLRenderPipelineReflectionInternal`.

---

## 2. Supported Hardware & Cross-GPU Compatibility

### Does this patch fix other AMD Macs with different GPUs?
**Yes, absolutely.** 

In macOS, Apple does not compile individual graphics drivers for every distinct GPU model. Instead, drivers are compiled for broad GPU architectural generations:
* **`AMDMTLBronzeDriver.bundle`**: Apple's unified Metal driver for all **AMD GCN 1 (Southern Islands), GCN 2 (Sea Islands), and GCN 3 (Volcanic Islands)** architectures.
* **`libAMDIL902.dylib`**: The unified Intermediate Language (IL) compiler plugin that translates Metal Shading Language into GCN machine code.

Because OpenCore Legacy Patcher (OCLP) installs the exact same driver bundle (`AMDMTLBronzeDriver.bundle` and `libAMDIL902.dylib`) for **all** GCN 1–3 Macs running macOS Sequoia, the exact same compiler null-dereference bug (`0x7DC05`), reflection container mismatch (`0x910E0`), and ImageIO argument encoder crashes exist identically across all of these models:

| Mac Model | GPU Architecture | GPU Model | Driver Bundle Used |
| :--- | :--- | :--- | :--- |
| **MacBook Pro (Retina, 15", Mid 2015)** | GCN 2 (Sea Islands) | AMD Radeon R9 M370X | `AMDMTLBronzeDriver` + `libAMDIL902` |
| **Mac Pro (Late 2013, "Trash Can")** | GCN 1 (Southern Islands) | Dual AMD FirePro D300 / D500 / D700 | `AMDMTLBronzeDriver` + `libAMDIL902` |
| **iMac (Retina 5K, 27", Late 2014 & Mid 2015)** | GCN 2 (Sea Islands) | AMD Radeon R9 M290X / M295X | `AMDMTLBronzeDriver` + `libAMDIL902` |
| **iMac (Retina 5K, 27", Late 2015)** | GCN 3 (Volcanic Islands) | AMD Radeon R9 M380 / M390 / M395 / M395X | `AMDMTLBronzeDriver` + `libAMDIL902` |
| **iMac (27", Late 2012 & Late 2013)** | GCN 1 (Southern Islands) | AMD Radeon HD 7750M / 7800M series | `AMDMTLBronzeDriver` + `libAMDIL902` |
| **Mac Pro (2010–2012) / Hackintoshes** | GCN 1–3 | AMD HD 7870, 7950, 7970, R9 280, 290, 380, 390 | `AMDMTLBronzeDriver` + `libAMDIL902` |

Because this patch operates directly on the shared `AMDMTLBronzeDriver` and `libAMDIL902.dylib` binaries, applying it repairs the Sequoia graphics stack across **all** of the above Mac models.

*(Note: Modern AMD GPUs like Polaris RX 480/580, Vega 56/64, and Navi RX 5000/6000 use `AMDRadeonX4000`/`X5000`/`X6000` drivers with modern Metal 3 runtimes and do not use `MetalOld.dylib` or `AMDMTLBronzeDriver`, so they never experienced these legacy GCN bugs).*

---

## 3. Phase 1: Spindump & Crash Log Forensic Analysis

### How We Knew Safari Was Stuck in `semaphore_wait_trap`
When Safari froze on an HDR image, macOS system diagnostics (`spindump`) captured the exact call stack of Safari's main thread:

```text
Thread 0x14a0    Thread name "caulk.messenger.shared:17"
37  thread_start + 15 (libsystem_pthread.dylib + 6231) [0x7ff804dfe857]
  37  _pthread_start + 115 (libsystem_pthread.dylib + 24069) [0x7ff804e02e05]
    37  caulk::concurrent::details::worker_thread::run() + 30 (caulk + 6500)
      37  semaphore_wait_trap + 10 (libsystem_kernel.dylib + 2758) [0x7ff804dc0ac6]
```

This proved that Safari was **not** stuck in an infinite CPU loop or rendering glitch. It was blocked in `semaphore_wait_trap`, waiting synchronously for a reply from Apple's background compiler daemon: `com.apple.MTLCompilerService`.

### The Silent Death of `com.apple.MTLCompilerService`
Checking the crash logs (`DiagnosticReports` and system log) revealed why the semaphore never woke up: `MTLCompilerService` had crashed silently in the background:

```text
Launchd throttled processes:
  MTLCompilerService throttled after SIGSEGV: throttled samples 1-25
```

Because `MTLCompilerService` died while compiling, the XPC port died with it. Safari and Preview were left waiting forever on an answer that would never arrive—causing the **indefinite beachball freeze**.

---

## 4. Phase 2: Isolating the Shader (`xdr::convert_image_to_image_loop`)

### How We Found the Exact Shader
Tracing Safari's image decoding pipeline revealed:
`CGImageDestinationAddImage` ➔ `IIOImageDestination::addImage` ➔ `HDRImageConverter_Metal convertImage:toImage:`.

Inside `/System/Library/Frameworks/ImageIO.framework/Versions/A/Resources/default.metallib`, we discovered Apple's precompiled Metal compute shaders used for color-space transformations. The primary HDR compute function is:
**`xdr::convert_image_to_image_loop`** (with constant specialization `xdr::kSamplingSize = {1, 1}`).

### Differential GPU Isolation Test
To isolate whether this failure was caused by the system-wide Metal compiler or the AMD driver specifically, we compiled `xdr::convert_image_to_image_loop` across both GPUs present on the dual-GPU MacBook Pro:
* **Intel Iris Pro GPU (Integrated)**: Compiled and executed successfully in 0.05 seconds.
* **AMD Radeon R9 M370X GPU (Discrete)**: Instantly failed with `Compiler encountered an internal error` and killed `MTLCompilerService` with `SIGSEGV` (exit code 11).

This differential test conclusively isolated the breakdown to the AMD compiler plugin (`libAMDIL902.dylib`), confirming that the fault only occurs when translating this specific compute kernel for AMD GCN hardware.

---

## 5. Phase 3: Bug 1 — Compiler Crash at `0x7DC05` (`libAMDIL902.dylib`)

### Where Did `0x7DC05` Come From? Was It Arbitrary?
It was **not** arbitrary. It came directly from the spindump and crash logs:

```text
5  llvm::amdMtlPlugin::ILPluginHelper::compileShader(...) (libAMDIL902.dylib + 602840) [0x5e64b62d8]
5  llvm::legacy::PassManagerImpl::run(llvm::Module&) (libAMDIL902.dylib + 11340297) [0x5e6ef3a09]
5  llvm::ILMetadataPropagation::runAnalysis(llvm::Module&) (libAMDIL902.dylib + 515582) [0x5e64a0dfe]
5  llvm::ILMetadataPropagation::initializeIABArgTypeSet(llvm::Argument*) + 73 (libAMDIL902.dylib + 515077) [0x5e64a0c05]
```

In the spindump, `libAMDIL902.dylib` was loaded at base address `0x5e6423000`.
The crash occurred at instruction pointer `0x5e64a0c05`.
Subtracting the library base from the instruction pointer:
```
0x5e64a0c05 - 0x5e6423000 = 0x7DC05 (or 515077 in decimal)
```
`0x7DC05` is the exact file offset in `libAMDIL902.dylib` where the CPU encountered the crash.

### Reverse-Engineering the Machine Code at `0x7DC05`
Disassembling `initializeIABArgTypeSet` using `otool -tvV`:

```assembly
0x7DBFE:  leaq    -0x48(%rbp), %r15
0x7DC02:  movq    0x80(%rax), %rax       ## Reads internal argument metadata pointer
0x7DC05:  movq    (%rax), %rdx           ## DEREFERENCE! If rax is NULL -> CRASH!
0x7DC08:  movq    %r15, %rdi
0x7DC0B:  movq    %r12, %rsi
0x7DC0E:  callq   0x7DC82                ## insert into SmallPtrSet
```

### Why Was `0x80(%rax)` NULL?
In LLVM / AMDIL compiler IR, each shader argument is represented by an `llvm::Argument*`. At offset `0x80`, the compiler looks for a pointer to the type descriptor.
* When AMD wrote this driver in 2015 for macOS Monterey/Big Sur, Apple's shader compiler always populated this pointer.
* In macOS 15 Sequoia, modern compute kernels (like ImageIO's HDR kernel) pass arguments where `0x80(%rax)` is NULL (0x0).
* The 2015 driver lacked a null check before `movq (%rax), %rdx`. Dereferencing `0x0` triggered a hardware segmentation fault (`EXC_BAD_ACCESS`).

### The Surgical Fix: Null-Filter Code Cave
We redirected `0x7DBFE` to an assembly code cave at `0xAD0430`:

```assembly
cave:
    leaq    -0x48(%rbp), %r15
    leaq    -0xe8(%rbp), %r12
    movq    0x80(%rax), %rax
    testq   %rax, %rax             ## Check if rax is NULL
    je      skip                   ## If NULL, safely skip dereference and insert!
    movq    (%rax), %rdx           ## Safe to dereference
    movq    %r15, %rdi
    movq    %r12, %rsi
    callq   0x7DC82                ## insert()
skip:
    jmp     0x7DC1E                ## Resume function cleanly
```
With this fix, `MTLCompilerService` compiled the shader in 0.2s without crashing!

---

## 6. Phase 4: Bug 2 — Reflection Crash at `0x910E0` (`MetalOld.dylib`)

Once Bug 1 was fixed, `MTLCompilerService` survived. But when apps inspected the compiled shader reflection, stock `MetalOld.dylib` crashed!

### Where Did `0x910E0` Come From?
It was reported directly in the crash log (`safari crash 2.txt`):

```text
Thread 0 Crashed::  Dispatch queue: com.apple.main-thread
0   MetalOld.dylib   0x10b7f70e0 MTLInputStageReflectionReader::deserialize(...) + 222
1   MetalOld.dylib   0x10b84e83f -[MTLFunctionReflectionInternal initWithDevice:reflectionData:functionType:options:] + 573
2   MetalOld.dylib   0x10b8592e4 __53-[_MTLFunction reflectionWithOptions:binaryArchives:]_block_invoke + 74
```

The base address of `MetalOld.dylib` was `0x10b766000`.
`0x10b7f70e0 - 0x10b766000 = 0x910E0`.
`0x910E0` is the exact file offset in `MetalOld.dylib` where the crash occurred.

### Disassembly of `MTLInputStageReflectionReader::deserialize`
```assembly
0x9109E:  movabsq $0x4e494253504c544d, %rcx  ## ASCII "MTLPSBIN" (Metal Pipeline State Binary)
0x910A8:  cmpq    %rcx, (%rax)               ## Does byte 0 start with "MTLPSBIN"?
0x910AB:  jne     0x910C3                    ## If NOT, jump to legacy fallback!
...
0x910C7:  callq   deserializeUint32()        ## Reads byte 0 as argument count!
0x910E0:  movb    $0x1, -0x50(%rbp, %rax)    ## CRASH: SIGSEGV out-of-bounds stack write!
```

---

## 7. The Core Problem: Unexpected Struct Layouts & Container Envelopes

Based on the forensic disassembly and data structures observed above, this failure occurs because of how the legacy driver and macOS 15 interact: the AMD driver expects arguments and reflection buffers in a fixed legacy format, whereas modern macOS 15 passes complex new argument structures and wraps reflection data inside an unexpected outer container envelope.

Here is how these two structural changes cause downstream failures:

### 1. The Argument Mismatch in the Compiler (`libAMDIL902.dylib`)
* **What macOS 12 Monterey Did**:
  In macOS 12, every shader argument was a simple, legacy type. The compiler generated a non-null Type Descriptor pointer at `0x80(%rax)` for every single argument in the shader.
* **What macOS 15 Sequoia Changed**:
  Apple redesigned ImageIO's HDR shader (`convert_image_to_image_loop`) for modern Apple Silicon and Metal 3. It contains complex structures (`tcIn`, `tcOut`), specialized constants (`kSamplingSize`), and modern buffer tables.
  For these modern arguments, macOS 15 no longer uses the legacy 2015 struct offset at `0x80(%rax)`—it leaves that pointer **NULL (`0x0`)** and transmits the metadata via modern LLVM bitcode dictionaries instead.
* **Why the 2015 Driver Crashed**:
  When the AMD driver loops through the shader's arguments, it expected every argument to have that legacy pointer. Because it lacked a null check, it dereferenced `0x0` on argument #3, crashing `MTLCompilerService` before it could finish!

---

### 2. The "Unexpected Length & 4 Billion Arguments" Issue in `MetalOld.dylib`
* **The Expected Buffer Layout**:
  `MetalOld.dylib` was written for macOS 12. It expected the reflection data to start **immediately at byte 0** with the 8-byte ASCII header `"MTLPSBIN"`.
* **The Extra 80 Bytes**:
  In macOS 15, Apple wrapped the reflection data inside an **80-byte outer envelope/container** (with magic `0xef13c710`):
  ```hex
  Offset 0x00:  10 c7 13 ef 08 00 00 00 12 b1 34 01 ... (macOS 15 Envelope Header)
  Offset 0x50:  4d 54 4c 50 53 42 49 4e  <--- "MTLPSBIN" is 80 bytes down!
  ```
  The buffer was **80 bytes longer** than `MetalOld.dylib` expected; the real data was pushed down to byte 80 (`0x50`).
* **The 4-Billion Arguments Crash**:
  Because `MetalOld.dylib` did not find `"MTLPSBIN"` at byte 0, it treated the stream as an older format where byte 0 represented the argument count.
  It read the first 4 bytes (`0xef13c710`) as a number: in decimal, `0xef13c710` equals **4,011,048,720**.
  Parsing `0xef13c710` as an argument count caused `MetalOld.dylib` to index stack memory for 4 billion argument descriptors. That generated out-of-bounds pointer `0x1ed400000001` and crashed with `SIGSEGV` at `0x910E0`.

---

## 8. Phase 5: Bug 3 — iStat Menus 7 & SceneKit Render Pipeline Crash

When iStat Menus 7 launches, it initializes 3D status meters using Apple's SceneKit framework.
SceneKit creates a **Render Pipeline** with vertex and fragment shaders.

### The Crash
```text
Thread 1 Crashed:: Dispatch queue: com.apple.root.default-qos
0   MetalOld.dylib   0x1d97d00e0 MTLInputStageReflectionReader::deserialize(...) + 222
1   MetalOld.dylib   0x1d9856605 -[MTLRenderPipelineReflectionInternal initWithVertexData:fragmentData:serializedVertexDescriptor:device:options:flags:] + 207
2   MetalOld.dylib   0x1d984a0e1 newRenderPipeline(...) + 590
3   SceneKit         -[SCNMTLResourceManager _createPipelineStateWithDescriptor:desc:pipeline:] + 629
```

### Why It Happened
Just like compute shaders, macOS 15 wraps both `vertexData` and `fragmentData` reflection streams in the `0xef13c710` envelope.
When SceneKit called `initWithVertexData:fragmentData:...`, `MetalOld.dylib` tried to deserialize both raw envelopes and crashed at `+222` (`0x910E0`).

### The Fix
`libAMDFix.dylib` intercepts `-[MTLRenderPipelineReflectionInternal initWithVertexData:fragmentData:...]` (as well as `initWithTileData:...` and `initWithObjectData:...`) and `-[MTLComputePipelineReflectionInternal initWithSerializedData:...]`, transparently slicing off the 80-byte header so that `MetalOld.dylib` receives pristine `"MTLPSBIN"` data for all render and compute pipelines.

---

## 9. Phase 6: Bug 4 — Safari `SIGFPE` Divide-by-Zero in `HDRImageConverter_Metal`

When browsing websites like `theanimecommunity.com` or loading web icons, Safari crashed with:
```text
Exception Type:   EXC_ARITHMETIC (SIGFPE)
Exception Codes:  0x0000000000000001, 0x0000000000000000
Exception Note:   EXC_CORPSE_NOTIFY
Termination Signal: Floating point exception: 8
```

### Disassembly of the Crash
```assembly
ImageIO`-[HDRImageConverter_Metal convertImage:transform:toImage:transform:]:
    0x7ff8137acf4b <+437>: movq   %r14, %rdi             ; r14 is encoder for buffer 1
    0x7ff8137acf4e <+440>: movq   %r13, %rsi             ; @selector(alignment)
    0x7ff8137acf54 <+446>: callq  *0x3229ac8e(%rip)      ; [encoder alignment]
    ...
    0x7ff8137acf8c <+502>: movq   %rax, %rcx             ; %rcx = alignment!
    0x7ff8137acf8f <+505>: leaq   (%rbx,%r14), %rax      ; %rax = (len + align)
    0x7ff8137acf93 <+509>: decq   %rax                   ; %rax = (len + align - 1)
    0x7ff8137acf96 <+512>: xorl   %edx, %edx             ; %rdx = 0
    0x7ff8137acf98 <+514>: divq   %rcx                   ; CPU DIVIDE BY %rcx!
```

### The Root Cause: Unchecked Nil Call & Division by Zero
In `HDRImageConverter_Metal`, ImageIO calls:
`id enc = [fn newArgumentEncoderWithBufferIndex: 1];`
and then calculates aligned memory size with:
`aligned_size = ((enc.encodedLength + enc.alignment - 1) / enc.alignment) * enc.alignment;`

If an argument buffer index is missing in the shader (e.g. buffer 2 or buffer 7 in `xdr::compute_luma_gain_histogram_8x8`), `newArgumentEncoderWithBufferIndex:` returns `nil`.
Apple's ImageIO code **never checks for nil**.
In Objective-C, sending any message to `nil` returns `0`:
`[nil alignment] ➔ 0`!
ImageIO then executes `divq %rcx` where `%rcx = 0`, causing an immediate CPU divide-by-zero hardware trap (`SIGFPE`)!

### The Fix: Automatic Safe Fallback Encoder
In `libAMDFix.dylib`, we hook `newArgumentEncoderWithBufferIndex:` on `_MTLFunction`.
If a requested buffer index does not exist or returns `nil`, `libAMDFix` automatically returns an `AMDFallbackEncoder`:
- `[fallback alignment]` returns `16`
- `[fallback encodedLength]` returns `0`
- Any encoding operations safely no-op.

When ImageIO performs the alignment math:
`((0 + 16 - 1) / 16) * 16 = 0`!
Zero bytes added, **zero division by zero**, and Safari renders the webpage cleanly without crashing!

---

## 10. Phase 7: Bug 5 — Safari `SIGSEGV` at `0x60` in `HDRImageConverter_Metal encodeInputImage:`

Even after preventing the divide-by-zero (`SIGFPE`) trap, visiting websites like `theanimecommunity.com` or loading `crash_reproducer_mirruro_based.html` still crashed Safari with a segmentation fault:

```text
Exception Type:   EXC_BAD_ACCESS (SIGSEGV)
Exception Subtype: KERN_INVALID_ADDRESS at 0x0000000000000060
Termination Signal: Segmentation fault: 11
Faulting Thread:  0
0  ImageIO  -[HDRImageConverter_Metal encodeInputImage:transform:toBuffer:offset:withArgumentEncoder:computeEncoder:index:textures:] + 398
1  ImageIO  -[HDRImageConverter_Metal convertImage:transform:toImage:transform:] + 982
2  ImageIO  -[HDRImageConverter convertImage:toImage:] + 1066
3  ImageIO  IIOConvertHDRData + 235
4  ImageIO  IIOCallConvertHDRData + 227
5  ImageIO  IIOImageDestination::createPixelDataProviderForExtendedRange(...) + 2737
6  ImageIO  IIOImageDestination::addImage(...) + 97
7  ImageIO  CGImageDestinationAddImage + 1262
8  WebCore  WebCore::createIconDataFromBitmaps(...) + 221
```

### Forensic Disassembly of the Crash
Disassembling `-[HDRImageConverter_Metal encodeInputImage:...]` at offset `+353` to `+413`:

```assembly
0x7ff820fafad2 <+353>: movq   0x3349344f(%rip), %rsi    ; "constantDataAtIndex:"
0x7ff820fafad9 <+360>: movl   $0x3, %edx              ; index = 3
0x7ff820fafade <+365>: movq   -0x30(%rbp), %rdi       ; withArgumentEncoder
0x7ff820fafae2 <+369>: callq  *0x3229c100(%rip)       ; [argumentEncoder constantDataAtIndex:3]
0x7ff820fafae8 <+375>: movq   -0x58(%rbp), %rcx       ; pointer to 128-byte 4x4 matrix
0x7ff820fafaec <+379>: vmovups (%rcx), %ymm0
0x7ff820fafaf0 <+383>: vmovups 0x20(%rcx), %ymm1
0x7ff820fafaf5 <+388>: vmovups 0x40(%rcx), %ymm2
0x7ff820fafafa <+393>: vmovups 0x60(%rcx), %ymm3
0x7ff820fafaff <+398>: vmovups %ymm3, 0x60(%rax)      ; CRASH! %rax is NULL (0x0)! 0x0 + 0x60 = 0x60!
0x7ff820fafb04 <+403>: vmovups %ymm2, 0x40(%rax)
0x7ff820fafb09 <+408>: vmovups %ymm1, 0x20(%rax)
0x7ff820fafb0e <+413>: vmovups %ymm0, (%rax)
```

### The Root Cause
1. In WebCore, generating icons (`createIconDataFromBitmaps`) requests color conversions for extended-range / Display P3 images.
2. For kernels where certain argument buffers are missing (such as buffer 2 and 7 in `xdr::compute_luma_gain_histogram_8x8`), the system returns `AMDFallbackEncoder`.
3. ImageIO's encoding methods (`encodeInputImage:`, `encodeOutputImage:`, `encodeInputColorTransform:`, `encodeOutputColorTransform:`, `encodeInputGainTransform:`, `encodeOutputGainTransform:`) immediately invoke:
   `[argumentEncoder constantDataAtIndex: 3]` to retrieve a pointer where they can write 128 bytes of transform matrix.
4. `AMDFallbackEncoder` previously did not implement `constantDataAtIndex:`. It forwarded the invocation to a no-op handler, returning `0x0` (`NULL`) in register `%rax`.
5. ImageIO unconditionally executed `vmovups %ymm3, 0x60(%rax)` without verifying `%rax`. Writing into memory address `0x0 + 0x60 = 0x60` triggered a hardware segmentation fault (`KERN_INVALID_ADDRESS at 0x0000000000000060`).

### The Surgical Fix: Constant Scratch Buffer & Dual Swizzling
1. **`AMDFallbackEncoder`**:
   - Implements a dedicated 4096-byte internal scratch buffer: `char _dummy[4096]`.
   - Implements `- (void *)constantDataAtIndex:(NSUInteger)index { return _dummy; }`.
   - Any 128-byte AVX matrix stores write safely into `_dummy` without crashing.
   - Implements full `<MTLArgumentEncoder>` protocol methods (`setBuffer:`, `setTexture:`, `setSamplerState:`, etc.) and handles selector introspection (`_argInfo:`) so forwarding is never needed.
2. **`BronzeMtlIndirectArgumentBufferEncoder` Swizzle**:
   - Swizzles `constantDataAtIndex:` on the real AMD driver encoder: if the driver returns `NULL` or throws an exception, it automatically returns `dummy[4096]`.
   - Guarantees that neither real nor fallback encoders can ever return a `NULL` pointer to ImageIO.
3. **Robust Encoder Creation Hooks**:
   - Wraps both `newArgumentEncoderWithBufferIndex:` and `newArgumentEncoderWithBufferIndex:reflection:functionReflection:` in `@try / @catch`, allowing real driver encoders to be used whenever possible, and safely returning `AMDFallbackEncoder` if the driver returns `nil` or throws.

---

## 11. Phase 8: Boot Safety & The 25% Apple Logo Hang

### Isn't `MetalOld.dylib` Made by OCLP?
**No.** `MetalOld.dylib` is **not** an open-source driver developed by OCLP.
It is Apple's original, closed-source `Metal.framework` binary from macOS Monterey/Ventura, extracted and redistributed by Dortania/OCLP so that legacy Metal 1 GPUs can run on modern macOS.

### Attempt 9: Modifying `MetalOld.dylib` on Disk (Initial Speculation vs. Reality)
In Attempt 9, we tested patching `MetalOld.dylib` on disk to skip the 80-byte header via a code cave at `0x1df000`.
**Result: The Mac failed to boot, hanging permanently at the 25% progress bar.**

#### Initial Speculation:
We initially speculated that macOS or OpenCore enforced boot-time signature or library validation on `MetalOld.dylib`.

#### Disassembly & What Actually Happened:
Disassembly of the Attempt 9 binary revealed that no signature check occurred:
1. The executable code section (`__TEXT,__text`) ended at `0x14cd7e`. Offset `0x1df000` was unallocated padding before `__DATA`, lacking executable memory page attributes.
2. The cave executed `subq $0x50, -0xf0(%rbp)`, corrupting the caller's stack frame.
3. During early boot (~25% Apple logo), `WindowServer` started and called Metal reflection. Executing invalid memory caused `WindowServer` to crash with `EXC_BAD_ACCESS (SIGSEGV)` in a loop before `loginwindow` could load.

We abandoned Attempt 9 shortly after to prevent affecting other Macs.

### Why We Keep `MetalOld.dylib` 100% Stock on Disk
Despite crash logs pointing to `MetalOld.dylib 0x910E0`, we keep it untouched for three reasons:
1. **`MetalOld.dylib` is not defective**: It parses clean `MTLPSBIN` buffers in milliseconds. Slicing off the 80-byte outer envelope dynamically solves the problem.
2. **Cross-GPU safety**: `MetalOld.dylib` is shared across other legacy GPUs (Nvidia Kepler, Intel HD 4000). Modifying it on disk risks regressions on other Macs.
3. **OCLP update resilience**: OCLP root patches overwrite `MetalOld.dylib` on every system update. Keeping our fix inside `AMDMTLBronzeDriver` ensures the patch survives.

**Strict Rule: `MetalOld.dylib` on disk must remain 100% UNTOUCHED STOCK.**

---

## 12. Phase 9: The Solution — In-Driver Companion (`libAMDFix.dylib`)

Instead of touching `MetalOld.dylib`, we let the AMD driver handle container unwrapping and encoder safety dynamically in memory:

```
[Safari / Preview / App]
       │
       ▼
Loads AMDMTLBronzeDriver (Contains injected LC_LOAD_DYLIB)
       │
       ▼
dyld loads libAMDFix.dylib automatically into process memory
       │
       ▼
1. Unwraps 0xef13c710 reflection containers:
   - Compute functions (MTLFunctionReflectionInternal)
   - Compute pipelines (MTLComputePipelineReflectionInternal)
   - Render pipelines  (MTLRenderPipelineReflectionInternal)
       │
       ▼
2. Guards argument encoders:
   - Provides AMDFallbackEncoder (align=16, len=0, constantData=_dummy) if encoder is nil
   - Swizzles Bronze alignment (never 0) and constantDataAtIndex: (never NULL)
   - Eliminates divide-by-zero (SIGFPE) and NULL dereference (SIGSEGV) in ImageIO
       │
       ▼
Hands clean MTLPSBIN & safe encoders to 100% UNTOUCHED STOCK MetalOld.dylib!
```

---

## 13. How to Verify Offline (`test_end_to_end.m`)

We have included the exact offline verification program inside `src/test_end_to_end.m`.
You can compile and run it anytime without opening Safari:

```bash
cd "portable patcher"
clang -framework Foundation -framework Metal src/test_end_to_end.m -o test_end_to_end
./test_end_to_end
```

**Expected Output:**
```text
========================================================
  AMD GPU + Stock MetalOld.dylib Offline Verification
========================================================
[+] Active Device: AMD Radeon R9 M370X

[Test 1/4] Verifying Render Pipeline Reflection (iStat Menus fix)...
[+] PASS: Render pipeline created cleanly without crashing! (pipe=0x7f9d3f01b800, refl=0x7f9d3d30faf0)

[Test 2/4] Verifying Compute Pipeline Reflection (HEIC / Preview fix)...
[+] PASS: Compute pipeline & reflection created cleanly! (pipe=0x7f9d3d310760, refl=0x600001ca4420)

[Test 3/4] Verifying Argument Encoder Safety (Safari SIGFPE fix)...
    Buffer 1: enc=BronzeMtlIndirectArgumentBufferEncoder align=16 len=144 -> aligned_size=144
    Buffer 2: enc=AMDFallbackEncoder align=16 len=0 -> aligned_size=0
    Buffer 5: enc=BronzeMtlIndirectArgumentBufferEncoder align=16 len=368 -> aligned_size=368
    Buffer 7: enc=AMDFallbackEncoder align=16 len=0 -> aligned_size=0
[+] PASS: All buffer encoders safe, zero divide-by-zero risk!

[Test 4/4] Verifying Constant Data Write Safety (Safari SIGSEGV at 0x60 fix)...
    Buffer 1: enc=BronzeMtlIndirectArgumentBufferEncoder constantData=0x110209010 -> 128-byte write safe!
    Buffer 2: enc=AMDFallbackEncoder constantData=0x7fa4f781c610 -> 128-byte write safe!
    Buffer 5: enc=BronzeMtlIndirectArgumentBufferEncoder constantData=0x110209014 -> 128-byte write safe!
    Buffer 7: enc=AMDFallbackEncoder constantData=0x7fa4f781c610 -> 128-byte write safe!
[+] PASS: All encoders return non-null constantData, zero crash risk!

========================================================
  VERIFICATION COMPLETE: ALL 4 SUBSYSTEMS PASSED (Exit 0)
========================================================
```

---

## 14. How to Use the Patcher

Double-click **`Patch.command`** in Finder. You have two options:

* **[1] Quick Install (Default)**: Applies tested, precompiled drivers in ~3 seconds. Zero dependencies (no Python or Xcode needed).
* **[2] Custom Build & Patch**: Takes the AMD driver already on your system, backs it up, applies the null-check in-place, and compiles `libAMDFix.dylib` from C source.
* **[3] Revert Patch**: Restores pristine stock AMD drivers from `src/backups/`.
* **[4] Check Status**: Inspects driver MD5 checksums to verify active status.

Restart your Mac after applying or reverting!
