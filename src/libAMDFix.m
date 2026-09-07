//
// libAMDFix.m
// Portable Metal Reflection & Argument Safety Companion for macOS 15 Sequoia + AMD GCN GPUs
//
// Description:
//   Fixes crashes in macOS 15 Sequoia when running legacy AMD GCN graphics drivers with stock MetalOld.dylib:
//     1. Compute reflection crash (MTLInputStageReflectionReader::deserialize at 0x910E0)
//        affecting Preview / ImageIO HDR/HEIC shaders (xdr::convert_image_to_image_loop).
//     2. Render pipeline reflection crash (MTLInputStageReflectionReader::deserialize at 0x910E0)
//        affecting iStat Menus 7, SceneKit, and 3D applications.
//     3. Argument encoder divide-by-zero crash (SIGFPE in HDRImageConverter_Metal convertImage)
//        affecting Safari on websites with icons/images (e.g. theanimecommunity.com / Miruro).
//
// Root Cause:
//   - macOS 15 MTLCompilerService prepends an 80-byte (0x50) container header (magic 0xef13c710)
//     to compiled reflection data. Stock MetalOld.dylib expects raw MTLPSBIN directly at byte 0.
//     When it sees 0xef13c710, it misinterprets it as 4 billion arguments and segfaults.
//   - In ImageIO, HDRImageConverter_Metal queries [encoder alignment] and calculates buffer sizes
//     using ((len + align - 1) / align) * align via the CPU instruction 'divq %rcx'.
//     If newArgumentEncoderWithBufferIndex returns nil (or if alignment is 0), [nil alignment] returns 0,
//     dividing by zero and crashing Safari with SIGFPE.
//
// Solution:
//   - Transparently unwraps 0xef13c710 reflection containers for all function, compute, and render pipelines.
//   - Provides safe fallback argument encoders (alignment=16, encodedLength=0) so ImageIO never divides by zero.
//   - 100% contained within userland AMD driver; MetalOld.dylib on disk remains 100% pristine and stock.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <os/log.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wproperty-attribute-mismatch"

// -----------------------------------------------------------------------------
// Safe Fallback Argument Encoder
// Prevents divide-by-zero (SIGFPE) and NULL dereference (SIGSEGV) in ImageIO
// -----------------------------------------------------------------------------
@interface AMDFallbackEncoder : NSObject <MTLArgumentEncoder>
@property (readonly) id<MTLDevice> device;
@property (copy) NSString *label;
@property (readonly) NSUInteger encodedLength;
@property (readonly) NSUInteger alignment;
@end

@implementation AMDFallbackEncoder {
    NSString *_label;
    char _dummy[4096];
}
- (id<MTLDevice>)device { return MTLCreateSystemDefaultDevice(); }
- (NSString *)label { return _label ?: @"AMDFallbackEncoder"; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (NSUInteger)encodedLength { return 0; }
- (NSUInteger)alignment { return 16; }

- (void *)constantDataAtIndex:(NSUInteger)index { return _dummy; }
- (void)setArgumentBuffer:(id<MTLBuffer>)argumentBuffer offset:(NSUInteger)offset {}
- (void)setArgumentBuffer:(id<MTLBuffer>)argumentBuffer startOffset:(NSUInteger)startOffset arrayElement:(NSUInteger)arrayElement {}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {}
- (void)setBuffers:(const id<MTLBuffer> *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range {}
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {}
- (void)setTextures:(const id<MTLTexture> *)textures withRange:(NSRange)range {}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {}
- (void)setSamplerStates:(const id<MTLSamplerState> *)samplers withRange:(NSRange)range {}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipeline atIndex:(NSUInteger)index {}
- (void)setRenderPipelineStates:(const id<MTLRenderPipelineState> *)pipelines withRange:(NSRange)range {}
- (void)setComputePipelineState:(id<MTLComputePipelineState>)pipeline atIndex:(NSUInteger)index {}
- (void)setComputePipelineStates:(const id<MTLComputePipelineState> *)pipelines withRange:(NSRange)range {}
- (void)setIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer atIndex:(NSUInteger)index {}
- (void)setIndirectCommandBuffers:(const id<MTLIndirectCommandBuffer> *)indirectCommandBuffers withRange:(NSRange)range {}
- (void)setAccelerationStructure:(id)accelerationStructure atIndex:(NSUInteger)index {}
- (void)setVisibleFunctionTable:(id)visibleFunctionTable atIndex:(NSUInteger)index {}
- (void)setVisibleFunctionTables:(const id<MTLVisibleFunctionTable> *)visibleFunctionTables withRange:(NSRange)range {}
- (void)setIntersectionFunctionTable:(id)intersectionFunctionTable atIndex:(NSUInteger)index {}
- (void)setIntersectionFunctionTables:(const id<MTLIntersectionFunctionTable> *)intersectionFunctionTables withRange:(NSRange)range {}
- (id<MTLArgumentEncoder>)newArgumentEncoderForBufferAtIndex:(NSUInteger)index { return self; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector];
    if (!sig) sig = [NSMethodSignature signatureWithObjCTypes:"v@:@@@@@@@@"];
    return sig;
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    // Safely no-op any unhandled encoding operations
}

- (BOOL)respondsToSelector:(SEL)aSelector { return YES; }
@end
#pragma clang diagnostic pop

// -----------------------------------------------------------------------------
// Reflection Data Unwrapper
// Extracts clean MTLPSBIN subrange from macOS 15 0xef13c710 container
// -----------------------------------------------------------------------------
static dispatch_data_t unwrap_reflection(id data) {
    if (!data) return nil;
    dispatch_data_t dd = (dispatch_data_t)data;
    const void *buf = NULL;
    size_t size = 0;
    dispatch_data_t map = dispatch_data_create_map(dd, &buf, &size);
    if (buf && size > 0x50 && *(const uint32_t *)buf == 0xef13c710) {
        uint64_t offset = *(const uint64_t *)((const char *)buf + 0x10);
        uint64_t len = *(const uint64_t *)((const char *)buf + 0x18);
        if (offset + len <= size && memcmp((const char *)buf + offset, "MTLPSBIN", 8) == 0) {
            return dispatch_data_create_subrange(dd, offset, len);
        }
    }
    return dd;
}

// -----------------------------------------------------------------------------
// 1. MTLFunctionReflectionInternal Hook (Compute Function Reflection)
// -----------------------------------------------------------------------------
static id (*orig_func_init)(id, SEL, id, id, NSUInteger, NSUInteger) = NULL;
static id my_func_init(id self, SEL _cmd, id dev, id data, NSUInteger type, NSUInteger opts) {
    return orig_func_init(self, _cmd, dev, (id)unwrap_reflection(data), type, opts);
}

// -----------------------------------------------------------------------------
// 2. MTLComputePipelineReflectionInternal Hooks (Compute Pipeline Reflection)
// -----------------------------------------------------------------------------
static id (*orig_comp_pipe_init1)(id, SEL, id, id, id, NSUInteger, NSUInteger) = NULL;
static id my_comp_pipe_init1(id self, SEL _cmd, id sdata, id stageDesc, id dev, NSUInteger opts, NSUInteger flags) {
    return orig_comp_pipe_init1(self, _cmd, (id)unwrap_reflection(sdata), stageDesc, dev, opts, flags);
}

static id (*orig_comp_pipe_init2)(id, SEL, id, id, NSUInteger, NSUInteger) = NULL;
static id my_comp_pipe_init2(id self, SEL _cmd, id sdata, id dev, NSUInteger opts, NSUInteger flags) {
    return orig_comp_pipe_init2(self, _cmd, (id)unwrap_reflection(sdata), dev, opts, flags);
}

// -----------------------------------------------------------------------------
// 3. MTLRenderPipelineReflectionInternal Hooks (Render Pipeline Reflection)
// -----------------------------------------------------------------------------
static id (*orig_render_init)(id, SEL, id, id, id, id, NSUInteger, NSUInteger) = NULL;
static id my_render_init(id self, SEL _cmd, id vdata, id fdata, id vdesc, id dev, NSUInteger opts, NSUInteger flags) {
    return orig_render_init(self, _cmd, (id)unwrap_reflection(vdata), (id)unwrap_reflection(fdata), vdesc, dev, opts, flags);
}

static id (*orig_tile_init)(id, SEL, id, NSUInteger, id, NSUInteger, NSUInteger) = NULL;
static id my_tile_init(id self, SEL _cmd, id tdata, NSUInteger ftype, id dev, NSUInteger opts, NSUInteger flags) {
    return orig_tile_init(self, _cmd, (id)unwrap_reflection(tdata), ftype, dev, opts, flags);
}

static id (*orig_mesh_init)(id, SEL, id, id, id, id, NSUInteger, NSUInteger) = NULL;
static id my_mesh_init(id self, SEL _cmd, id odata, id mdata, id fdata, id dev, NSUInteger opts, NSUInteger flags) {
    return orig_mesh_init(self, _cmd, (id)unwrap_reflection(odata), (id)unwrap_reflection(mdata), (id)unwrap_reflection(fdata), dev, opts, flags);
}

// -----------------------------------------------------------------------------
// 4. _MTLFunction Argument Encoder Hooks
// -----------------------------------------------------------------------------
static id (*orig_newArgEnc)(id, SEL, NSUInteger) = NULL;
static id my_newArgEnc(id self, SEL _cmd, NSUInteger bufIdx) {
    id enc = nil;
    @try {
        enc = orig_newArgEnc ? orig_newArgEnc(self, _cmd, bufIdx) : nil;
    } @catch (id ex) {
        enc = nil;
    }
    if (!enc || [enc alignment] == 0) {
        return [[AMDFallbackEncoder alloc] init];
    }
    return enc;
}

static id (*orig_enc_fn)(id, SEL, NSUInteger, id *, id) = NULL;
static id my_enc_fn(id self, SEL _cmd, NSUInteger bufIdx, id *refl, id fnRefl) {
    id enc = nil;
    @try {
        enc = orig_enc_fn ? orig_enc_fn(self, _cmd, bufIdx, refl, fnRefl) : nil;
    } @catch (id ex) {
        enc = nil;
    }
    if (!enc || [enc alignment] == 0) {
        return [[AMDFallbackEncoder alloc] init];
    }
    return enc;
}

// -----------------------------------------------------------------------------
// 5. Bronze Argument Encoder Swizzles
// -----------------------------------------------------------------------------
static NSUInteger (*orig_bronze_align)(id, SEL) = NULL;
static NSUInteger my_bronze_align(id self, SEL _cmd) {
    NSUInteger a = orig_bronze_align ? orig_bronze_align(self, _cmd) : 0;
    return a == 0 ? 16 : a;
}

static void *(*orig_bronze_constData)(id, SEL, NSUInteger) = NULL;
static void *my_bronze_constData(id self, SEL _cmd, NSUInteger idx) {
    static char dummy[4096];
    void *p = NULL;
    @try {
        p = orig_bronze_constData ? orig_bronze_constData(self, _cmd, idx) : NULL;
    } @catch (id ex) {
        p = NULL;
    }
    return p ? p : dummy;
}

// -----------------------------------------------------------------------------
// Hook Installer
// -----------------------------------------------------------------------------
__attribute__((constructor))
static void amdfix_init(void) {
    // 1. Function reflection
    Class fnReflCls = NSClassFromString(@"MTLFunctionReflectionInternal");
    if (fnReflCls) {
        Method m = class_getInstanceMethod(fnReflCls, NSSelectorFromString(@"initWithDevice:reflectionData:functionType:options:"));
        if (m) {
            orig_func_init = (id (*)(id, SEL, id, id, NSUInteger, NSUInteger))method_getImplementation(m);
            method_setImplementation(m, (IMP)my_func_init);
        }
    }

    // 2. Compute pipeline reflection
    Class compReflCls = NSClassFromString(@"MTLComputePipelineReflectionInternal");
    if (compReflCls) {
        Method m1 = class_getInstanceMethod(compReflCls, NSSelectorFromString(@"initWithSerializedData:serializedStageInputDescriptor:device:options:flags:"));
        if (m1) {
            orig_comp_pipe_init1 = (id (*)(id, SEL, id, id, id, NSUInteger, NSUInteger))method_getImplementation(m1);
            method_setImplementation(m1, (IMP)my_comp_pipe_init1);
        }
        Method m2 = class_getInstanceMethod(compReflCls, NSSelectorFromString(@"initWithSerializedData:device:options:flags:"));
        if (m2) {
            orig_comp_pipe_init2 = (id (*)(id, SEL, id, id, NSUInteger, NSUInteger))method_getImplementation(m2);
            method_setImplementation(m2, (IMP)my_comp_pipe_init2);
        }
    }

    // 3. Render pipeline reflection
    Class rdrReflCls = NSClassFromString(@"MTLRenderPipelineReflectionInternal");
    if (rdrReflCls) {
        Method m1 = class_getInstanceMethod(rdrReflCls, NSSelectorFromString(@"initWithVertexData:fragmentData:serializedVertexDescriptor:device:options:flags:"));
        if (m1) {
            orig_render_init = (id (*)(id, SEL, id, id, id, id, NSUInteger, NSUInteger))method_getImplementation(m1);
            method_setImplementation(m1, (IMP)my_render_init);
        }
        Method m2 = class_getInstanceMethod(rdrReflCls, NSSelectorFromString(@"initWithTileData:functionType:device:options:flags:"));
        if (m2) {
            orig_tile_init = (id (*)(id, SEL, id, NSUInteger, id, NSUInteger, NSUInteger))method_getImplementation(m2);
            method_setImplementation(m2, (IMP)my_tile_init);
        }
        Method m3 = class_getInstanceMethod(rdrReflCls, NSSelectorFromString(@"initWithObjectData:meshData:fragmentData:device:options:flags:"));
        if (m3) {
            orig_mesh_init = (id (*)(id, SEL, id, id, id, id, NSUInteger, NSUInteger))method_getImplementation(m3);
            method_setImplementation(m3, (IMP)my_mesh_init);
        }
    }

    // 4. _MTLFunction argument encoders
    Class fnCls = NSClassFromString(@"_MTLFunction");
    if (fnCls) {
        Method m1 = class_getInstanceMethod(fnCls, NSSelectorFromString(@"newArgumentEncoderWithBufferIndex:"));
        if (m1) {
            orig_newArgEnc = (id (*)(id, SEL, NSUInteger))method_getImplementation(m1);
            method_setImplementation(m1, (IMP)my_newArgEnc);
        }
        Method m2 = class_getInstanceMethod(fnCls, NSSelectorFromString(@"newArgumentEncoderWithBufferIndex:reflection:functionReflection:"));
        if (m2) {
            orig_enc_fn = (id (*)(id, SEL, NSUInteger, id *, id))method_getImplementation(m2);
            method_setImplementation(m2, (IMP)my_enc_fn);
        }
    }

    // 5. Bronze encoder alignment & constantData safety
    Class bronzeEncCls = NSClassFromString(@"BronzeMtlIndirectArgumentBufferEncoder");
    if (bronzeEncCls) {
        Method mAlign = class_getInstanceMethod(bronzeEncCls, NSSelectorFromString(@"alignment"));
        if (mAlign) {
            orig_bronze_align = (NSUInteger (*)(id, SEL))method_getImplementation(mAlign);
            method_setImplementation(mAlign, (IMP)my_bronze_align);
        }
        Method mConst = class_getInstanceMethod(bronzeEncCls, NSSelectorFromString(@"constantDataAtIndex:"));
        if (mConst) {
            orig_bronze_constData = (void *(*)(id, SEL, NSUInteger))method_getImplementation(mConst);
            method_setImplementation(mConst, (IMP)my_bronze_constData);
        }
    }
}
