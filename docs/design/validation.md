# 移动端重构验证报告

验证日期：2026-09-05。本轮在小液态胶囊导航与黑色主题基础上统一主操作按钮及配色，重新执行全量 Flutter 检查、截图和双平台调试构建。这里区分自动化 Widget / 单元测试、真实 HTTP 服务验证、平台构建和设备验收。通过某一层不能推断其他层已通过。

## 最终检查状态

| 检查 | 结果 | 证据与范围 |
| --- | --- | --- |
| Dart 格式 | 通过 | `dart format --output=none --set-exit-if-changed lib test`，167个文件、0个更改；`build/action-format.log` |
| Flutter 静态分析 | 通过 | `flutter analyze --no-pub`，无问题，8.2秒；本机日志 `build/action-analyze.log` |
| Flutter 全量测试 | 通过 | `flutter test --no-pub --dart-define=QINGJUAN_CAPTURE_MOBILE_UI=true`，314项全部通过，25秒；本机日志 `build/action-full-tests.log` |
| 补丁空白检查 | 通过 | `git diff --check` |
| UI 渲染产物 | 已生成并归档 | 47张最终 PNG，[截图清单](screenshots.md)；Widget fixture，非真机截图 |
| 真实 HTTP 主路径 | 上一轮通过，本轮未重跑 | 35项检查全部通过；[机器可读报告](mobile-backend-smoke.json)保留原始运行时间 |
| HTTP 脚本静态检查 | 上一轮通过，本轮未重跑 | `python -m ruff check --config python-backend/pyproject.toml tool/mobile_backend_smoke.py` |
| Android debug APK | 通过 | `flutter build apk --debug --no-pub` 成功，17.9秒；`build/action-android-build.log` |
| Windows debug 客户端 | 通过 | `flutter build windows --debug --no-pub` 成功，17.3秒；`build/action-windows-build.log` |
| 后端全量 pytest | 本轮未运行 | 后端生产代码未改；上一轮独立35项 HTTP 检查不等同全量后端测试 |
| React 管理端测试 / 构建 | 本轮未运行 | `admin-web` 与 `python-backend/app/admin_static` 无差异；不将只读审查视作运行验证 |
| Android 设备验收 | 未运行 | 无已连接 Android 设备，也无可用 AVD |

上一轮记录为309项全量测试、平板布局调整后35项移动复测。本轮314项全量测试已包含平板修正和新的主操作按钮；报告使用本轮结果，不累计不同轮次的测试数。

## 可运行构建产物

| 平台 | 本机产物 | 大小与使用方式 |
| --- | --- | --- |
| Android debug | `build/app/outputs/flutter-apk/app-debug.apk` | 195,496,649字节；为调试包，已构建但未安装到设备 |
| Windows debug | `build/windows/x64/runner/Debug/` | `qingjuan.exe` 为1,361,408字节；运行时需要整个 Debug 目录，不能只复制EXE |

两者均包含本轮主操作按钮和配色。Android APK于本机时间2026-09-05 23:41:05生成。Windows 增量构建中原生EXE没有变化，Dart资源 `data/flutter_assets/kernel_blob.bin` 为75,770,224字节，已于23:41:19更新。这里交付的是调试构建验证，不是签名发布包、安装器或真机运行验收。

## 工具链与平台隔离

本机执行使用 Flutter master 3.48、Dart 3.14。仓库 [CI 配置](../../.github/workflows/ci.yml) 使用 Flutter stable 3.44.4；本报告没有将 CI 配置视作 stable 渠道已经实际跑过的结果。`ScrollCacheExtent` 已在 Flutter 3.44 stable 提供，迁移依据见 [Flutter 官方说明](https://docs.flutter.dev/release/breaking-changes/scroll-cache-extent)。

Android 使用移动壳层且依赖远程后端；Windows 保留 Fluent 桌面入口和本机 / 远程后端选择。平台分支不会因窗口变窄而互换。共享阅读与账号逻辑通过明确的移动分支适配，已有桌面阅读器和账号测试包含在314项全量测试中。React 管理界面没有界面重构改动。

## Widget 与交互验证

| 场景 | 已执行的检查 | 未覆盖的设备行为 |
| --- | --- | --- |
| 导航与适配 | 320dp、200%文字、48dp目标、安全区、减少动态效果 / 高对比关闭模糊、语义点击、平板键盘边距下导航可达、系统返回路由 | Android 真实返回手势、系统导航栏和输入法 |
| 深浅主题与按钮 | 主要文字、次文字、选中态、错误反馈和主操作按钮的被测颜色组合对比度至少4.5；47张实际 Widget 渲染；登录、来源导入和听书按钮流程保持可操作 | 不等同整个界面的无障碍认证，也未运行设备读屏逐项验收 |
| 书库与发现 | 筛选、搜索、滚动上下文、账号 / 后端切换隔离、断连保留内容、导入及进度恢复入口 | 真实外部书源成功搜索、上游解析可用性 |
| 任务与来源 | 服务端37.5%进度正确映射为控件0.375；失败仅重试一次；导入进行中关闭页面；普通用户来源只读 | 真实网络波动下的长期后台任务 |
| 账号安全 | 密码登录衔接TOTP；注册遵循验证码和身份牌策略；错误重试；窄屏大字的账号安全与两步验证；GitHub可信地址及解绑边界 | 真实邮箱投递、GitHub外部授权回跳和设备安全存储 |
| 小说与漫画 | 长章节按需构建、正文与控制栏、音量翻页、排版 / 初始位置恢复、目录跳转、单图错误恢复与缩放结构 | 长漫画真机帧率、图片内存峰值、原生音量键分发 |
| 听书 | 播放控制、章节切换、速度与音量、翻译切换和引擎状态 | Android 设备TTS音色、实际发声及音频中断策略 |

输入法截图通过 `FakeViewPadding` 注入底部边距，TTS通过测试引擎验证；这些测试没有启动 Android 原生输入法或语音引擎。截图使用受控数据，也未冒充个人书库数据。

本轮已重新生成全部47张截图，复制归档后逐文件核对SHA256及清单索引。视觉复查包括书库浅色 / 深色、详情深色、任务深色、导入恢复深色、听书深色和发现页大字布局，确认新按钮与中性黑表面层次一致。

## 真实 HTTP 数据链路

[tool/mobile_backend_smoke.py](../../tool/mobile_backend_smoke.py) 启动独立的 uvicorn 回环网络服务，启用多用户模式，使用随机临时端口、独立临时数据目录及隔离标记。连接 Token、两步验证密钥、管理员会话密钥和随机密码仅在内存 / 进程环境中使用；报告不写出密钥、令牌或账号密码。测试不修改生产后端源码、用户书库或个人远端账号。

上一轮35项检查验证了以下实际 HTTP 路径；本轮只调整移动 UI，没有重跑该服务验证：

1. 连接元信息、注册策略和多用户能力；错误连接 Token 返回401。
2. 注册用户并恢复会话；普通用户导入书源返回403。
3. 通过 multipart 上传TXT，实际解析为2章，在本人书库获取详情并读取真实段落。
4. 保存章节、段落及比例进度；建立下载任务并轮询到 `completed`，真实进度100%、完成章节数与总数一致。
5. 翻译健康快照真实返回 `disabled`；强制管理员探测返回401。提交翻译后任务真实失败，原因明确为模型未启用 / 未配置；没有调用外部付费模型。
6. 第二位用户的书库隔离，访问第一位用户作品返回404。
7. 退出登录后旧会话返回401，重新登录仍恢复原有章节与段落进度。

该次运行35项全部通过，耗时2.48秒，自身临时服务已停止，该次临时数据已清理。结果见 [mobile-backend-smoke.json](mobile-backend-smoke.json)，记录时间为2026-09-05 15:15:38 UTC。该结果证明真实后端的 HTTP / 数据路径，未经过 Android 安装包，也未访问外部内容源；它与 Widget 页面行为测试共同提供证据，但不能替代 Android 连接实际远端的端到端验收。

在项目根目录复现：

```powershell
& python-backend/.venv/Scripts/python.exe tool/mobile_backend_smoke.py
& python-backend/.venv/Scripts/python.exe -m ruff check --config python-backend/pyproject.toml tool/mobile_backend_smoke.py
```

报告生成到 `build/mobile-backend-smoke.json`。脚本只终止自身启动的服务。

## 真实限制与设备待验收

- 尚无 Android 真机或可用 AVD：返回手势、系统栏、实际软键盘、原生文件选择与导出、设备TTS以及漫画解码性能仍待设备验收。
- 没有配置个人远程测试账号、可用外部书源或翻译模型。成功的外部搜索 / 链接解析 / 翻译需要相应服务；本次不虚构成功结果。
- 下载保存于服务端，不代表 Android 断网可读。当前链接导入仅在 Controller 内追踪一条任务，任务ID不跨应用重启保存；完成作品仍可刷新书库获取。
- TTS为页面级生命周期，离开听书页面会停止。连续排版的阅读恢复遵循现有比例协议，不能保证修改排版后的逐字锚点完全相同。

早期一次 HTTP 验证退出时遇到 Windows 文件占用，遗留临时目录 `C:\Users\29873\AppData\Local\Temp\qingjuan-mobile-smoke-dkcwia6i`。已停止该次自身服务并核对临时目录标记；目录只包含本次生成的测试书籍、数据库、日志及随机测试凭据的哈希，不含生产用户数据。最新成功运行的目录已正常清理，两者不能混为一谈。

自动批准审查拒绝了对此确切临时目录执行 `Remove-Item -LiteralPath … -Recurse -Force` 的清理操作，返回原因仅为 `blocked by policy`，未提供更具体原因。该目录仍保留，未继续尝试删除或绕过限制。
