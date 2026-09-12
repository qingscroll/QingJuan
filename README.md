<!-- markdownlint-disable MD033 MD041 -->
<p align="center">
  <img alt="青卷 LOGO" src="./assets/logo.png" width="160" height="160" />
</p>

<h1 align="center">青卷 QingJuan</h1>

<p align="center">
  Windows 与 Android 小说、漫画下载、翻译和阅读客户端
</p>

青卷由 Flutter 客户端和 FastAPI 后端组成。Windows 可使用安装包内的本机后端，也可连接 Linux 远程后端；Android 可连接 Linux 后端或通过局域网连接 PC 共享的本机后端。书库、下载、翻译和任务均由当前连接的后端管理。

> 项目仍在持续开发。网站规则变化时，部分下载功能可能暂时失效。请只保存你有权访问的内容。

## 功能

- 从小说、漫画网站或 Legado / 阅读 App JSON 书源导入作品
- 按站点浏览推荐栏目与排行榜，分页查看作品并直接加入书架
- 导入本地 `TXT`、`DOCX`、`EPUB` 和 `PDF`
- 下载章节、暂停/继续/取消任务并记录阅读进度
- 多链接导入、查看导入历史，重启后恢复未完成的导入
- 完整书库备份与恢复，显式迁移 Windows 本机书库到空的 Linux 服务端
- 使用 OpenAI 兼容接口翻译小说和漫画
- 支持漫画 OCR、文本校对、擦字、渲染、上色、超分和修复工作流
- 导出 `TXT`、`DOCX`、`EPUB`、`PDF` 或图片压缩包
- 手动或定时追更，保留旧章节与位置，按需下载新增章节
- 书库分组、标签、置顶与阅读状态，编辑书名、作者和简介
- 书签、划线笔记，以及已缓存章节的章内／全书正文搜索
- Android 选章保存到设备，断网阅读，联网后同步进度并提示跨设备冲突
- 设备系统 TTS、听书位置与定时停止，Android 通知栏及锁屏媒体控制
- 术语表、人名映射、小说译文校对、历史版本和选段重译
- 插件自检、兼容性检查与已安装版本回退
- 用户存储与模型请求配额、公平任务队列、书籍占用统计及导出文件清理
- 亮色、深色主题
- 账号自助改密、验证邮箱找回密码与登录会话管理

内置或适配番茄小说、起点中文网、夸克小说、笔趣阁、刺猬猫、SF 轻小说、哔哩轻小说、Kakuyomu、Syosetu、Pixiv、Webtoon、拷贝漫画、动漫之家、18Comic、Bika、E-Hentai 等来源。站点可用性取决于上游服务，插件开发与打包方式见[站点插件规范](./docs/development/07-site-plugin-spec.md)。

## 支持平台

| 平台 | 要求 | 运行方式 |
| --- | --- | --- |
| Windows | Windows 10 / 11 x64 | 本机后端或 Linux 远程后端 |
| Android | Android 8.0（API 26）及以上 | Linux 远程后端或 PC 局域网共享 |
| Linux 服务端 | x86_64、systemd、Python 3.11+ | FastAPI 后端与管理服务 |

## 快速开始

从 [Releases](https://github.com/qingscroll/QingJuan/releases/latest) 下载对应安装包：

- Windows：运行 `QingJuan-v<版本>-windows-x64-setup.exe` 安装；也可完整解压 `QingJuan-v<版本>-windows-x64.zip`，运行 `qingjuan.exe`。单机使用请选择“本机后端”。
- Android：安装 `QingJuan-v<版本>-android.apk`，连接已部署的 Linux 后端，或扫描 PC 设置中的连接二维码。

每次启动会在后台检查正式版更新；Windows 在“设置 → 软件更新”中检查、下载并安装，Android 在“我的 → 软件更新”中检查并打开新版 APK 下载。Windows 下载完成并通过 SHA-256 校验后，点击“退出并安装”启动安装向导；本机任务会中断，请先保存编辑内容。网络不可用时仍可正常使用软件并稍后重试。

Windows 默认安装到 `%LOCALAPPDATA%\Programs\QingJuan`，无需管理员权限。在线升级沿用当前安装或解压目录，保留 `backend/data/`；卸载也保留这些用户数据。手动从旧解压版迁移时请选择原目录，否则新目录不会自动读取旧书库。

### 手机扫码连接 PC（局域网）

1. 将手机和电脑连接到同一局域网，在 PC 青卷“设置 → 后端连接”中保存并连接后端。
2. 在“设置 → 手机连接”点击“生成连接二维码”。本机模式会开启受连接密钥保护的共享入口（所选内网 IP 的 TCP 19454 端口）；多网卡时可切换到手机所在网络的网卡。
3. 在手机青卷“我的 → 服务连接”选择“扫描二维码”，核对地址后点击“验证并连接”。也可在 PC 复制连接链接，再在手机粘贴；支持自定义链接的扫码应用可直接唤起青卷。

本机共享使用 PC 的同一份书库、任务和阅读进度，无需另建账号。使用期间保持 PC 青卷运行；Windows 防火墙提示时允许专用网络访问。关闭共享、切换 PC 到远程后端或退出 PC 青卷后，共享连接失效；重新生成二维码会更换密钥，手机需重新扫码。

PC 已连接远程后端时，二维码分享当前已保存的地址与连接 Token；手机仍需登录对应账号，相同账号可访问同一书库。隐藏二维码不会撤销远程 Token。二维码与链接含连接凭据，只应交给可信设备。

### 部署 Linux 后端

需要独立常驻后端时可部署 Linux 服务端；Windows 本机模式及其局域网共享可跳过。

```bash
sudo mkdir -p /opt/qingjuan
sudo git clone https://github.com/qingscroll/QingJuan.git /opt/qingjuan/app
cd /opt/qingjuan/app
sudo bash deploy/linux/install.sh
sudo qingjuan-info
```

安装完成后会显示服务地址、连接 Token 和一次性管理密码。公网部署请配置 HTTPS，并通过 `--url https://你的域名` 指定外部地址。

客户端连接远程后端时填写 FastAPI 地址和连接 Token，地址末尾不要添加 `/api/v1`。Windows 本机与远程后端的数据相互独立，切换连接不会迁移或同步数据。

常用运维命令：

```bash
sudo systemctl status qingjuan-backend --no-pager
sudo journalctl -u qingjuan-backend -f
sudo bash /opt/qingjuan/app/deploy/linux/update.sh
sudo qingjuan-password
sudo qingjuan-uninstall
```

如需同时永久删除书库数据，使用 `sudo qingjuan-uninstall --purge-data`；不要先执行普通卸载。

## 数据与安全

- Windows 本机数据位于解压目录的 `backend/data/`
- Linux 数据位于 `/var/lib/qingjuan`
- 启用 2FA 后，备份或迁移 Linux 服务时需同时保存 `/var/lib/qingjuan` 和 `/etc/qingjuan/backend.env`
- Windows 本机与 Linux 后端不会自动同步，更新或迁移前请备份当前数据
- Android 离线内容是按服务实例和账号隔离的设备副本；服务器仍是权威数据源，清理设备缓存保留待同步进度
- 不要公开连接 Token、管理密码、API 密钥、Cookie、数据库或下载内容
- 远程连接建议使用局域网、Tailscale 或 WireGuard；公网访问必须使用 HTTPS

## 开发与贡献

开发环境、项目架构、测试、构建、CI 和发布要求见[开发文档](./docs/development/README.md)。欢迎提交 [Issue](https://github.com/qingscroll/QingJuan/issues) 或 Pull Request，提交前请移除密钥、账号和个人数据。

## 交流

- GitHub：[qingscroll/QingJuan](https://github.com/qingscroll/QingJuan)
- QQ 群：`1074882763`
- 安全问题：通过 GitHub 的 **Security → Report a vulnerability** 私密报告

## 许可与致谢

本项目使用 [GNU GPL v3](./LICENSE) 许可证。

感谢[所有贡献者](https://github.com/qingscroll/QingJuan/graphs/contributors)、[Linux.do](https://linux.do) 社区，以及 Flutter、FastAPI、RapidOCR、`fluent_ui`、[fanqie-assistant](https://github.com/naiyQAQ/fanqie-assistant)、[hgmzhn/manga-translator-ui](https://github.com/hgmzhn/manga-translator-ui) 等开源项目。
