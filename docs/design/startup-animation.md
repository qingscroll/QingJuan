# 开屏动画

青卷启动时立即挂载 `AppStartup`，显示居中的黑白线条 Logo；读取本地配置、连接后端和恢复工作区在其后进行。主应用只挂载一次，就绪后撤下开屏。

开屏使用青卷自己的卷轴 Logo，轮廓来自 `assets/logo.png`。保留原图的卷轴比例、上下弧线、端帽和环纹，去掉白色圆角底板及阴影，以黑白线条呈现。动效参考 Windows Codex **26.908.4834** 的 `webview/index.html` 内 `startup-loader`。

| 参数 | 实现 |
| --- | --- |
| Logo | 青卷卷轴轮廓居中放入 21 × 21 坐标框，以 56 × 56 逻辑像素绘制，保持原始宽高比 |
| 入场 | 延迟 60 ms，180 ms `cubic-bezier(0, 0, .58, 1)` 淡入 |
| 扫光 | 2200 ms 循环，`cubic-bezier(.4, 0, .2, 1)` |
| 光带 | 112°，图像宽度 220%，位置从 140% 到 −105% |
| 渐变 | 22% 透明、38% 白色 4%、49% 白色 48%、56% 白色 8%、74% 透明 |
| 基础线条 | 浅色：黑色 24%；深色：白色 68% |
| 背景 | 浅色纯白、深色纯黑；Codex 原始容器背景为透明 |

从现有 PNG 的彩色前景描出卷轴轮廓，保存为 Flutter `Path`，原始品牌图片保持不变。扫光通过 `CustomPainter` 的重绘监听实现，不增加 SVG、视频或动效包。光带位置按 CSS 的背景定位规则计算，保留参考动效的角度和宽度。

青卷自己的启动退场策略：至少展示 900 ms，初始化完成后用 180 ms 淡出。长时间初始化时继续循环，8 秒后提供进入已挂载应用的入口；连接失败或未配置服务时仍进入既有设置页面。配置读取失败显示重试按钮。系统要求减少动态效果时显示静态标志，并取消最短等待和退场动画。

验证命令：

```powershell
flutter test --no-pub test/shared/startup_splash_test.dart test/app/app_startup_test.dart
flutter test --no-pub --dart-define=QINGJUAN_CAPTURE_STARTUP=true test/shared/startup_splash_test.dart
```

第二条命令输出桌面和手机、浅色和深色的 Flutter 实际渲染帧到 `build/startup-review/`，并记录一轮卷轴动画帧供视觉检查。
