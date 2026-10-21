#pragma once
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import "imgui.h"

typedef void(^ImGuiDrawBlock)(void);

/**
 * ImGuiMetalView
 * 基于 MTKView 的 ImGui Metal 渲染视图，负责：
 *  - Metal 设备/指令队列管理
 *  - ImGui 上下文初始化与销毁
 *  - 每帧渲染调度
 *  - UITouch → ImGui IO 事件转发
 *  - 多设备像素密度适配
 */
@interface ImGuiMetalView : MTKView

@property (nonatomic, copy)     ImGuiDrawBlock      drawBlock;
@property (nonatomic, readonly) NSArray<NSValue *>  *imguiWindowRects;

/**
 * 初始化视图，自动选取系统默认 Metal 设备
 * @param frame  视图尺寸（通常传屏幕 bounds）
 */
- (instancetype)initWithFrame:(CGRect)frame;

/**
 * 销毁 ImGui 上下文与 Metal 后端，退出前必须调用
 */
- (void)shutdown;

@end
