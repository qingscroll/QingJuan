# 移动端重构验证报告

更新日期：2026-09-06。本轮根据安装包截图修复真实二级路由的文字继承、冗余加载文字及过重按钮。Flutter检查、59张截图与Android Release测试包已完成。这里区分自动化 Widget / 单元测试、真实 HTTP 服务验证、平台构建和设备验收，历史通过记录不替代本轮结果。

## 最终检查状态

| 检查 | 结果 | 证据与范围 |
| --- | --- | --- |
| Dart 格式 | 通过 | `dart format --output=none --set-exit-if-changed lib test`，178个文件、0个更改；`build/text-fix-format.log` |
| Flutter 静态分析 | 通过 | `flutter analyze --no-pub`，无问题，15.8秒；`build/text-fix-analyze.log` |
| Flutter 全量测试 | 通过 | `flutter test --no-pub --dart-define=QINGJUAN_CAPTURE_MOBILE_UI=true`，354项全部通过，26秒；`build/text-fix-full-tests.log` |
| 补丁空白检查 | 通过 | `git diff --check` |
| UI 渲染产物 | 59张已生成并归档 | 原47张场景增加12张实际应用路由：详情4张、阅读器8张；归档SHA256一致，[截图清单](screenshots.md)；Widget fixture，非真机截图 |
| 真实 HTTP 主路径 | 上一轮通过，本轮未重跑 | 35项检查全部通过；[机器可读报告](mobile-backend-smoke.json)保留原始运行时间 |
| HTTP 脚本静态检查 | 上一轮通过，本轮未重跑 | `python -m ruff check --config python-backend/pyproject.toml tool/mobile_backend_smoke.py` |
| Android 测试APK | 通过 | `flutter build apk --release --no-pub`，204.7秒；v2.1.0 / build41，Release模式、本机测试签名；`build/text-fix-android-release.log` |
| Windows debug 客户端 | 通过 | `flutter build windows --debug --no-pub`，58.4秒；`build/text-fix-windows-build.log` |
| 后端全量 pytest | 本轮未运行 | 后端生产代码未改；上一轮独立35项 HTTP 检查不等同全量后端测试 |
| React 管理端测试 / 构建 | 本轮未运行 | `admin-web` 与 `python-backend/app/admin_static` 无差异；不将只读审查视作运行验证 |
| Android 设备验收 | 未运行 | 本轮 `adb devices` 列表仍为空，无可用 AVD |

上一轮314项全量测试通过，167文件格式检查无更改，静态分析无问题，日志为 `build/action-{full-tests,format,analyze}.log`。旧主页面测试外层额外包裹的 `FluentApp` 掩盖了真实应用文字继承问题，本轮已移除并增加从实际移动根应用进入详情 / 阅读器的回归，不能用旧测试通过记录说明该问题此前已覆盖。

## 构建产物

| 平台 | 本机产物 | 大小与使用方式 |
| --- | --- | --- |
| Android本轮测试包 | `release/android/QingJuan-v2.1.0-41-android.apk` | 66,208,120字节，Release模式、本机测试签名；2026-09-06 23:12:57生成 |
| Windows本轮debug | `build/windows/x64/runner/Debug/` | 本轮增量构建通过；运行时需要整个 Debug 目录，不能只复制EXE |

上一轮Android调试APK为195,496,649字节，于2026-09-05 23:41:05生成，不作为本轮截图反馈修复的安装包。本轮Windows已重新增量构建，Dart资源随构建更新。

本轮包以Release模式编译，使用本机测试证书签名（无 `android/key.properties`，与此前测试版本相同）。运行模式为Release，不是debug APK；该签名属于本地测试用途。

当前正式发布候选已更新为 `2.1.1+41`。上表的 `2.1.0+41` APK 生成于语义版本切换前，仅作为同一代码改动的本机 UI 与打包验证证据；正式 `2.1.1` 版本元数据和签名产物以标签触发的发布工作流为准。

`apksigner verify --verbose --print-certs` 校验通过，证书SHA256与此前测试包一致。`aapt dump badging` 确认包名 `com.tavre.qingjuan`、versionName `2.1.0`、versionCode `41`、minSdk26、targetSdk36，无 `application-debuggable` 标记；APK包含arm64-v8a、armeabi-v7a、x86_64三种AOT库，未包含调试kernel资源。日志为 `build/text-fix-apk-{signature,manifest}.log`。

交付APK与构建输出SHA256一致：`eb37b510cafdebf9c04b2d954668dd0a508e14fa618623c4cdeb9e58c8a638d6`，同名 `.sha256` 文件随包提供。Release构建存在已有AGP / Kotlin未来支持及Android SDK XML版本提示，构建成功，本轮未改动这些工具链版本。

## 工具链与平台隔离

本机执行使用 Flutter master 3.48、Dart 3.14。仓库 [CI 配置](../../.github/workflows/ci.yml) 使用 Flutter stable 3.44.4；本报告没有将 CI 配置视作 stable 渠道已经实际跑过的结果。`ScrollCacheExtent` 已在 Flutter 3.44 stable 提供，迁移依据见 [Flutter 官方说明](https://docs.flutter.dev/release/breaking-changes/scroll-cache-extent)。

Android 使用移动壳层且依赖远程后端；Windows 保留 Fluent 桌面入口和本机 / 远程后端选择。平台分支不会因窗口变窄而互换。共享阅读与账号逻辑通过明确的移动分支适配，已有桌面阅读器和账号测试保留。React 管理界面没有界面重构改动。

## Widget 与交互验证

| 场景 | 已执行的检查 | 未覆盖的设备行为 |
| --- | --- | --- |
| 真实应用路由与加载 | 从实际 `MobileQingJuanApp` 打开详情 / 阅读器的回归已通过；根正文w400、无文字装饰；移动加载只保留进度与读屏语义，Windows仍显示原标签 | 新安装包在用户设备上的复验 |
| 导航与适配 | 320dp、200%文字、48dp目标、安全区、减少动态效果 / 高对比关闭模糊、语义点击、平板键盘边距下导航可达、系统返回路由 | Android 真实返回手势、系统导航栏和输入法 |
| 深浅主题与按钮 | 主要文字、次文字、选中态、错误反馈和按钮颜色对比度断言通过；首页为“接着读 ›”行内操作，常见按钮调整为中性灰、14字号 / w500 / 10dp圆角 | 不等同整个界面的无障碍认证，也未运行设备读屏逐项验收 |
| 书库与发现 | 筛选、搜索、滚动上下文、账号 / 后端切换隔离、断连保留内容、导入及进度恢复入口 | 真实外部书源成功搜索、上游解析可用性 |
| 任务与来源 | 服务端37.5%进度正确映射为控件0.375；失败仅重试一次；导入进行中关闭页面；普通用户来源只读 | 真实网络波动下的长期后台任务 |
| 账号安全 | 密码登录衔接TOTP；注册遵循验证码和身份牌策略；错误重试；窄屏大字的账号安全与两步验证；GitHub可信地址及解绑边界 | 真实邮箱投递、GitHub外部授权回跳和设备安全存储 |
| 小说与漫画 | 长章节按需构建、正文与控制栏、音量翻页、排版 / 初始位置恢复、目录跳转、单图错误恢复与缩放结构 | 长漫画真机帧率、图片内存峰值、原生音量键分发 |
| 听书 | 播放控制、章节切换、速度与音量、翻译切换和引擎状态 | Android 设备TTS音色、实际发声及音频中断策略 |

输入法截图通过 `FakeViewPadding` 注入底部边距，TTS通过测试引擎验证；这些测试没有启动 Android 原生输入法或语音引擎。截图使用受控数据，也未冒充个人书库数据。

本轮59张截图已归档并逐文件核对SHA256一致。新增12张实际应用路由截图：详情的加载 / 内容浅深色4张，以及分页 / 连续阅读各自的加载 / 内容浅深色8张；仍使用受控模拟数据。

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
