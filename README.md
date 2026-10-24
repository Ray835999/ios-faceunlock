# FaceUnlock — 免费版「Vizage」平替（iPhone 6s / iOS 15 rootless）

用**前置摄像头 + Vision 人脸特征指纹**在越狱的 Touch ID 机型上实现人脸解锁。
Vizage（foxfortmobile，$3.99）是唯一在维护的同类商业插件；本仓库是免费自建实现，
针对 **iPhone 6s / iOS 15.8.x / Dopamine rootless palera1n**，arm64 rootless deb。

一个包两件东西：

| 组件 | 作用 |
|---|---|
| **FaceUnlockSettings.app** | 设置 App：录入人脸、开关、阈值、清除 |
| **FaceUnlock.dylib**（SpringBoard 插件） | 锁屏匹配 + 解锁，无 UI |

录入和匹配跑的是**同一份 `FacePrint.m` 代码**，两边特征指纹可直接比对。

## 原理

1. 在 **FaceUnlockSettings App** 里录入：App 自己跑前置摄像头 + Vision
   （`VNDetectFaceRectanglesRequest` + 质量门 + `VNGenerateFaceFeaturePrintRequest`），
   采 5 个样本写入 `/var/jb/var/mobile/Library/FaceUnlock/templates.plist`，
   然后发 Darwin 通知 `com.ray835999.faceunlock.templates-changed`。
2. 插件收到通知立即热重载模板；锁屏出现时启动摄像头匹配（约 3fps，12 秒窗口）。
3. **匹配**：阈值内连续 2 帧匹配 → `setAuthenticated:YES` →
   `SBLockScreenManager lockScreenViewControllerRequestsUnlock`
   （与开源插件 FastUnlockX 相同的解锁完成调用；锁屏有通知横幅时会先跳过，
   与 FastUnlockX 的 `hasContent` 保护一致）。
4. **匹配器**：优先私有类 `VNGenerateFaceFeaturePrintRequest`（Photos 同款人脸嵌入，
   运行时探测）；不可用时自动回退「裁剪人脸 → 归一化 256px → `VNGenerateImageFeaturePrintRequest`」。

> 安全说明：2D 摄像头比对可以用照片/视频欺骗（Vizage 也一样，官方自己承认），
> 不支持 Apple Pay；请不要把它当唯一防护。

## 安装

1. 从 GitHub Actions artifact 下载 `com.ray835999.faceunlock_1.1.0-1+debug_iphoneos-arm64.deb`。
2. 传到手机（Filza/SSH），Sileo/Zebra 安装或 `dpkg -i`（rootless 环境自动装到 `/var/jb`）。
3. `ldrestart`（或 respring）——桌面出现 **FaceUnlock** 图标。
4. **必须先设锁屏密码**（和 Vizage 一样的要求）。

## 使用（ empirical 验证流程 ）

1. 打开桌面的 **FaceUnlock** App →「开始录入人脸」→ 允许相机权限 →
   正脸对摄像头、缓慢转头，采满 5 个样本（进度 5/5 自动保存）。
   日志：`log stream --predicate 'process == "SpringBoard"' | grep FaceUnlock`
   （App 的日志在同一条流里，前缀都是 `[FaceUnlock]`）
2. 锁屏，正脸看前置摄像头，日志出现
   `[FaceUnlock] MATCH distance=0.xxx - requesting unlock` 即解锁。
3. 录入完成后插件日志会打印 `templates reloaded: 5`，确认通信链路通了。

调校参数（App 里也能改，写的是同一份 plist：
`/var/jb/var/mobile/Library/Preferences/com.ray835999.faceunlock.plist`）：

| Key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `Enabled` | Bool | `true` | 总开关 |
| `Threshold` | Number | `0.5` | 匹配距离阈值。不识别就调大（0.6~0.8），误解锁就调小 |

- 想录第二个人的脸：App 里先「清除」，再让对方录 5 次即可。
- 每次扫描会话结束会打印 `scan session best distance=...`，这是调 Threshold 的依据。

## 如果进 Safe Mode / SpringBoard 崩溃

1. **卸载**：Safe Mode 里能开 Sileo/Zebra，直接移除 FaceUnlock；或 SSH 进手机
   `dpkg -r com.ray835999.faceunlock && ldrestart`。
2. **看注入点**：`log stream --predicate 'process == "SpringBoard"' | grep FaceUnlock`
   - 连 `ctor: injecting into com.apple.springboard` 都没有 → 加载期就崩了
     （substrate / dyld 层面，与业务代码无关）
   - 有 `ctor:` 但没有 `loaded:` → setUp 阶段崩
   - 有 `loaded:` 没有 `scanning started` → 摄像头会话阶段崩
   - 有 `scanning started` 之后崩 → 看最后一条日志停在哪个阶段
3. **软关闭**：在 App 里关「启用 FaceUnlock」开关，或写
   `{"Enabled": false}` 到 prefs plist，然后 `ldrestart`。

崩溃加固要点（v1.0.0 曾进 Safe Mode，已修）：

- `%ctor` 不碰任何 SpringBoard 单例（tweak 在 dyld 加载期注入，那时 SpringBoard
  还没初始化）；`setUp` 推迟到首次锁屏出现。
- 所有 hook body 与采集管线包 `@try/@catch`。
- 回退匹配器不用 UIKit 后台绘图，纯 CoreImage。
- `AVCaptureSession` 生命周期归采集队列，主线程只翻 BOOL 闸门 + 会话代际。
- 模板数组跨线程访问全部加锁；不写 `NSNull` 进 plist。

## 已知限制

- 解锁的是锁屏 UI 层；SEP/密钥袋状态不变（与 Appellancy/Vizage 同类 2D 方案相同性质）。
- 暗光下前置摄像头画质差，识别率下降；质量分低的帧会被丢弃。
- 扫描窗口 12 秒无匹配自动停（省电），下次亮屏重新开始。

## 构建

GitHub Actions（ubuntu + theos + iPhoneOS15.6.sdk + L1ghtmann toolchain）：
push 到 main 或手动 dispatch 即出 rootless deb（含 tweak + App）。本地构建：

```bash
export THEOS=~/theos
make package THEOS_PACKAGE_SCHEME=rootless
```

工程结构：

```
Tweak.xm                      # SpringBoard 插件：匹配 + 解锁
FacePrint.h/.m                # 共享管线：检测 / 特征指纹 / 模板读写 / 距离
settings/main.m               # App 入口
settings/FaceUnlockSettings.m # App UI：菜单 + 录入界面
settings/Info.plist           # 相机权限 / SceneManifest / 图标（after-stage 覆盖）
settings/AppIcon60x60@2x.png  # 120x120 图标
```
