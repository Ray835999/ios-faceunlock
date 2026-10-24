# FaceUnlock — 免费版「Vizage」平替（iPhone 6s / iOS 15 rootless）

用**前置摄像头 + Vision 人脸特征指纹**在越狱的 Touch ID 机型上实现人脸解锁。
Vizage（foxfortmobile，$3.99）是唯一在维护的同类商业插件；本仓库是免费自建实现，
针对 **iPhone 6s / iOS 15.8.x / Dopamine rootless palera1n**，arm64 rootless deb。

## 原理

1. 锁屏出现（`SBDashBoardViewController`）时启动前置摄像头，每帧跑
   `VNDetectFaceRectanglesRequest` + `VNDetectFaceCaptureQualityRequest`（约 3fps）。
2. **匹配器**：优先用私有类 `VNGenerateFaceFeaturePrintRequest`（Photos 同款人脸嵌入，
   运行时 `NSClassFromString` 探测）；不可用时自动回退到
   「裁剪人脸区域 → 归一化 256px → `VNGenerateImageFeaturePrintRequest`」的公开 API 路径。
3. **录入**：安装后前 5 次用密码/指纹真实解锁时自动采集你的人脸指纹
   （不需要配套 App，和 Appellancy 的体验一致）。
4. **解锁**：距离阈值内连续 2 帧匹配 → `setAuthenticated:YES` →
   `SBLockScreenManager lockScreenViewControllerRequestsUnlock`
   （与开源插件 FastUnlockX 相同的解锁完成调用）。

> 安全说明：2D 摄像头比对可以用照片/视频欺骗（Vizage 也一样，官方自己承认），
> 不支持 Apple Pay；请不要把它当唯一防护。

## 安装

1. 从 GitHub Actions artifact 下载 `com.ray835999.faceunlock_1.0.0-1+debug_iphoneos-arm64.deb`。
2. 传到手机（Filza/SSH），Sileo/Zebra 安装或 `dpkg -i`（rootless 环境自动装到 `/var/jb`）。
3. `ldrestart`（或 respring）。
4. **必须先设锁屏密码**（和 Vizage 一样的要求）。

## 使用与调校（ empirirical 验证流程 ）

```bash
# 1) 确认注入（应看到 ctor / loaded 两行）
log stream --predicate 'process == "SpringBoard"' | grep FaceUnlock

# 2) 录入：用密码解锁 5 次，日志出现
#    [FaceUnlock] enrolled faceprint 1/5 ... 5/5 -> enrollment complete

# 3) 测试：锁屏，正脸看前置摄像头，日志出现
#    [FaceUnlock] MATCH distance=0.xxx - requesting unlock
```

调校参数：`/var/jb/var/mobile/Library/Preferences/com.ray835999.faceunlock.plist`

| Key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `Enabled` | Bool | `true` | 总开关 |
| `Threshold` | Number | `0.5` | 匹配距离阈值。不识别就调大（0.6~0.8），误解锁就调小 |
| `Method` | String | `auto` | `auto` / `faceprint` / `imageprint` |
| `EnrollSamples` | Number | `5` | 录入张数；想录第二个人的脸就临时调大，让对方也用密码解锁几次 |

- 重新录入：删掉 `/var/jb/var/mobile/Library/FaceUnlock/templates.plist`，再密码解锁即可。
- 每次扫描会话结束会打印 `scan session best distance=...`，这是调 Threshold 的依据：
  本人最好距离与「别人/无人体」的距离差越大越稳。

## 已知限制

- 解锁的是锁屏 UI 层；SEP/密钥袋状态不变（与 Appellancy/Vizage 同类 2D 方案相同性质）。
- 暗光下前置摄像头画质差，识别率下降；`faceCaptureQuality < 0.1` 的帧会被丢弃。
- 扫描窗口 12 秒无匹配自动停（省电），下次亮屏重新开始。

## 构建

GitHub Actions（ubuntu + theos + iPhoneOS15.6.sdk + L1ghtmann toolchain）：
push 到 main 或手动 dispatch 即出 rootless deb。本地构建：

```bash
export THEOS=~/theos
make package THEOS_PACKAGE_SCHEME=rootless
```
