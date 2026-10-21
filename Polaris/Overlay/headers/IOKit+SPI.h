typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __GSEvent *GSEventRef;
typedef void *IOHIDEventSystemClientRef;

#if __cplusplus
extern "C" {
#endif

uint32_t IOHIDEventGetType(IOHIDEventRef event);
double   IOHIDEventGetFloatValue(IOHIDEventRef event, uint32_t field);
CFIndex  IOHIDEventGetIntegerValue(IOHIDEventRef event, uint32_t field);
CFArrayRef IOHIDEventGetChildren(IOHIDEventRef event);

// IOHIDEventSystemClient — 直接监控 IOKit 层 HID 事件
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef allocator,
                                                                int type,
                                                                CFDictionaryRef attributes);
void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client,
                                                CFRunLoopRef runLoop,
                                                CFStringRef mode);
void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef client,
                                                  void *callback,
                                                  void *target,
                                                  void *refcon);

#if __cplusplus
}
#endif

// HID 触摸数据（IOHIDEventSystemClient 回调写入，drawBlock 读取喂 ImGui IO）
typedef struct {
    float childNormX, childNormY; // 子事件归一化坐标 (0~1, 物理竖屏)
    bool  isTouching;             // 当前是否有手指在屏幕上
    bool  volumeUpPressed;        // 音量加按下 (单次脉冲)
    bool  volumeDownPressed;      // 音量减按下 (单次脉冲)
} HIDDebugInfo;

