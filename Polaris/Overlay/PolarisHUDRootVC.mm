//
//  PolarisHUDRootVC.mm
//  悬浮窗根视图：ImGuiMetalView + 方向跟踪 + 悬浮球/菜单绘制
//
//  结构与网易云 HUDRootVC 一致：
//   - 容器视图做旋转（避免 UIWindow 布局覆盖 transform）
//   - FBSOrientationObserver 优先 + NSTimer 轮询兜底
//   - drawBlock 里喂触摸 → 画悬浮球 → 画展开菜单（ImGui）
//   - 音量键控制菜单显隐
//

#import "PolarisHUDRootVC.h"
#import "ImGuiMetalView.h"
#import "PolarisHUDLog.h"
#import "PolarisHUDMenu.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

#import "IOKit+SPI.h"

// PolarisHUDMain.mm 中定义
extern HIDDebugInfo g_polarisHid;

// 当前方向（_applyOrientation 写入，drawBlock 读取）
static int g_currentOrientation = 1; // UIInterfaceOrientationPortrait

@implementation PolarisHUDRootVC {
    UIView         *_containerView;        // 旋转容器
    ImGuiMetalView *_metalView;
    NSTimer        *_orientationTimer;
    id              _fbsObserver;
    UIInterfaceOrientation _fbsOrientation;
    BOOL            _fbsActive;
    CGFloat         _lastAppliedAngle;
    CGSize          _lastDisplaySize;
    MPVolumeView   *_hiddenVolumeView;
}

- (ImGuiMetalView *)metalView {
    return _metalView;
}

- (void)dealloc {
    [_orientationTimer invalidate];
    [_hiddenVolumeView removeFromSuperview];
    if (_fbsObserver) {
        SEL sel = NSSelectorFromString(@"invalidate");
        if ([_fbsObserver respondsToSelector:sel]) {
            ((void(*)(id, SEL))objc_msgSend)(_fbsObserver, sel);
        }
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    // 隐藏系统音量 HUD（网易云同款，防止按音量键弹系统提示）
    _hiddenVolumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-100, -100, 1, 1)];
    _hiddenVolumeView.alpha = 0.01f;
    [self.view addSubview:_hiddenVolumeView];

    // 旋转容器：不受 UIWindow 布局系统干扰
    _containerView = [[UIView alloc] initWithFrame:self.view.bounds];
    _containerView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_containerView];

    _metalView = [[ImGuiMetalView alloc] initWithFrame:_containerView.bounds];
    [_containerView addSubview:_metalView];

    _metalView.drawBlock = ^{
        ImGuiIO &io = ImGui::GetIO();

        // ── 触摸事件（IOHID 归一化坐标 → ImGui 显示坐标）──
        {
            static bool wasTouching = false;
            bool isTouching = g_polarisHid.isTouching;
            float nX = g_polarisHid.childNormX;
            float nY = g_polarisHid.childNormY;
            float dW = io.DisplaySize.x;
            float dH = io.DisplaySize.y;
            float imX = 0, imY = 0;

            int ori = g_currentOrientation;
            switch (ori) {
                case 3: imX = nY * dW;          imY = (1.0f - nX) * dH; break; // LandscapeRight
                case 4: imX = (1.0f - nY) * dW; imY = nX * dH;          break; // LandscapeLeft
                case 2: imX = (1.0f - nX) * dW; imY = (1.0f - nY) * dH; break; // PortraitUpsideDown
                default: imX = nX * dW;         imY = nY * dH;          break; // Portrait
            }

            if (isTouching) {
                io.AddMousePosEvent(imX, imY);
                if (!wasTouching) io.AddMouseButtonEvent(0, true);
            } else if (wasTouching) {
                io.AddMouseButtonEvent(0, false);
            }
            wasTouching = isTouching;
        }

        // ── 音量键控制菜单显隐（网易云悬浮球交互）──
        if (g_polarisHid.volumeUpPressed) {
            g_polarisHid.volumeUpPressed = false;
            PolarisMenuToggleVisible();
        }
        if (g_polarisHid.volumeDownPressed) {
            g_polarisHid.volumeDownPressed = false;
            PolarisMenuSetVisible(false);
        }

        float screenW = io.DisplaySize.x;
        float screenH = io.DisplaySize.y;

        // ── 悬浮球（菜单隐藏时显示）──
        PolarisMenuRenderBall(screenW, screenH);

        // ── 展开的 ImGui 菜单页面 ──
        PolarisMenuRender(screenW, screenH);
    };

    _lastAppliedAngle  = -999;
    _lastDisplaySize   = CGSizeZero;
    _fbsOrientation    = UIInterfaceOrientationPortrait;
    _fbsActive         = NO;

    [self _setupFBSOrientationObserver];

    __weak __typeof__(self) weakSelf = self;
    _orientationTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                       repeats:YES
                                                         block:^(NSTimer *timer) {
        [weakSelf _pollAndApply];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_orientationTimer forMode:NSRunLoopCommonModes];
}

#pragma mark - 方向跟踪

- (void)_setupFBSOrientationObserver {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);

    Class FBSOriObsCls = NSClassFromString(@"FBSOrientationObserver");
    if (!FBSOriObsCls) {
        PolarisHUDLog(@"FBSOrientationObserver 不可用，使用轮询兜底");
        return;
    }

    _fbsObserver = [[FBSOriObsCls alloc] init];

    __weak __typeof__(self) weakSelf = self;
    SEL setHandlerSel = NSSelectorFromString(@"setHandler:");
    if ([_fbsObserver respondsToSelector:setHandlerSel]) {
        id handler = ^(id orientationUpdate) {
            __strong __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            long long ori = 0;
            SEL oriSel = NSSelectorFromString(@"orientation");
            if ([orientationUpdate respondsToSelector:oriSel]) {
                ori = ((long long(*)(id, SEL))objc_msgSend)(orientationUpdate, oriSel);
            }
            if (ori < UIInterfaceOrientationPortrait || ori > UIInterfaceOrientationLandscapeLeft) return;

            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf->_fbsOrientation = (UIInterfaceOrientation)ori;
                strongSelf->_fbsActive = YES;
                [strongSelf _applyOrientation:(UIInterfaceOrientation)ori];
            });
        };
        ((void(*)(id, SEL, id))objc_msgSend)(_fbsObserver, setHandlerSel, handler);
    }

    SEL activeOriSel = NSSelectorFromString(@"activeInterfaceOrientationWithCompletion:");
    if ([_fbsObserver respondsToSelector:activeOriSel]) {
        id completion = ^(long long ori) {
            __strong __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (ori < UIInterfaceOrientationPortrait || ori > UIInterfaceOrientationLandscapeLeft) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf->_fbsOrientation = (UIInterfaceOrientation)ori;
                strongSelf->_fbsActive = YES;
                [strongSelf _applyOrientation:(UIInterfaceOrientation)ori];
            });
        };
        ((void(*)(id, SEL, id))objc_msgSend)(_fbsObserver, activeOriSel, completion);
    }
}

- (void)_pollAndApply {
    [self _applyOrientation:[self _detectOrientation]];
}

- (UIInterfaceOrientation)_detectOrientation {
    if (_fbsActive) return _fbsOrientation;

    // _UIStatusBarOrientation 私有 C 函数
    typedef long long (*StatusBarOriFunc)(void);
    static StatusBarOriFunc _statusBarFunc = NULL;
    static BOOL _resolved = NO;
    if (!_resolved) {
        _resolved = YES;
        _statusBarFunc = (StatusBarOriFunc)dlsym(RTLD_DEFAULT, "_UIStatusBarOrientation");
    }
    if (_statusBarFunc) {
        long long ori = _statusBarFunc();
        if (ori >= UIInterfaceOrientationPortrait && ori <= UIInterfaceOrientationLandscapeRight) {
            return (UIInterfaceOrientation)ori;
        }
    }

    CGRect bounds = [UIScreen mainScreen].bounds;
    if (bounds.size.width > bounds.size.height) {
        return UIInterfaceOrientationLandscapeRight;
    }
    return UIInterfaceOrientationPortrait;
}

- (void)_applyOrientation:(UIInterfaceOrientation)orientation {
    g_currentOrientation = (int)orientation;

    CGFloat angle = 0.0;
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:  angle = M_PI_2;  break;
        case UIInterfaceOrientationLandscapeRight: angle = -M_PI_2; break;
        case UIInterfaceOrientationPortraitUpsideDown: angle = M_PI; break;
        default: angle = 0.0; break;
    }

    // 容器旋转：宽高互换交给 transform，不依赖 UIWindow 布局
    CGSize size = _containerView.bounds.size;
    CGSize display = CGSizeZero;
    if (orientation == UIInterfaceOrientationLandscapeLeft ||
        orientation == UIInterfaceOrientationLandscapeRight) {
        display = CGSizeMake(MAX(size.width, size.height), MIN(size.width, size.height));
    } else {
        display = CGSizeMake(MIN(size.width, size.height), MAX(size.width, size.height));
    }

    if (_lastAppliedAngle == angle &&
        CGSizeEqualToSize(_lastDisplaySize, display)) {
        return;
    }
    _lastAppliedAngle = angle;
    _lastDisplaySize  = display;

    _containerView.transform = CGAffineTransformMakeRotation(angle);
    _containerView.frame = CGRectMake(0, 0, display.width, display.height);
    _metalView.frame = _containerView.bounds;

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)display.width, (float)display.height);
}

@end
