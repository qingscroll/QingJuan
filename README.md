<!-- markdownlint-disable MD033 MD041 -->
<p align="center">
  <img alt="青卷 LOGO" src="./assets/logo.png" width="160" height="160" />
</p>

<h1 align="center">青卷 QingJuan</h1>

<p align="center">
  Windows 与 Android 小说、漫画下载、翻译和阅读客户端
</p>

青卷使用 Flutter 构建 Windows 与 Android 客户端，并为 FastAPI 后端提供 React 管理界面。Windows 可使用安装包内的
本机后端，也可与 Android 一起连接 Linux 远程后端；书库、下载、翻译和任务由当前选中的后端管理。

Windows 与 Android 共用业务能力，但采用两套独立界面：Windows 保持 v1.3.4 的 Fluent/Windows 仿原生桌面风格，
Android 使用触控优先的移动端风格；窗口宽度变化不会让两种平台界面互相切换。

> 项目仍在持续开发。网站规则变化时，部分下载功能可能暂时失效。请只保存你有权访问的内容。

## 功能

- 从常见小说、漫画网站导入作品
- 导入本地 `TXT`、`DOCX`、`EPUB` 和 `PDF`
- 下载章节并查看任务进度
- 使用 OpenAI 兼容接口翻译小说和漫画
- 在桌面漫画翻译工作台中批量处理图片，并支持正常翻译、导出译文、导出原文、仅翻译工程 JSON、导入译文并渲染、仅上色、仅超分、仅修复和替换翻译九种工作流
- 导出 `TXT`、`DOCX`、`EPUB`、`PDF` 或图片压缩包
- 阅读原文和译文，保存阅读进度
- 使用设备系统 TTS 听书
- 支持亮色、深色和跟随系统主题

目前支持番茄小说、起点中文网、夸克小说、笔趣阁、刺猬猫、SF 轻小说、少年梦、哔哩轻小说、Kakuyomu、Syosetu、Novel18、Pixiv、Yanmaga、Webtoon、拷贝漫画、COMICORES、动漫之家、
18Comic、Bika、E-Hentai 等站点，也支持导入 Legado / 阅读 App JSON 书源。搜索页可选择“书源”“夸克”“番茄”“起点”或“笔趣阁”；内置解析器会保留目录中的全部章节，并在上游返回可解析内容时默认保存，不因 VIP、订阅或付费标记提前跳过。未实现章节解析或上游未返回可用内容时会明确提示。Windows 本机模式在客户端“插件配置”中启停内置解析器；
Linux 远程模式在服务器管理界面的“插件管理”中统一维护，客户端会自动隐藏该入口。外部规则仍只在“书源管理”中管理。

番茄与起点插件支持扫码登录；番茄扫码受限时也可粘贴已登录浏览器请求的 Cookie。连接成功后可一键添加当前账号书架，
文字作品按“边看边下”方式加入，已有作品会自动跳过。登录凭据只保存在当前后端进程内存中，后端重启后需要重新登录。

## 支持平台

| 平台 | 支持范围 | 安装包 |
| --- | --- | --- |
| Windows | Windows 10 / 11 x64 | `QingJuan-v<版本>-windows-x64.zip` |
| Android | Android 8.0（API 26）或更高版本 | `QingJuan-v<版本>-android.apk` |
| Linux | x86_64、systemd、Python 3.11+ 服务端 | 原生部署脚本 |

Windows ZIP 包含本机后端，可在“本机后端 / Linux 远程后端”之间选择；Android 必须连接 Linux 服务端。

## 使用方法

### 1. 安装客户端

从 [Releases](https://github.com/Tavre/QingJuan/releases/latest) 下载对应平台的安装包：

- Windows：完整解压 Windows x64 ZIP，运行 `qingjuan.exe`。需要单机使用时在设置中选择“本机后端”。
- Android：下载 APK，在手机或平板确认来源后安装。

### 2. 可选：部署 Linux 后端

Android 或 Windows 远程模式需要 Linux 服务端；只使用 Windows 本机模式时可以跳过本节。

先在 Linux 服务器执行：

```bash
sudo mkdir -p /opt/qingjuan
sudo git clone https://github.com/Tavre/QingJuan.git /opt/qingjuan/app
cd /opt/qingjuan/app
sudo bash deploy/linux/install.sh
sudo qingjuan-info
```

安装脚本会自动识别服务器的 Tailscale、WireGuard 或局域网 IP。安装完成后会显示管理界面地址、首次登录的
随机管理密码、FastAPI 地址和连接 Token。管理密码只显示一次；公网服务器请使用
`--url https://你的域名` 指定已配置反向代理的 HTTPS 地址。

浏览器打开终端显示的管理界面地址，即可查看服务概览、连接设备、用户、注册设置、系统诊断、后端升级、后端 API 密钥、任务和服务器运行日志，
以及书库、书源、插件和模型设置。管理员可创建或停用用户、编辑账号显示资料、重置密码、提权或降权，并撤销登录会话；内置 `admin` 始终保留管理员权限。提权后的客户端账号可以维护服务级配置，但浏览器管理界面继续使用独立管理密码。系统诊断可下载不含凭据和服务器路径的脱敏报告；API 密钥默认遮挡，只在管理员主动点击后
短暂显示。注册设置可独立启用邮箱验证码和固定身份牌，两项同时启用时新用户必须全部通过；自主注册始终要求唯一邮箱，SMTP 密码、身份牌和验证码不会由管理接口回显。管理员还可配置 GitHub OAuth App Device Flow；已注册用户可自行绑定 GitHub，并可选择启用基于验证器应用的 TOTP 两步验证与一次性恢复码。GitHub 不会自动创建本地账号，也不会获得邮箱或仓库权限。Linux 后端的翻译模型在管理界面配置并支持自检；Windows / Android 远程连接后会自动检查服务端模型，
不在客户端保存模型密钥或直连模型供应商。忘记管理密码时运行：

```bash
sudo qingjuan-password --generate
```

### 3. 选择后端

打开 **设置 → 后端连接**：

- Windows 本机模式：选择“本机后端”并保存，应用会按需启动安装包内的后端，无需 Token；本机后端不启动浏览器管理界面，
  翻译模型、API 密钥、系统提示词和外部 OCR 直接在客户端“设置 → 翻译服务”中配置。
- Windows 远程模式或 Android：填写服务器显示的“FastAPI 地址”和“连接 Token”，保存连接后在“我的”中注册或登录。Linux
  后端会按用户隔离书架、阅读进度和任务；`admin` 可使用服务器管理密码登录默认管理员账号。书源、插件和模型属于服务级配置，
  普通用户可使用，只有管理员能修改；Bika 登录凭据也按服务级配置共享，不属于用户书架账号。

远程 FastAPI 地址不要添加 `/api/v1`。公网访问必须使用 HTTPS，不要直接暴露公网 HTTP 端口；远程连接失败时不会
自动回退本机。切换模式会切换到另一套后端数据，但会保留安全存储中的远程连接信息。

常用服务器命令：

```bash
# 查看状态
sudo systemctl status qingjuan-backend --no-pager

# 查看日志
sudo journalctl -u qingjuan-backend -f

# 更新后端
sudo bash /opt/qingjuan/app/deploy/linux/update.sh

# 查看在线升级任务日志
sudo journalctl -u qingjuan-updater -n 100 --no-pager

# 修改管理界面密码
sudo qingjuan-password

# 卸载并保留书库数据与 2FA 解密配置
sudo qingjuan-uninstall
```

新版安装会启用受控的 systemd 在线升级器。之后可在管理界面的“后端升级”中检查并安装固定部署仓库的上游版本；
页面不接受仓库地址、分支或命令参数。升级器在独立服务中运行，下载、安装依赖和预检期间后端保持在线，只在最终切换时
短暂重启，客户端会显示恢复状态并自动重新探测。若从不含在线升级器的旧版本迁移，第一次命令更新完成后管理页仍提示
“尚未启用在线升级”时，再执行一次上面的更新命令完成一次性引导，之后即可使用管理界面升级。

需要连同书库一起永久删除时，直接运行
`sudo qingjuan-uninstall --purge-data`，不要先执行普通卸载。

### 4. 漫画翻译工作台

Windows 客户端连接到可用后端后，可从侧栏进入“漫画翻译”。工作台支持直接从书架选择漫画，也支持选择图片、递归选择文件夹
或直接拖放文件与文件夹；在书籍详情中点击“漫画翻译”会自动导入全部章节，勾选章节后则只导入所选章节并打开同一个工作台。
工作台提供正常翻译、导出译文、导出原文、仅翻译工程 JSON、导入译文并渲染、仅上色、仅超分、仅修复和替换翻译九种模式。
任务可以随时停止；已完成文件会保留，未完成文件可在修正配置后重新执行。

每张图片都可进入三栏文本修改工作台：左侧切换页面，中间在原图与译图上核对文字框，右侧直接修改原文、译文和排版方向。
可筛选尚未翻译的区域，也可在图片上拖框补录 OCR 完全漏检的对白；保存后无需再次调用 OCR 或翻译模型即可重新擦字、排版并渲染。

默认输出到输入目录旁的 `manga_translator_work/`，工程 JSON 位于 `json/`，最终图片位于 `result/`；导入译文和替换翻译时，
可将同名译文图片放入 `translated_images/`，扩展名可以与原图不同。翻译继续使用青卷当前后端配置的 OCR、模型和渲染链路；
短语气词、感叹词和拟声词也会进入逐区域翻译；模型漏项、重复项会整批重试，原样返回的日文区域会单独定向重试。
若裁切招牌或拟声片段仍无法可靠翻译，青卷会保留该区域原图、记录诊断并继续生成页面，不再让单个片段拖垮整页。书架来源的正常翻译、
导入译文并渲染和替换翻译任务在整章全部页面成功后，会直接写入该章节的“译文”；任一页面失败时不会发布残缺章节。
文本工作台重新渲染书架来源页面时同样会按完整章节写回；若本章仍有页面尚未生成工程或结果图，本地修改会保留并明确提示缺页，避免覆盖为残缺译文。
旧版工程缺少气泡几何信息时，原文清理会退回到受 OCR 文字框约束的墨迹蒙版，避免纵排文字边角残留；新工程会保存气泡框、安全框与样式元数据，后续重载不再退化。
工作流模式、交互和工程目录与下方致谢的上游项目保持一致，上色与超分等执行实现则适配青卷现有能力。

## 数据与安全

- Windows 本机数据保存在完整解压目录的 `backend/data/`
- Linux 数据保存在 `/var/lib/qingjuan`
- Linux 用户启用 2FA 后，备份或迁移必须同时保存 `/var/lib/qingjuan` 与受限的
  `/etc/qingjuan/backend.env`；其中的独立 2FA 密钥与数据库缺一不可。普通卸载会同时保留两者，
  `--purge-data` 才会永久删除
- Android 以及 Windows 远程模式只在设备上保存界面偏好，以及平台安全存储保护的连接 Token 和用户会话 Token
- Windows 本机数据与 Linux 数据不会自动同步；更新或迁移前请备份当前使用的数据及其配套密钥
- 不要公开连接 Token、翻译 API 密钥、Cookie、数据库和下载内容
- 不要公开管理密码；终端改密后，原有管理界面会话会自动退出
- 连接建议使用局域网、Tailscale / WireGuard；公网访问必须使用 HTTPS

## 开发、构建与 CI

开发环境、架构、测试、构建、CI 与发布要求统一见[开发文档](./docs/development/README.md)。
欢迎提交 [Issue](https://github.com/Tavre/QingJuan/issues) 或 Pull Request；提交前请遵循开发文档并移除密钥、账号和个人数据。

## 交流

- GitHub：[Tavre/QingJuan](https://github.com/Tavre/QingJuan)
- QQ 群：`1074882763`
- 安全问题请使用 GitHub 的 **Security → Report a vulnerability** 私密报告

## 许可与致谢

本项目使用 [GNU GPL v3](./LICENSE) 许可证。

感谢[所有贡献者](https://github.com/Tavre/QingJuan/graphs/contributors)，包括[Linux do](https://linux.do) 社区，以及Flutter、FastAPI、RapidOCR、
`fluent_ui`、[fanqie-assistant](https://github.com/naiyQAQ/fanqie-assistant) 等开源项目。

桌面端漫画翻译工作台的工作流模式、工程目录约定和交互设计借用并复刻自
[hgmzhn/manga-translator-ui](https://github.com/hgmzhn/manga-translator-ui)。原项目以 GPL-3.0 发布；
本项目已取得原作者授权，并在此保留借用与来源声明。
