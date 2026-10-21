//
//  PolarisHUDMenu.h
//  悬浮球 + ImGui 展开菜单（网易云风格）
//

#import <Foundation/Foundation.h>
#import "imgui.h"

NS_ASSUME_NONNULL_BEGIN

/// 切换菜单显隐（音量+ / 点悬浮球调用）。
void PolarisMenuToggleVisible(void);

/// 强制设置菜单显隐。
void PolarisMenuSetVisible(bool visible);

/// 菜单当前是否可见。
bool PolarisMenuIsVisible(void);

/// 绘制悬浮球（菜单隐藏时调用）。可拖拽，单击展开菜单。
void PolarisMenuRenderBall(float screenW, float screenH);

/// 绘制展开的 ImGui 菜单页面。
void PolarisMenuRender(float screenW, float screenH);

NS_ASSUME_NONNULL_END
