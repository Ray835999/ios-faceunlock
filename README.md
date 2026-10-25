# FaceUnlock 2.5.0 — 摄像头人脸解锁（iPhone 6s / iOS 15 rootless）

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

## 2.5.0 修的是什么（"拍完相机没反应，只能点取消"）

系统相机（`UIImagePickerController`）在这台机器上**判定为不可用**：拍完第一张后，
它自己的界面只剩"取消"活着 —— 快门、"使用照片"全部点不动。这修不了，那是系统
相机 UI 在这个越狱环境里自己卡死了。

所以快门搬进我们自己的页面，**系统相机这条路整体删除**。

| 做法 | 为什么 |
|---|---|
| 新增 `FUSShotViewController` | 会话里只有 `AVCaptureDeviceInput` + `AVCaptureVideoPreviewLayer` + `AVCapturePhotoOutput`，**不挂 `AVCaptureVideoDataOutput`** —— 那条路一帧都没给过；静态拍照走 ISP，跟它完全独立 |
| **快门是我们自己的 `UIButton`** | 不依赖系统相机 UI，不会被它拖死。连按 5 次也归我们管 |
| 5 秒没有回调就强制解锁快门 | 快门不会永久卡在"正在拍照…" |
| 每张都有屏内回执 | 「识别中…」→「很好 · 稍微换个角度」/「没检测到人脸 · 正对镜头」/「太暗/太糊」 |
| 采到第 N 张就出现「完成（N 张）」 | 不用凑满 5 张，少几张也能存 |
| **系统相机代码路径整体删除** | `setCameraDevice:` / `presentSystemCamera` 在产物里**彻底缺席**（字节级核验），再也不会误点到那个卡死的界面 |
| 只留相册（`sourceType = PhotoLibrary`） | 相册不碰摄像头，是最后一道保险 |

录入流程变成：点 **「打开相机录入」** → 我们自己的相机页 → 按白色圆钮拍一张 →
屏上进度 `1 / 5`、下面写「很好 · 稍微换个角度」→ 拍满或点右下 **「完成（N 张）」**。

---

## 2.4.0 修的是什么（"系统相机拍完 1 张就点不动拍照按钮了"）

拍完第一张、点了「使用照片」之后，第二台系统相机起来了，但**快门是灰的、按不动**。

| 真凶 | 说明 |
|---|---|
| 连弹 picker 太快 | 第一台 picker 关闭时系统还在释放摄像头，第二台立刻抢设备，只拿到一个"预览在、快门死"的界面 |
| 程序自己重开 | 拍完一张后代码又自动弹一台相机 —— 用户没准备好，看到的是一台不听话的相机 |
| 没有退路 | 快门一哑，`_collected` 里明明已经有 1 张也存不下去，只能取消重来 |

这一版把"**能录进去**"当硬指标：

- **拍一张就能完成。** `_collected.count >= 1` 之后右边按钮变成 **「用这 N 张完成」**，点了直接写盘（`saveTemplates` 接受任意数量），成功弹窗会写明"只保存了 N 个样本（目标是 5 个）"。`n == 0` 时拒绝写盘，不会把已有的好模板覆盖成空。
- **不再自动重开相机。** 拍完一张就停在你手上，左边按钮变成 **「再拍一张（已 N/5）」**，你点它才动。
- **相册是确定能用的补样本通道。** 点「再拍一张」弹菜单：用系统相机拍 / **从相册选一张**。相册 picker 完全不碰 capture device，永远不会哑。系统相机只能拍一张时，先用系统相机 App 拍几张自拍存进相册，回来选就行 —— 这是唯一能稳定凑满 5 张的路。
- **弹 picker 前后留余量**：`stopRunning` 之后再等 0.25s 才弹；如果 2 秒内 picker 没能成为 presented controller，屏幕上直接说"相机界面没能打开"，不留死屏。presenting 冲突会重试 4 次，而不是静默放弃。
- **取消不再清 `_manualMode`**，取消之后两个按钮照旧可用。
- 新增 `NSPhotoLibraryUsageDescription`（缺这个，present 相册 picker 会直接崩）。

---

## 2.3.0 修的是什么（"录入闪一下像崩了、系统相机拍完没反应、点取消就没了"）

三个症状，三个各自独立的真凶，都在采集层：

| 症状 | 真凶 |
|---|---|
| 一进录入页**闪一下、像崩了** | 2.2.0 的四档"格式阶梯"每档都**拆掉会话重建**，每次重建都要摘掉预览层再 `startRunning` —— 屏幕上是黑一下、亮一下、再黑一下。拆到一半的会话还会让下一次 `startRunning` 未必成功 |
| **系统相机拍完没反应** | 打开系统相机前只做了**异步** `stopRunning`，picker 就在会话还没真释放摄像头时被弹出来 —— 苹果自己的相机拿不到设备，按快门等于按在空气上 |
| **点取消就没了** | 取消后直接落到黑屏，没有任何提示和退路 |

这一版改成 **一个会话、两个帧源、零会话重建**：

| 改动 | 为什么 |
|---|---|
| `AVCaptureVideoDataOutput` **完全不设 `videoSettings`** | 强制像素格式正是让连接哑掉的原因。交给 AVFoundation 自己协商，摄像头才肯出帧。`FacePrint` 走 CIImage/Vision，本来就不关心格式 |
| 没有阶梯，**一次建好就用** | 不再拆会话 = 不再闪。预览层全程只挂一个 session |
| 视频没帧 → **同一个会话**用 `AVCapturePhotoOutput` 连拍（1 张/秒） | 不拆会话、不抢设备、不重建。拍照走的是 ISP 的静态通路，跟视频通路的哑不哑无关 |
| 系统相机**等会话真的停了**才弹 | `teardownSessionThen:` 把 stop 做完再 present，苹果相机一定能拿到摄像头 |
| 每拍一张都有**屏内回执** | "收到照片，正在识别…" → "很好，稍微换个角度" / "没检测到人脸…"。不会再出现"点了没反应" |
| 取消要给**明确去处** | 弹提示写清"已采集 N/5"，并提示点「系统相机拍照」或「重试打开相机」 |

底部计量仍是三行，一眼定位：

```
帧 128 检测 12 命中 11 · 视频
640x480 丢0 快门0 失败0
run1 act1 en1 photo1 · rect: 1 face(s) (orient right)
```

第二行的 `快门/失败` 是静态通路的计数器：`快门>0` 说明拍照通路活着，
`失败` 连涨 3 次会自动把「系统相机拍照」按钮点亮。

插件侧只做**一处**最小改动：阶梯第 0 档改成"不设 `videoSettings`"（`default(0)`），
后面两档才是显式的 `420f`/`420v`。原来 3 秒无帧先换格式、全败才计崩溃计数的逻辑不变。

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

1. 从 GitHub Actions artifact 下载 `com.ray835999.faceunlock_2.5.0-1+debug_iphoneos-arm64.deb`。
2. 传到手机（Filza / SSH），Sileo / Zebra 安装或 `dpkg -i`（rootless 自动装到 `/var/jb`）。
   安装脚本会自动 `uicache`，桌面出现 **FaceUnlock** 图标。
3. **先设好锁屏密码**（和 Vizage 一样的前提）。
4. **重装后必须注销/重启一次**，否则插件不会重新注入 SpringBoard。
5. 打开 **FaceUnlock** → 点 **① 开始录入人脸**。
   自动取帧通路一直 `帧 0` 时，点蓝色 **「打开相机录入」**：这是我们自己的相机页，
   按下面白色圆钮拍一张，进度会变成 `1 / 5`。
   - 拍满 5 张自动保存；**不满也能点右下「完成（N 张）」先存**；
   - 相机页里任何按钮都是我们的 `UIButton`，不会再出现"只能点取消"；
   - 想用现成自拍 → 点「再拍一张」→ 菜单里 **从相册选一张**。
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
