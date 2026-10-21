//
//  PolarisHUDMenu.mm
//  悬浮球 + ImGui 展开菜单
//
//  交互（网易云风格）：
//   - 平时只显示一个可拖拽的悬浮球
//   - 单击悬浮球或按音量+ 展开 ImGui 菜单页面
//   - 音量- 收起菜单
//  菜单内容：内核状态 / 游戏进程(smoba) / RemoteCall 跨进程功能演示。
//  页面仅是骨架 —— 后续功能按需求再加。
//

#import "PolarisHUDMenu.h"
#import "PolarisHUDKRW.h"
#import "PolarisBridge.h"
#import "imgui_internal.h"

#include <math.h>

// ── 状态 ──
static bool g_menuVisible = false;
static float g_menuAlpha  = 0.0f;      // 展开动画
static float g_ballX = -1.0f, g_ballY = -1.0f;

// ── 菜单数据（draw 时刷新）──
static char s_kernelInfo[256] = "";
static char s_gameInfo[256]   = "";
static bool s_showDemo = false;

void PolarisMenuToggleVisible(void) { g_menuVisible = !g_menuVisible; }
void PolarisMenuSetVisible(bool visible) { g_menuVisible = visible; }
bool PolarisMenuIsVisible(void) { return g_menuVisible; }

// ── 悬浮球（网易云 ESPRenderer::renderFloatingBall 同款视觉）──
void PolarisMenuRenderBall(float screenW, float screenH)
{
    if (g_menuVisible) return;
    g_menuAlpha = 0.0f;

    float ballR = 25.0f;
    if (g_ballX < 0) { g_ballX = screenW - 50.0f; g_ballY = screenH * 0.4f; }

    ImVec2 center(g_ballX, g_ballY);

    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, ballR);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0, 0, 0, 0));
    ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(0, 0, 0, 0));

    float winSz = ballR * 2 + 4;
    ImGui::SetNextWindowPos(ImVec2(center.x - winSz * 0.5f, center.y - winSz * 0.5f), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(winSz, winSz));

    ImGui::Begin("##PolarisBall", nullptr,
        ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
        ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoMove |
        ImGuiWindowFlags_NoSavedSettings);

    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImVec2 wp = ImGui::GetWindowPos();
    ImVec2 ballCenter(wp.x + winSz * 0.5f, wp.y + winSz * 0.5f);

    dl->AddCircleFilled(ballCenter, ballR + 3, IM_COL32(40, 100, 255, 30), 32);   // 外发光
    dl->AddCircleFilled(ballCenter, ballR, IM_COL32(25, 60, 140, 220), 32);       // 主体
    dl->AddCircleFilled(ballCenter, ballR - 2, IM_COL32(35, 80, 180, 200), 32);
    dl->AddCircleFilled(ImVec2(ballCenter.x - 5, ballCenter.y - 6),
                        ballR * 0.4f, IM_COL32(100, 180, 255, 60), 24);           // 高光
    dl->AddCircle(ballCenter, ballR, IM_COL32(80, 160, 255, 150), 32, 1.5f);      // 边框
    const char *txt = "P";
    ImVec2 tsz = ImGui::CalcTextSize(txt);
    dl->AddText(ImVec2(ballCenter.x - tsz.x * 0.5f, ballCenter.y - tsz.y * 0.5f),
                IM_COL32(200, 220, 255, 240), txt);

    // 拖拽 + 单击判断
    ImGui::SetCursorPos(ImVec2(0, 0));
    ImGui::InvisibleButton("##ballhit", ImVec2(winSz, winSz));

    static float dragDist = 0;
    static bool  wasActive = false;
    static int   activeFrames = 0;

    bool isActive = ImGui::IsItemActive();
    if (isActive && !wasActive) { dragDist = 0; activeFrames = 0; }
    if (isActive) {
        activeFrames++;
        ImVec2 delta = ImGui::GetMouseDragDelta(0, 0.0f);
        dragDist = sqrtf(delta.x * delta.x + delta.y * delta.y);
        g_ballX = ImGui::GetIO().MousePos.x - winSz * 0.5f + ballR;
        g_ballY = ImGui::GetIO().MousePos.y - winSz * 0.5f + ballR;
        // 限制在屏幕内
        g_ballX = ImClamp(g_ballX, ballR, screenW - ballR);
        g_ballY = ImClamp(g_ballY, ballR, screenH - ballR);
    }
    if (wasActive && !isActive && activeFrames > 0) {
        // 松手：位移很小视为单击 → 展开菜单
        if (dragDist < 6.0f) PolarisMenuSetVisible(true);
    }
    wasActive = isActive;

    ImGui::End();
    ImGui::PopStyleColor(2);
    ImGui::PopStyleVar(2);
}

// ── 展开菜单 ──
void PolarisMenuRender(float screenW, float screenH)
{
    if (!g_menuVisible) return;

    // 展开渐显
    if (g_menuAlpha < 1.0f) g_menuAlpha = ImMin(g_menuAlpha + 0.08f, 1.0f);

    // 刷新内核 / 游戏状态文本（每 ~30 帧一次即可）
    static int refreshTick = 0;
    if ((refreshTick++ % 30) == 0) {
        if (PolarisHUDKernelIsReady()) {
            snprintf(s_kernelInfo, sizeof(s_kernelInfo),
                     "KRW 已采用 · base 0x%llx · slide 0x%llx",
                     (unsigned long long)PolarisKernelBase(),
                     (unsigned long long)PolarisKernelSlide());
        } else {
            snprintf(s_kernelInfo, sizeof(s_kernelInfo), "KRW 未就绪（父进程未传递或采用失败）");
        }
        if (PolarisGameProcessIsReady()) {
            snprintf(s_gameInfo, sizeof(s_gameInfo), "smoba · pid %d · proc 0x%llx",
                     PolarisGameProcessPID(),
                     (unsigned long long)PolarisGameProcessProcAddress());
        } else {
            snprintf(s_gameInfo, sizeof(s_gameInfo), "未获取（在主 App 点「获取游戏进程」）");
        }
    }

    ImGui::PushStyleVar(ImGuiStyleVar_Alpha, g_menuAlpha);

    ImVec2 winSize(400, 460);
    if (winSize.x > screenW - 20) winSize.x = screenW - 20;
    if (winSize.y > screenH - 20) winSize.y = screenH - 20;
    ImGui::SetNextWindowPos(ImVec2((screenW - winSize.x) * 0.5f,
                                   (screenH - winSize.y) * 0.5f),
                            ImGuiCond_Appearing);
    ImGui::SetNextWindowSize(winSize, ImGuiCond_Appearing);

    ImGui::Begin("Polaris", nullptr,
                 ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings);

    ImGui::Text("Polaris · DarkSword");
    ImGui::Separator();

    if (ImGui::CollapsingHeader("内核状态", ImGuiTreeNodeFlags_DefaultOpen)) {
        ImGui::TextWrapped("%s", s_kernelInfo);
        ImGui::TextWrapped("游戏进程: %s", s_gameInfo);
    }

    if (ImGui::CollapsingHeader("跨进程 (RemoteCall)", ImGuiTreeNodeFlags_DefaultOpen)) {
        ImGui::TextWrapped("RemoteCall 已就绪，可对任意进程执行远程调用。");
        ImGui::BulletText("RemoteCall / 内核读写与 DarkSpeed 同源");
        ImGui::BulletText("目标进程: SpringBoard / 游戏 (smoba)");
    }

    if (ImGui::CollapsingHeader("关于")) {
        ImGui::TextWrapped("悬浮窗: 音量+ 展开 / 音量- 收起，拖动悬浮球移动位置。");
        if (ImGui::Checkbox("ImGui Demo", &s_showDemo)) {}
    }

    ImGui::Separator();
    if (ImGui::Button("收起菜单", ImVec2(-1, 0))) {
        PolarisMenuSetVisible(false);
    }

    ImGui::End();
    ImGui::PopStyleVar();

    if (s_showDemo) ImGui::ShowDemoWindow();
}
