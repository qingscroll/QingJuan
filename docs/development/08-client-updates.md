# 客户端在线更新与 Windows 安装包

## 更新流程

`AppUpdateController` 在根应用初始化时启动一次检查，与后端就绪、账户登录独立；设置页可手动重试。版本从原生应用包读取，发布元数据来自固定的 `qingscroll/QingJuan` GitHub Releases latest API。只接受正式 `v主.次.补丁` 标签，按数字比较，不降级，不把 build number 当作正式版更新。

官方仓库地址统一定义在 `lib/core/app_metadata.dart`，更新接口、发布页面、下载来源校验和关于页共同使用。仓库从 `Tavre/QingJuan` 迁移后，GitHub 旧接口会重定向并返回新仓库的链接；客户端直接请求新接口，只信任当前官方仓库。发布信息或地址校验失败会单独提示，不再误报为网络故障。

Windows 目标文件固定为 `QingJuan-v<版本>-windows-x64-setup.exe` 及同名 `.sha256`，两者必须同属该 Release。缺少安装包或校验文件时展示发布页面入口。请求不携带后端 Token；下载有超时、大小上限与流式进度，失败/取消清理临时文件。下载后及启动安装前分别进行 SHA-256 校验。此校验用于验证文件完整性，不等于 Windows 代码签名。

用户点击“退出并安装”并确认后，启动安装器并传入原目录和当前 PID，回收当前客户端拥有的本机后端后退出。安装器最多等待 30 秒，客户端未退出则失败；原生 `QingJuan.Application` mutex 同时防止安装/卸载时覆盖运行中文件。更新保留原目录 `backend/data/`，安装文件清单不含用户数据，卸载不会递归删除应用目录。

Android 复用版本检查，在“我的 → 软件更新”中打开官方 APK 下载地址，由浏览器下载、系统安装。Android 不自动静默安装。

## 构建和发布

使用与 CI 一致的 Flutter 3.44.4、Python 3.13 和现有后端构建依赖：

```powershell
./tool/build_windows.ps1
./tool/smoke_test_windows_release.ps1
./tool/package_windows.ps1 -Tag v2.3.0
./tool/test_windows_installer.ps1
```

`package_windows.ps1` 校验标签、pubspec、PE 版本及敏感文件后生成 ZIP 与安装 EXE，各附带 SHA-256。Inno Setup 6.7.3 首次通过官方地址下载并检查 Authenticode 发布者签名，再按当前用户安装到 `.dart_tool/inno-setup/6.7.3`；也可用 `-IsccPath` 指定已安装的编译器。

产物位于 `release/`。默认安装位置为 `%LOCALAPPDATA%\Programs\QingJuan`，无管理员提权；支持选择安装目录、快捷方式及从系统设置卸载。CMake 将 Visual C++ 运行库放在程序旁边，打包时验证这些 DLL 必须存在。测试脚本使用独立 AppId、独立目录和禁用快捷方式的微型测试包，验证首次安装、等待进程退出、覆盖升级、卸载与数据保留。

## 安装包体积

Windows 后端使用 `deploy/windows/backend.spec` 生成目录式包，入口仍为 `backend/qingjuan-desktop.exe`，依赖放在 `backend/_internal/`，用户数据仍为 `backend/data/`。Inno 使用 `lzma2/ultra64` 对依赖统一压缩，避免把已压缩的单文件后端再次压缩。此布局也省去每次启动时将整个后端解压到临时目录的步骤。

打包排除未使用的 OpenCV FFmpeg 视频插件、Tk/Qt 图形界面依赖、Crypto 自测和重复 Python 源码；保留图片编解码器、PDF、加密算法、离线 OCR 模型、运行库及许可证。发布冒烟通过隔离插件在冻结后端中实际验证图片格式、PDF、AES、OpenCV、OCR 和 HTTPS CA 文件。

目录式包会暴露 HTTPS 公共证书文件，因此打包扫描只允许 `backend/_internal/certifi/cacert.pem` 和 `backend/_internal/curl_cffi/cacert.pem`，并拒绝其中的私钥材料；其他 PEM、密钥和用户数据仍被阻止。安装器必须保留这些已验证的公共 CA，不能重新按 `*.pem` 全部排除。

本机 `2.2.0+42` 构建对比（十进制 MB，实际大小随依赖版本变化）：安装 EXE 约 156.27 → 105.75 MB，减少 32.33%；ZIP 约 159.01 → 144.18 MB。安装目录约 180.67 → 302.24 MB，但后端运行时不再额外解压原先约 309 MB 的临时依赖。

发布前增加 `pubspec.yaml` 的版本和 build number，并创建同版本标签。Release 流水线发布六个文件：Windows ZIP、安装 EXE、Android APK 和三个校验文件。首次发布这项功能后，已含更新功能的客户端才能在后续发布中完成在线升级；旧版本仍需手动安装一次。

官方参考：[GitHub Releases API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)、[Inno Setup AppMutex](https://jrsoftware.org/ishelp/topic_setup_appmutex.htm)、[当前用户安装](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm)。

打包参考：[PyInstaller 目录式与单文件模式](https://pyinstaller.org/en/stable/operating-mode.html)、[Inno 压缩选项](https://jrsoftware.org/ishelp/topic_setup_compression.htm)。
