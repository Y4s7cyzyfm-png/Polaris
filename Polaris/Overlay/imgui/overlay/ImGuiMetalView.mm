#import "ImGuiMetalView.h"
#import <QuartzCore/QuartzCore.h>
#import "imgui.h"
#import "imgui_impl_metal.h"
#import "imgui_internal.h"

// main.m 中定义的诊断日志函数 (C linkage)
extern "C" void DiagLog(NSString *fmt, ...);

@interface ImGuiMetalView () <MTKViewDelegate>
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign) CFTimeInterval      lastFrameTime;
@property (nonatomic, assign) BOOL                imguiReady;
@property (nonatomic, strong) NSArray<NSValue *>  *imguiWindowRects;
@end

@implementation ImGuiMetalView

- (instancetype)initWithFrame:(CGRect)frame {
    DiagLog(@"[ImGuiMetalView] initWithFrame: %.0fx%.0f", frame.size.width, frame.size.height);

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    DiagLog(@"  MTLDevice: %@", device ? [device name] : @"NIL! (Metal 不可用)");
    if (!device) {
        DiagLog(@"  [FATAL] Metal 设备创建失败! 悬浮窗将无法显示");
        return nil;
    }

    self = [super initWithFrame:frame device:device];
    if (!self) {
        DiagLog(@"  [FATAL] MTKView initWithFrame:device: 返回 nil!");
        return nil;
    }

    DiagLog(@"  MTKView: OK");
    [self _configureMTKView];
    DiagLog(@"  configureMTKView: OK, commandQueue=%@", _commandQueue ? @"OK" : @"NIL!");
    [self _setupImGui];
    DiagLog(@"  setupImGui: OK, imguiReady=%d", _imguiReady);

    return self;
}

#pragma mark - 私有初始化

- (void)_configureMTKView {
    self.delegate                 = self;
    self.colorPixelFormat         = MTLPixelFormatBGRA8Unorm;
    self.depthStencilPixelFormat  = MTLPixelFormatDepth32Float_Stencil8;
    self.sampleCount              = 1;
    self.framebufferOnly          = NO;
    if (@available(iOS 10.3, *)) {
        self.preferredFramesPerSecond = [UIScreen mainScreen].maximumFramesPerSecond;
    } else {
        self.preferredFramesPerSecond = 60;
    }
    self.multipleTouchEnabled     = YES;
    self.userInteractionEnabled   = YES;

    self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    self.layer.opaque = NO;
    self.opaque       = NO;
    self.backgroundColor = [UIColor clearColor];

    _commandQueue = [self.device newCommandQueue];
}

- (void)_setupImGui {
    DiagLog(@"  [setupImGui] CreateContext...");
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();

    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename  = nullptr;

    DiagLog(@"  [setupImGui] _adaptToDevice (字体加载)...");
    [self _adaptToDevice];

    DiagLog(@"  [setupImGui] StyleColorsDark + tuneStyle...");
    ImGui::StyleColorsDark();
    [self _tuneStyle];

    DiagLog(@"  [setupImGui] ImGui_ImplMetal_Init...");
    ImGui_ImplMetal_Init(self.device);
    _imguiReady   = YES;
    _lastFrameTime = CACurrentMediaTime();
    DiagLog(@"  [setupImGui] 完成, imguiReady=YES");
}

- (void)_adaptToDevice {
    ImGuiIO& io = ImGui::GetIO();
    UIScreen *screen = [UIScreen mainScreen];
    CGFloat   scale  = screen.scale;

    io.DisplaySize             = ImVec2((float)self.bounds.size.width,
                                        (float)self.bounds.size.height);
    io.DisplayFramebufferScale = ImVec2((float)scale, (float)scale);

    // ── 字号按屏幕短边 (pt) 自适应: iPad~768pt → 15, iPhone~400pt → 12 ──
    // 避免仅依赖 UIScreen.scale 导致手机字体反而比平板大
    CGFloat shortSidePt = MIN(self.bounds.size.width, self.bounds.size.height);
    if (shortSidePt < 1.0f) shortSidePt = MIN(screen.bounds.size.width, screen.bounds.size.height);
    float fontSize = roundf((float)shortSidePt / 52.0f);
    if (fontSize < 11.0f) fontSize = 11.0f;
    if (fontSize > 16.0f) fontSize = 16.0f;

    // ── 加载中文字体 (使用 bundle 内的 kjzt.ttf) ──

    // 从 app bundle 或可执行文件同目录查找 kjzt.ttf
    NSString *bundleFontPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"kjzt.ttf"];
    // 插件进程 mainBundle 可能不对, 也尝试可执行文件所在目录
    NSString *execDir = [[[NSProcessInfo processInfo].arguments firstObject] stringByDeletingLastPathComponent];
    NSString *execFontPath = [execDir stringByAppendingPathComponent:@"kjzt.ttf"];

    NSString *fontPath = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundleFontPath]) {
        fontPath = bundleFontPath;
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:execFontPath]) {
        fontPath = execFontPath;
    }

    bool fontLoaded = false;
    if (fontPath) {
        DiagLog(@"  [font] 找到 kjzt.ttf: %@", fontPath);
        ImFontConfig cfg;
        cfg.FontNo = 0;
        cfg.OversampleH = 1;
        cfg.OversampleV = 1;
        cfg.PixelSnapH = true;
        // 精简字符范围: Latin + 中文标点 + 常用汉字 (约 6700 字)
        static const ImWchar ranges[] = {
            0x0020, 0x00FF, // Latin
            0x2000, 0x206F, // General Punctuation
            0x3000, 0x303F, // CJK Symbols and Punctuation
            0x4E00, 0x9FFF, // CJK Unified Ideographs
            0xFF00, 0xFF5E, // Fullwidth ASCII
            0,
        };
        cfg.GlyphRanges = ranges;
        DiagLog(@"  [font] AddFontFromFileTTF 开始...");
        ImFont* font = io.Fonts->AddFontFromFileTTF(
            [fontPath UTF8String], fontSize, &cfg, ranges);
        DiagLog(@"  [font] AddFontFromFileTTF 结果: %@", font ? @"OK" : @"FAILED");
        if (font) {
            fontLoaded = true;
            DiagLog(@"  [font] 字体加载成功 (%.0fpx)", fontSize);
        }
    } else {
        DiagLog(@"  [font] kjzt.ttf 未找到! bundle=%@ exec=%@", bundleFontPath, execFontPath);
    }

    if (!fontLoaded) {
        DiagLog(@"  [font] 使用 ImGui 默认字体");
    }
    DiagLog(@"  [font] _adaptToDevice 完成");
}

- (void)_tuneStyle {
    UIScreen *screen  = [UIScreen mainScreen];
    BOOL      isIpad  = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad);

    // 根据屏幕短边 (pt) 算缩放; iPad 短边 ≈768pt 作为 1.5x 基准
    CGFloat shortSidePt = MIN(self.bounds.size.width, self.bounds.size.height);
    if (shortSidePt < 1.0f) shortSidePt = MIN(screen.bounds.size.width, screen.bounds.size.height);

    float uiScale;
    if (isIpad || shortSidePt >= 700.0f) {
        uiScale = 1.5f;
    } else {
        // iPhone: 390pt≈ 0.98, 430pt≈ 1.08; 夹在 [0.85, 1.15]
        uiScale = (float)shortSidePt / 400.0f;
        if (uiScale < 0.85f) uiScale = 0.85f;
        if (uiScale > 1.15f) uiScale = 1.15f;
    }

    ImGuiStyle& style = ImGui::GetStyle();
    style.ScaleAllSizes(uiScale);

    // FontGlobalScale 补偿: 代码里硬编码的字号 (PLIST/SetNextWindowSize内的文字) 也一起缩放
    // 以 iPad 1.5x 为基准, iPhone 缩回比例 (同时近似修正字体峰高不匹配)
    ImGui::GetIO().FontGlobalScale = uiScale / 1.5f;

    style.WindowRounding    = 8.0f;
    style.FrameRounding     = 4.0f;
    style.ScrollbarRounding = 4.0f;
    style.GrabRounding      = 4.0f;
    style.Alpha             = 0.92f;
}

#pragma mark - MTKViewDelegate

- (void)drawInMTKView:(MTKView *)view {
    static int frameCount = 0;
    frameCount++;
    if (frameCount <= 3) {
        DiagLog(@"  [render] frame #%d, imguiReady=%d, view.bounds=%.0fx%.0f, hidden=%d, superview=%@",
               frameCount, _imguiReady,
               view.bounds.size.width, view.bounds.size.height,
               view.hidden, view.superview ? @"OK" : @"NIL");
    }
    if (!_imguiReady) return;

    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) {
        if (frameCount <= 5) DiagLog(@"  [render] frame #%d: rpd=nil!", frameCount);
        return;
    }

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    if (!cmdBuf) {
        if (frameCount <= 5) DiagLog(@"  [render] frame #%d: cmdBuf=nil!", frameCount);
        return;
    }

    CFTimeInterval now   = CACurrentMediaTime();
    CFTimeInterval delta = now - _lastFrameTime;
    if (delta <= 0.0) delta = 1.0 / 60.0;
    _lastFrameTime = now;

    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize  = ImVec2((float)view.bounds.size.width,
                              (float)view.bounds.size.height);
    io.DeltaTime    = (float)delta;

    rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor  = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();

    if (_drawBlock) {
        @try { _drawBlock(); }
        @catch (NSException *e) {
            NSLog(@"[ImGui] drawBlock 异常: %@", e);
        }
    }

    ImGui::Render();
    [self _updateWindowRects];

    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
    if (enc) {
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cmdBuf, enc);
        [enc endEncoding];
    }

    if (view.currentDrawable) {
        [cmdBuf presentDrawable:view.currentDrawable];
    }
    [cmdBuf commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    ImGuiIO& io = ImGui::GetIO();
    CGFloat scale = [UIScreen mainScreen].scale;
    io.DisplaySize             = ImVec2((float)(size.width  / scale),
                                        (float)(size.height / scale));
    io.DisplayFramebufferScale = ImVec2((float)scale, (float)scale);
}

#pragma mark - ImGui 窗口矩形追踪

- (void)_updateWindowRects {
    ImGuiContext *ctx = ImGui::GetCurrentContext();
    if (!ctx) return;
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    for (int i = 0; i < ctx->Windows.Size; i++) {
        ImGuiWindow *w = ctx->Windows[i];
        if (!w || w->Hidden) continue;
        if (w->Flags & ImGuiWindowFlags_ChildWindow) continue;
        if (w->Size.x <= 0 || w->Size.y <= 0) continue;
        CGRect r = CGRectMake(w->Pos.x, w->Pos.y, w->Size.x, w->Size.y);
        [rects addObject:[NSValue valueWithCGRect:r]];
    }
    _imguiWindowRects = [rects copy];
}

#pragma mark - 触摸事件 → ImGui IO

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_imguiReady) return;
    UITouch  *t   = touches.anyObject;
    CGPoint   loc = [t locationInView:self];
    ImGuiIO&  io  = ImGui::GetIO();
    io.AddMousePosEvent((float)loc.x, (float)loc.y);
    io.AddMouseButtonEvent(0, true);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_imguiReady) return;
    UITouch  *t   = touches.anyObject;
    CGPoint   loc = [t locationInView:self];
    ImGuiIO&  io  = ImGui::GetIO();
    io.AddMousePosEvent((float)loc.x, (float)loc.y);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_imguiReady) return;
    ImGui::GetIO().AddMouseButtonEvent(0, false);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_imguiReady) return;
    ImGui::GetIO().AddMouseButtonEvent(0, false);
}

#pragma mark - 销毁

- (void)shutdown {
    if (!_imguiReady) return;
    _imguiReady = NO;
    ImGui_ImplMetal_Shutdown();
    ImGui::DestroyContext();
}

- (void)dealloc {
    [self shutdown];
}

@end
