//
// test_end_to_end.m
// Comprehensive Offline Verification Test for AMD Radeon R9 M370X + Stock MetalOld.dylib
//
// Description:
//   Tests all 4 Metal subsystems against the active GPU and stock MetalOld.dylib:
//     1. Render Pipeline Reflection (validates iStat Menus 7 / SceneKit fix)
//     2. Compute Pipeline Reflection (validates Preview / ImageIO HEIC HDR fix)
//     3. Argument Encoder Divide-by-Zero Safety (validates Safari icon/image SIGFPE fix)
//     4. Constant Data Write Safety (validates Safari icon/image SIGSEGV at 0x60 fix)
//
// Compilation & Execution:
//   clang -framework Foundation -framework Metal test_end_to_end.m -o test_end_to_end
//   ./test_end_to_end
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int main() {
    printf("========================================================\n");
    printf("  AMD GPU + Stock MetalOld.dylib Offline Verification\n");
    printf("========================================================\n");

    // 1. Obtain AMD Device
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    id<MTLDevice> amd = nil;
    for (id<MTLDevice> dev in devices) {
        if ([dev.name containsString:@"AMD"]) amd = dev;
    }
    if (!amd) {
        printf("[!] AMD device not found, falling back to default device...\n");
        amd = MTLCreateSystemDefaultDevice();
    }
    printf("[+] Active Device: %s\n\n", [[amd name] UTF8String]);

    NSError *err = nil;

    // -------------------------------------------------------------------------
    // Test 1: Render Pipeline Reflection (iStat Menus 7 / SceneKit)
    // -------------------------------------------------------------------------
    printf("[Test 1/4] Verifying Render Pipeline Reflection (iStat Menus fix)...\n");
    NSString *renderSrc = @"#include <metal_stdlib>\n"
                          "using namespace metal;\n"
                          "struct VertexOut { float4 pos [[position]]; };\n"
                          "vertex VertexOut vert(uint vid [[vertex_id]]) { VertexOut out; out.pos = float4(0); return out; }\n"
                          "fragment float4 frag(VertexOut in [[stage_in]]) { return float4(1); }\n";
    id<MTLLibrary> rLib = [amd newLibraryWithSource:renderSrc options:nil error:&err];
    if (!rLib) {
        printf("[!] Render library compilation failed: %s\n", [[err localizedDescription] UTF8String]);
        return 1;
    }

    MTLRenderPipelineDescriptor *rDesc = [[MTLRenderPipelineDescriptor alloc] init];
    rDesc.vertexFunction = [rLib newFunctionWithName:@"vert"];
    rDesc.fragmentFunction = [rLib newFunctionWithName:@"frag"];
    rDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    MTLRenderPipelineReflection *rRefl = nil;
    id<MTLRenderPipelineState> rPipe = [amd newRenderPipelineStateWithDescriptor:rDesc
                                                                        options:MTLPipelineOptionArgumentInfo
                                                                     reflection:&rRefl
                                                                          error:&err];
    if (!rPipe || !rRefl) {
        printf("[!] Render pipeline creation failed: %s\n", [[err localizedDescription] UTF8String]);
        return 2;
    }
    printf("[+] PASS: Render pipeline created cleanly without crashing! (pipe=%p, refl=%p)\n\n", rPipe, rRefl);

    // -------------------------------------------------------------------------
    // Test 2: Compute Pipeline Reflection (Preview / HEIC / ImageIO HDR)
    // -------------------------------------------------------------------------
    printf("[Test 2/4] Verifying Compute Pipeline Reflection (HEIC / Preview fix)...\n");
    NSURL *libURL = [NSURL fileURLWithPath:@"/System/Library/Frameworks/ImageIO.framework/Versions/A/Resources/default.metallib"];
    id<MTLLibrary> lib = [amd newLibraryWithURL:libURL error:&err];
    if (!lib) {
        printf("[!] Failed to load default.metallib: %s\n", [[err localizedDescription] UTF8String]);
        return 3;
    }

    MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues alloc] init];
    unsigned short samplingSize[2] = {1, 1};
    [cv setConstantValue:samplingSize type:MTLDataTypeUShort2 withName:@"xdr::kSamplingSize"];

    id<MTLFunction> fn = [lib newFunctionWithName:@"xdr::convert_image_to_image_loop" constantValues:cv error:&err];
    if (!fn) {
        printf("[!] Failed to create specialized function: %s\n", [[err localizedDescription] UTF8String]);
        return 4;
    }

    MTLComputePipelineDescriptor *cDesc = [[MTLComputePipelineDescriptor alloc] init];
    cDesc.computeFunction = fn;
    MTLComputePipelineReflection *cRefl = nil;
    id<MTLComputePipelineState> cPipe = [amd newComputePipelineStateWithDescriptor:cDesc
                                                                         options:MTLPipelineOptionArgumentInfo
                                                                      reflection:&cRefl
                                                                           error:&err];
    if (!cPipe || !cRefl) {
        printf("[!] Compute pipeline creation failed: %s\n", [[err localizedDescription] UTF8String]);
        return 5;
    }
    printf("[+] PASS: Compute pipeline & reflection created cleanly! (pipe=%p, refl=%p)\n\n", cPipe, cRefl);

    // -------------------------------------------------------------------------
    // Test 3: Argument Encoder Divide-by-Zero Safety (Safari SIGFPE fix)
    // -------------------------------------------------------------------------
    printf("[Test 3/4] Verifying Argument Encoder Safety (Safari SIGFPE fix)...\n");
    int testBufs[] = {1, 2, 5, 7};
    for (int i = 0; i < 4; i++) {
        int b = testBufs[i];
        id enc = [fn newArgumentEncoderWithBufferIndex:b];
        NSUInteger align = [enc alignment];
        NSUInteger len = [enc encodedLength];
        if (align == 0) {
            printf("[!] FAIL: Buffer %d returned alignment 0!\n", b);
            return 6;
        }
        NSUInteger total = ((len + align - 1) / align) * align;
        printf("    Buffer %d: enc=%s align=%lu len=%lu -> aligned_size=%lu\n",
               b, object_getClassName(enc), (unsigned long)align, (unsigned long)len, (unsigned long)total);
    }
    printf("[+] PASS: All buffer encoders safe, zero divide-by-zero risk!\n\n");

    // -------------------------------------------------------------------------
    // Test 4: Constant Data Write Safety (Safari Miruro / Icon SIGSEGV fix)
    // -------------------------------------------------------------------------
    printf("[Test 4/4] Verifying Constant Data Write Safety (Safari SIGSEGV at 0x60 fix)...\n");
    id<MTLBuffer> testBuf = [amd newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    int checkBufs[] = {1, 2, 5, 7};
    for (int i = 0; i < 4; i++) {
        int b = checkBufs[i];
        id enc = [fn newArgumentEncoderWithBufferIndex:b];
        [enc setArgumentBuffer:testBuf offset:0];
        void *p = [enc constantDataAtIndex:3];
        if (p == NULL) {
            printf("[!] FAIL: Buffer %d constantDataAtIndex:3 returned NULL! (Will crash at 0x60)\n", b);
            return 7;
        }
        // Simulate ImageIO AVX/SSE 128-byte transform matrix store:
        // vmovups %ymm3, 0x60(%rax); vmovups %ymm2, 0x40(%rax); ...
        memset(p, 0xEE, 128);
        printf("    Buffer %d: enc=%s constantData=%p -> 128-byte write safe!\n",
               b, object_getClassName(enc), p);
    }
    printf("[+] PASS: All encoders return non-null constantData, zero crash risk!\n\n");

    printf("========================================================\n");
    printf("  VERIFICATION COMPLETE: ALL 4 SUBSYSTEMS PASSED (Exit 0)\n");
    printf("========================================================\n");
    return 0;
}
