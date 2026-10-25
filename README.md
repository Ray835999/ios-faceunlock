# FaceUnlock 2.2.0 — 摄像头人脸解锁（iPhone 6s / iOS 15 rootless）

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

## 2.2.0 修的是什么（"预览活的、帧 0、连拍照也没有"）

截图给出的信息已经足够定位：**预览层在渲染，说明会话在跑、摄像头在出图**；
但 `帧 0` 且拍照通路 0 张，说明**两条数据连接都没建立成功**。这不是权限、不是 Vision、
也不是"摄像头被别的 App 占着"。

v2.1.0 的猜测方向（队列共享、格式协商）只对了一半。真正的坑是**应用时机**：
`videoSettings` 是在 `commitConfiguration` **之后**才设到 output 上的。对一个已经进入
会话的连接改像素格式，不是每个 AVFoundation 构建都会照做 —— 连接就这么静默地哑掉，
而预览层用的是它自己的连接，照旧渲染。

按三条规则重做采集层：

| 规则 | 做法 |
|---|---|
| **① 先设格式再挂 output** | `videoSettings` 在 `addOutput:` **之前**写入，全程包在 `beginConfiguration` / `commitConfiguration` 里 |
| **② 原生格式优先** | 依次试 `420f → 420v → BGRA`，并换一次 preset（640×480 → High）。BGRA 常常出现在 `availableVideoCVPixelFormatTypes` 里却根本不出数据 |
| **③ 每档都是全新会话** | 每档建一个全新 session（旧的在会话队列上按序 stop），**2 秒没出帧就自动换下一档**，不需要用户点任何东西 |

四档视频全哑 → 换成**只挂 `AVCapturePhotoOutput` 的独立会话**（预览 + 按需拍照，1 张/秒）；
仍然拿不到 → 直接调 **系统相机 UI（`UIImagePickerController`）**，让用户按 5 次快门。
系统相机是苹果自己的管道，不存在"连接哑掉"这回事，所以这条路必然能完成录入。

四条路径（视频流 / 照片 / 系统相机 / 以后锁屏匹配）全部走同一个 `processPixelBuffer:`，
特征指纹仍然可比。

底部计量改成三行，一张截图就能判断卡在哪：

```
帧 128 检测 12 命中 11  第1档
源 视频 420f  640x480 丢0
run1 act1 en1 · rect: 1 face(s) (orient right)
```

第三行的 `run/act/en` 是会话启动后的真实连接状态，`act0` 就是"连接没激活"。

插件侧同步改造：像素格式同样在 `addOutput` 之前写入、同样是 `420f → 420v → BGRA` 阶梯，
3 秒无帧先换下一档重建会话，**四档都失败才计入崩溃计数**（避免把"格式不对"误判成
"摄像头坏了"而自动禁用）。

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

## 2.0.1 修的是什么（"相机开了但不录入"）

症状：相机预览正常、人就站在镜头前，但进度一直 `0 / 5`。

三个叠加的 bug，都在共享的 `FacePrint.m` 里 —— 也就是说**录入和锁屏匹配同时是坏的**：

| # | Bug | 真相 |
|---|---|---|
| 1 | **缓冲区方向** | `AVCaptureVideoDataOutput` **不会**按 `connection.videoOrientation` 旋转输出缓冲区。竖屏采集拿到的仍是横向 640×480，人脸是横躺的；Vision 用默认 `.up` 去检测，基本检不到 |
| 2 | **请求连坐** | 人脸矩形和画质两个请求塞在同一次 `performRequests:` 里，整体返回 NO 就 `return nil` —— 画质请求一失败，明明已经拿到的矩形结果也被扔掉 |
| 3 | **裁剪错位** | 兜底特征路径用未旋转的图 + 已旋转坐标系的人脸框，裁出来的不是脸，特征指纹自然没用 |

修法：

- **方向自动探测**：按固定顺序（`right → left → up → down → 四个镜像`）试
  `initWithCVPixelBuffer:orientation:options:`，第一个真正检出脸的方向被缓存。
  App 与插件用同一颗摄像头、同一 preset、同一像素格式，所以收敛到同一个值，
  特征指纹保持可比。
- **只认矩形请求**：`performRequests:` 的返回值不再决定成败，`rectReq.results`
  有结果就算检出；画质改成独立的**可选增强**，失败只是"质量未知"，不丢帧。
- **裁剪跟随方向**：先 `imageByApplyingOrientation:` 对齐，再用 Vision 的
  boundingBox（左下原点）直接映射到 CIImage extent，逐像素对得上。
- **质量分级提示**：检到脸但质量低时提示"太暗/太糊（q=0.xx）"，不再和"没人脸"混为一谈。

录入界面底部新增一行实时计量：

```
帧 128 · 检测 12 · 命中 11 · 方向 right · 质量 0.68
```

| 计量表现 | 说明 |
|---|---|
| `帧` 一直是 0 | 相机没出帧（会话/权限问题） |
| `帧` 在涨、`检测` 在涨、`命中` 一直 0 | 帧到了但 Vision 检不到脸（方向/光线/遮挡） |
| `命中` 在涨但进度仍 0/5 | 检到脸了，卡在特征提取或保存 |

---

## 2.1.0 修的是什么（"预览是活的，但 帧 0"）

症状：预览层里人清清楚楚，底部却写着 `帧 0 · 检测 0 · 命中 0`，并弹出
「相机在跑，但一帧画面都没收到」。

这两个事实同时成立，只有一个解释：**`AVCaptureVideoDataOutput` 的回调一次都没被调用**。
预览层用的是它自己独立的连接，所以画面照常渲染，跟数据输出能不能出帧是两件事。

这一版做了三件事，都是针对这个断点：

| 改动 | 为什么 |
|---|---|
| **会话队列与回调队列分开** | `startRunning` 是阻塞调用。原来它和采样回调共用同一个串行队列，首帧可能被卡在队列后面（严重时永久出不来）。现在 start/stop 走独立队列 |
| **像素格式改成协商** | 不再硬写 32BGRA。先问 `availableVideoPixelFormatTypes` 支持什么，支持才设；硬要一个连接产不出的格式，结果就是"会话在跑、零缓冲" |
| **双通路采集** | 起会话后 2.5 秒仍 `帧 0` → 自动切到 `AVCapturePhotoOutput` 逐张拍照（1 张/秒），用照片的 `pixelBuffer` 走同一套检测。拍照是**按需触发**的独立管道，不受视频流是否阻塞影响 |

同时补了三条能直接定位的证据：

- `didDropSampleBuffer:` 计数 → 屏幕上的 `丢 N`。**`丢` 在涨说明相机其实在产帧**，
  只是被丢弃了（回调队列太慢），这和"完全没有帧"是两种病。
- 日志里记录 `preset / fmts / chosen / conn.enabled`，一条 `session:` 行说清配置结果。
- 底部计量改成两行，且**上移**避开屏幕底边：

```
帧 128 · 检测 12 · 命中 11 · 源 视频
Vision 640x480 丢0 方向right · rect: 1 face(s)
```

`源 视频` = 视频流在供帧；`源 照片` = 视频流哑了，已自动改用逐张拍照。
两种来源走同一个 `processPixelBuffer:`，采样逻辑完全一致，录入与锁屏匹配仍然可比。

插件侧同样把 `startRunning` / `stopRunning` 移出采样队列，像素格式同样改成协商。

---

## 使用方法

1. 从 GitHub Actions artifact 下载 `com.ray835999.faceunlock_2.2.0-1+debug_iphoneos-arm64.deb`。
2. 传到手机（Filza / SSH），Sileo / Zebra 安装或 `dpkg -i`（rootless 自动装到 `/var/jb`）。
   安装脚本会自动 `uicache`，桌面出现 **FaceUnlock** 图标。
3. **先设好锁屏密码**（和 Vizage 一样的前提）。
4. **重装后必须注销/重启一次**，否则插件不会重新注入 SpringBoard。
5. 打开 **FaceUnlock** → 点 **① 开始录入人脸** → 把脸放进圆圈，自动采集 5 个样本。
   如果底部一直 `帧 0`，它会自己换格式重试；四档都失败时右下角会出现 **系统相机拍照**，
   用它按 5 次快门一样能完成录入。
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
