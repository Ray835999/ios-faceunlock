# FaceUnlock 2.0.0 — 摄像头人脸解锁（iPhone 6s / iOS 15 rootless）

用**前置摄像头 + Vision 人脸特征指纹**在越狱的 Touch ID 机型上实现人脸解锁，
是 Vizage（foxfortmobile，$3.99）的免费自建平替。
目标环境：**iPhone 6s / iOS 15.8.x / Dopamine rootless**，arm64 rootless deb。

一个包两件东西：

| 组件 | 作用 |
|---|---|
| **FaceUnlockSettings.app** | 设置 App：录入人脸、开关、急停、屏内诊断 |
| **FaceUnlock.dylib**（SpringBoard 插件） | 锁屏匹配 + 解锁，无 UI |

录入和匹配跑的是**同一份 `FacePrint.m`**，两边特征指纹可直接比对。

---

## 2.0.0 是一次重写，不是修补

v1.x 反复出现「一会儿崩溃、一会儿点不了」。根因不是某一行代码写错，而是**架构把太多
东西塞进了 SpringBoard 进程**：`%ctor` 里注册通知、hook 锁屏控制器生命周期、`dlopen`
框架、在 springboard 里起摄像头会话。任何一处抛异常或阻塞，用户看到的就是 Safe Mode
或「整台手机点不动」（SpringBoard 卡死 = 所有按钮都失效）。

2.0.0 换了个前提：**假设这个进程随时会被自己搞死**。

| 机制 | 解决的症状 |
|---|---|
| **崩溃循环熔断**：`%ctor` 记开机计数，120 秒内被加载 4 次 → 自动写 `DISABLED` 并**不安装任何 hook** | 崩一次就自愈，不会被拖进 Safe Mode 死循环 |
| **零框架符号**：AVFoundation/CoreVideo 常量全部换字面量（`"vide"`、`"PixelFormatType"`、`0x42475241`），dylib 里**没有任何框架加载命令** | 加载期不可能因框架缺失而崩 |
| **什么都不在加载期做**：`%ctor` 不碰 SpringBoard、不注册通知、不 dlopen；3 秒后才 setup，框架首次真正需要时才加载 | 消除 dyld 期崩溃 |
| **无帧看门狗**：起会话后 3 秒没收到帧 → 在自己队列上拆掉会话并计数，累计 3 次自动禁用 | 不会把摄像头攥在手里卡死手机 |
| **解锁多路链**：`setAuthenticated:` → `unlockUIFromSource:withOptions:` → `lockScreenViewControllerRequestsUnlock`，逐条尝试并记录哪条生效 | 不用猜 iOS 15 的私有 API，哪条通用哪条 |
| **遥测代替抓日志**：所有状态写进 `status.plist`，App 首页直接显示 | 不用连电脑、不用敲命令行 |
| **急停开关**：App 里一个红色按钮，或手工 `touch .../DISABLED` | 任何异常都能一秒自救 |

App 侧同样重写：**丢掉 `UITableViewController` + `UINavigationController`**，改成单个
`UIViewController` + 手摆 frame 的 `UIButton`，并且**屏上带触摸计数器 + hitTest 命中视图**，
让「触摸没进进程」和「控件被盖住」当场可区分。

---

## 使用方法

1. 从 GitHub Actions artifact 下载 `com.ray835999.faceunlock_2.0.0-1+debug_iphoneos-arm64.deb`。
2. 传到手机（Filza / SSH），Sileo / Zebra 安装或 `dpkg -i`（rootless 自动装到 `/var/jb`）。
   安装脚本会自动 `uicache`，桌面出现 **FaceUnlock** 图标。
3. **先设好锁屏密码**（和 Vizage 一样的前提）。
4. **重装后必须注销/重启一次**，否则插件不会重新注入 SpringBoard。
5. 打开 **FaceUnlock** → 点 **① 开始录入人脸** → 把脸放进圆圈，自动采集 5 个样本。
6. 锁屏，把脸对准前置摄像头。

> App 首页顶部那张状态卡就是诊断面板：`当前状态` / `SB相机权限` / `会话/帧/脸` /
> `最近距离` / `解锁路径` / `解锁结果`。没反应时先看它，再点「复制诊断信息」发出来。

---

## 排障对照表

| 状态卡显示 | 含义 / 处理 |
|---|---|
| `插件遥测：无（尚未在 SpringBoard 中运行）` | 插件没注入。注销或重启一次 |
| `当前状态：disabled (kill switch)` | 被急停/自动禁用了。打开开关或点「重新启用」 |
| `当前状态：disabled: crash loop detected` | 上次真的崩过，已自动熔断保护。看「最近错误」判断原因 |
| `SB相机权限：被拒绝` | SpringBoard 没有相机权限 —— 这是插件起摄像头失败最常见原因 |
| `当前状态：no frames (camera not delivering)` | 会话起了但拿不到帧，8 成是权限；3 次后会自动禁用 |
| `当前状态：no templates` | 还没录入，或录入没保存成功 |
| `会话/帧/脸：2 / 0 / 0` | 会话起了，帧没到 → 权限问题 |
| `会话/帧/脸：2 / 300 / 0` | 有画面但没检测到脸 → 光线/距离/前置摄像头被挡 |
| `最近距离：0.62`（阈值 0.55） | 认出来了但不够像。多录几个角度，或调阈值 |
| `解锁路径：no route available` | 私有 API 全不响应（系统版本差异），把这行发出来 |
| `解锁结果：仍锁屏(失败)` | 认证设置了但没完成解锁，需要换一条路由 |

按钮点了没反应时，看首页底部 **「触摸事件」**：

* 数字**不动** → 触摸根本没进 App 进程（窗口/事件层问题）
* 数字**会动**，但点按钮没反应 → 看「命中视图」，说明按钮被别的东西盖住了

---

## 急停 / 恢复

```bash
# 立即禁用（不改任何代码，重启也保持禁用）
touch /var/jb/var/mobile/Library/FaceUnlock/DISABLED

# 恢复
rm /var/jb/var/mobile/Library/FaceUnlock/DISABLED
rm /var/jb/var/mobile/Library/FaceUnlock/boot.plist
```

App 里的红色按钮「② 急停」做的是一样的事，不需要终端。

## 数据文件

全部在 `/var/jb/var/mobile/Library/FaceUnlock/`：

| 文件 | 内容 |
|---|---|
| `templates.plist` | 录入的人脸特征指纹 |
| `status.plist` | 插件遥测（App 首页显示的就是它） |
| `tweak.log` | 插件日志（上限 96 KB 自动截断） |
| `app.log` | App 日志 |
| `DISABLED` | 急停开关 |
| `boot.plist` | 崩溃循环熔断计数 |

---

## 技术要点

* **Vision**：`VNDetectFaceRectanglesRequest` + `VNDetectFaceCaptureQualityRequest` 质量门，
  特征指纹优先私有 `VNGenerateFaceFeaturePrintRequest`，回退到「裁剪人脸 → 归一化 256px →
  `VNGenerateImageFeaturePrintRequest`」。距离用 `computeDistance:toFeaturePrintObservation:`
  优先，回退原始向量欧氏距离。
* **解锁**：先设 `setAuthenticated:YES`，再走 `SBLockScreenManager` 的三条解锁路由，
  1.2 秒后回查 `isLockScreenVisible` 自检是否真的解开。
* **触发**：Darwin 通知 `com.apple.springboard.lockcomplete`（主）+ `CSCoverSheetViewController`
  / `SBDashBoardViewController` 的 `viewDidAppear:`（备），两者都不存在也不影响加载。
* **构建**：theos + iPhoneOS 15.6 SDK + L1ghtmann 工具链，GitHub Actions 出 deb；
  `layout/DEBIAN/postinst` 必须是 0755（theos 会拒绝 644）。
