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

1. 从 GitHub Actions artifact 下载 `com.ray835999.faceunlock_1.2.1-1+debug_iphoneos-arm64.deb`。
2. 传到手机（Filza/SSH），Sileo/Zebra 安装或 `dpkg -i`（rootless 环境自动装到 `/var/jb`）。
   安装脚本会自动跑 `uicache`，桌面出现 **FaceUnlock** 图标
   （若图标没出现，手动执行 `uicache` 或 `ldrestart`）。
3. **必须先设锁屏密码**（和 Vizage 一样的要求）。

## 使用（empirical 验证流程）

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

## 如果进 Safe Mode / SpringBoard 崩溃（v1.2.0 排查 SOP）

按日志三阶段定位（**按顺序看，能直接指出崩在哪一层**）：

```bash
log stream --predicate 'process == "SpringBoard"' | grep FaceUnlock
```

| 日志停在哪 | 含义 | 处理 |
|---|---|---|
| **完全没有 `ctor:`** | dyld 加载期就死了（框架链接/链接器层面） | v1.2.1 起 Vision/AVFoundation/CoreMedia/CoreVideo 已改为**弱链接且不带任何加载命令**，加载期不可能再因框架而死；若仍出现，请把手机「设置 → 隐私 → 分析与改进 → 分析数据 → `SpringBoard-*.ips`」里最新一条崩溃报告发来 |
| 有 `ctor:` 没有 `loaded:` | 首次锁屏 `setUp` 阶段崩 | 看 `dlopen CoreMedia/AVFoundation/Vision` 三行是否打印完——崩在哪个后面就是哪个框架的初始化问题 |
| 有 `loaded:` 没有 `scanning started` | 摄像头会话启动阶段崩 | 日志里会先打印 `camera authorization status:`，把它一起发来 |
| 有 `scanning started` 后崩 | 帧处理/解锁链路崩 | 看最后一条日志 |

1. **不进 Safe Mode 的软关闭**：写 `{"Enabled": false}` 到 prefs plist 后 `ldrestart`；
   或建急停文件 `/var/jb/var/mobile/Library/FaceUnlock/DISABLED`（存在即完全停用，
   连 hook 内部逻辑都不跑）。
2. **卸载**：Safe Mode 里能开 Sileo/Zebra，直接移除 FaceUnlock；或 SSH 进手机
   `dpkg -r com.ray835999.faceunlock && ldrestart`。
3. **隔离 App 侧**（判断是不是 App 引起的）：
   `rm -rf /var/jb/Applications/FaceUnlockSettings.app && uicache && ldrestart`
   —— 不崩就说明是 App 侧问题；崩则是插件侧。

v1.2.0 崩溃加固（v1.0.x 两次 Safe Mode 的根因都已覆盖）：

- **`%ctor` 只打一行日志**，不注册通知、不碰任何 API（v1.0.0 的根因是
  `%ctor` 里调 `SBLockScreenManager sharedInstance`；v1.2.x 起
  `notify_register_dispatch` 也挪到了 `setUp`）。
- **Vision / AVFoundation / CoreMedia / CoreVideo 弱链接且不带加载命令**：
  编译产物里这些框架**没有任何 LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB**——
  dyld 在把插件注入 SpringBoard 时不会去加载它们，加载期零风险；
  运行时在 `setUp` 里 `dlopen`，失败只打日志并禁用功能。
- 所有类引用走 `NSClassFromString`、所有 extern 常量做 NULL 检查
  （`AVMediaTypeVideo`、`AVCaptureSessionPreset640x480`、
  `kCVPixelBufferPixelFormatTypeKey` 等弱引用符号）。
- 所有 hook body 与采集管线包 `@try/@catch`。
- 回退匹配器不用 UIKit 后台绘图，纯 CoreImage。
- `AVCaptureSession` 生命周期归采集队列，主线程只翻 BOOL 闸门 + 会话代际。
- 模板数组跨线程访问全部加锁；不写 `NSNull` 进 plist。
- 解锁调用前带 FastUnlockX 同款 `hasContent` 保护。
- 安装后 `postinst` 自动 `uicache`；`layout/DEBIAN/postinst` 以 755 模式提交
  （Contents API 不记录 mode，是用 Git Data API 补的 tree entry mode）。

## 已知限制

- 解锁的是锁屏 UI 层；SEP/钥匙串状态不变（与 Appellancy/Vizage 同类 2D 方案相同性质）。
- 暗光下前置摄像头画质差，识别率下降；质量分低的帧会被丢弃。
- 扫描窗口 12 秒无匹配自动停（省电），下次亮屏重新开始。
- 插件在 SpringBoard 进程里跑摄像头，若日志显示
  `camera authorization status: 0`（notDetermined）且始终拿不到帧，
  说明该进程没有相机 TCC 授权——那是体系限制，需要改成「App 侧匹配 +
  通知驱动解锁」架构（v1.3.0 候选方案）。

## 构建

GitHub Actions（ubuntu + theos + iPhoneOS15.6.sdk + L1ghtmann toolchain）：
push 到 main 或手动 dispatch 即出 rootless deb（含 tweak + App）。本地构建：

```bash
export THEOS=~/theos
make package THEOS_PACKAGE_SCHEME=rootless
```

工程结构：

```
Tweak.xm                      # SpringBoard 插件：匹配 + 解锁（框架弱链接 + 运行时 dlopen）
FacePrint.h/.m                # 共享管线：检测 / 特征指纹 / 模板读写 / 距离
settings/main.m               # App 入口
settings/FaceUnlockSettings.m # App UI：菜单 + 录入界面
settings/FaceUnlockSettings.h # App 类声明
settings/Info.plist           # 相机权限 / 图标（after-stage 覆盖 theos 自动生成的）
settings/AppIcon60x60@2x.png  # 120x120 图标
layout/DEBIAN/postinst        # 安装后 uicache，让桌面出现 App 图标
Makefile                      # tweak（WEAK_FRAMEWORKS）+ application 两个 target
control                       # deb 元数据
```
