# 青卷开发指南（总览）

> 本目录是青卷项目的**唯一开发规范来源**。所有编码、重构、代码评审与发布都以这里的约定为准。
> 这一份是入口文档：先读它了解整体，再按需要进入对应章节。

---

## 这份文档是给谁看的

| 如果你…… | 建议从哪读起 |
| --- | --- |
| 刚接触项目，想搞懂“青卷到底是什么、怎么跑起来” | 先读本页，然后读[《原则与架构》](./01-principles-and-architecture.md) |
| 要改 Flutter 客户端（`lib/`、`test/`） | [《Flutter 客户端开发规范》](./03-frontend.md) + [《UI 与可访问性》](./02-ui-and-accessibility.md) |
| 要改 FastAPI 后端、管理界面或 Linux 部署（`python-backend/`、`admin-web/`、`deploy/linux/`） | [《后端、管理界面与集成》](./04-backend-and-android.md) |
| 要写测试或准备提交合并 | [《质量与测试》](./05-quality-and-testing.md)、[《工作流与迁移》](./06-workflow-and-migration.md) |
| 只想知道“提交代码前必须满足什么” | [最低强制要求](#8-最低强制要求每条都很重要) 与 [质量与测试](./05-quality-and-testing.md) |

---

## 1. 项目到底是什么

青卷（QingJuan）是一个 **小说 / 漫画 的导入、下载、翻译、阅读客户端**，同时也负责管理这些内容背后的服务。

它由三个部分组成，共享同一套业务能力：

```
┌─────────────────────┐   ┌──────────────────────┐
│  Flutter 客户端      │   │  管理界面（可选）       │
│  Windows + Android  │   │  React + Ant Design   │
└──────────┬──────────┘   └──────────┬───────────┘
           │  HTTP / HTTPS           │ 同源 Cookie 会话
           ▼                         ▼
┌─────────────────────────────────────────────────┐
│            FastAPI 后端（业务核心）                │
│   抓取 / 下载 / 翻译 / OCR / 任务 / 书库 / 账号    │
└─────────────────────────────────────────────────┘
```

- **Flutter 客户端**：Windows 桌面端与 Android 手机 / 平板端。两者共用业务逻辑和 Controller，但分别维护两套界面（Windows 走 Fluent 桌面风格，Android 走触控优先的移动风格）。
- **FastAPI 后端**：有两种运行形态——
  - *Windows 本机伴随后端*：打包在 Windows 安装包内，只监听回环地址 `http://127.0.0.1:19453`，面向单机用户；
  - *Linux 远程服务*：systemd 单进程多用户服务，供 Android（必须）和 Windows（可选）远程连接。
- **管理界面**：随 Linux 后端一起提供的 React 管理页（`/admin/`），用于配置服务器、维护用户、查看设备 / 诊断 / 日志等运维操作。它不是阅读客户端。

> 一句话总结：**“当前选中的后端”是书籍、任务、阅读进度、模型设置的唯一权威来源**；客户端只负责展示与操作，不自己存书库。

## 2. 各文档都讲什么（导航）

| 文档 | 内容 | 主要涉及目录 |
| --- | --- | --- |
| [原则与架构](./01-principles-and-architecture.md) | 依赖方向、模块边界、目录职责、文件拆分阈值、命名规范 | 全仓库 |
| [UI 与可访问性](./02-ui-and-accessibility.md) | Fluent 视觉基线、Android 触控、响应式布局、阅读器沉浸、语义与可访问性 | `lib/features/`、`lib/shared/` |
| [Flutter 客户端](./03-frontend.md) | Widget / Controller / API / 状态管理 / 导航 / 持久化 / 阅读器具体实现 | `lib/`、`test/` |
| [后端与管理界面](./04-backend-and-android.md) | FastAPI 分层、API 约定、认证与凭据、数据库、抓取与站点插件、后台任务、部署 | `python-backend/`、`admin-web/`、`windows/`、`android/`、`deploy/linux/` |
| [质量与测试](./05-quality-and-testing.md) | TDD 流程、测试分层、强制命令、三轮验证、完成定义 | 所有变更 |
| [站点插件规范](./07-site-plugin-spec.md) | 独立插件包、Python API v1、安装更新、信任边界与示例 | `app/plugin_system/`、`examples/plugins/` |
| [工作流与迁移](./06-workflow-and-migration.md) | Git 流程、PR 要求、CI 门禁、发布流程、迁移规则、禁止反模式 | 贡献与发布 |

---

## 3. 一个请求是怎么在系统里流动的

理解下面这条链路，就理解了 80% 的项目结构：

```
用户点击                 →  Widget（只负责布局与交互）
→ Feature Controller     →  表达“一个功能域”的用例、持有状态
→ ApiClient              →  负责 HTTP、鉴权头、JSON、错误归一化
→ FastAPI Router         →  校验输入、调用业务、映射响应
→ Service / Site Plugin  →  具体业务：抓取、下载、翻译、任务
→ Repository / db.py     →  SQLite、文件系统、第三方网站
```

基本铁律：

- **依赖只能向下**：Widget 不许直连 HTTP / 数据库 / 进程；Controller 不依赖页面实例。
- **客户端不侧写安全**：连接 Token 只存在于安全存储与请求头；模型密钥只存在后端 SQLite，客户端拿不到。
- **数据由后端管**：书库、任务、阅读进度、插件开关都在后端，客户端只存“界面偏好”和“安全存储里的连接信息”。

## 4. 平台边界一句话

| | Windows 客户端 | Android 客户端 | Linux 后端 |
| --- | --- | --- | --- |
| 连接方式 | 本机后端(127.0.0.1) **或** 远程 Linux | 仅远程 Linux | 本地多用户服务 |
| 界面风格 | Fluent 桌面（NavigationView） | 触控移动端（底部导航） | Ant Design 管理页 |
| 登录 | 本机隐式管理员 / 远程账号 | 远程账号 | 管理密码 + 用户账号 / Token |

> Windows 提供**两种显式连接模式**（本机 / 远程），切换模式意味着切换数据源，绝不会自动回退。Android 只有远程模式。

---

## 5. 快速上手：把项目跑起来

### 必需的开发环境

| 工具 | 版本基线 | 用途与要点 |
| --- | --- | --- |
| Windows 10 / 11 x64 | 客户端运行与 Windows 开发主机 | 构建、运行、调试 Windows / Android 客户端 |
| Linux / macOS | 受支持的开发主机 | Android 客户端开发（可选） |
| Flutter | `3.44.4` **stable** | 正式包禁止用 master / beta |
| Dart | `3.12.2` | 随 Flutter 3.44.4 提供，不单独安装 |
| JDK | 17 | Gradle 与 Android 构建 |
| Python | CPython `3.13.x` x64 | 后端开发与测试；别用 Store 重定向别名 |
| Node.js | `20.19.x` 或 `22.12+` | 仅构建 / 测试 `admin-web/` |
| Android SDK | `flutter doctor -v` 要求 | 构建 APK |
| Git | 当前支持版本 | 仓库管理 |

### 首次配置（在仓库根目录执行）

```powershell
flutter config --enable-android
flutter config --enable-windows-desktop
flutter doctor -v          # 确认 Flutter 3.44.4、Android toolchain 无错误
flutter pub get
flutter devices            # 能看到模拟器或开启了 USB 调试的真机
```

> `flutter doctor` 必须同时确认 Android toolchain 无错误；`Get-Command flutter` / `Get-Command python` 用于确认当前 PowerShell 会话实际解析到哪个工具（不要只看 IDE 状态栏）。

如果还要改后端或调试 Windows 本机模式，再创建 Python 虚拟环境：

```powershell
cd python-backend
python -m venv .venv
.\.venv\Scripts\activate
python -m pip install -r requirements-dev.txt   # 已含运行 + 测试 + 发布依赖
```

要改或跑管理界面时：

```powershell
cd admin-web
npm ci
npm run dev
```

### 调试启动

```powershell
# Android（真机 / 模拟器）
flutter run -d <设备ID>

# Windows 桌面
flutter run -d windows
```

> Windows 首次启动时若没有既有远程配置，默认进入**本机模式**并按需启动随包后端；Android 首次启动会展示服务器配置页。
> 手机端仍不需要 Python 环境——手机只连接远程 Linux 后端。

---

## 6. 当前发布基线（读代码前先看这个）

- 已发布版本：**v2.1.0（build 40）**；仓库当前发布候选：**`2.1.1+41`**（修复 Android 详情与阅读器路由的文字样式继承、加载反馈和移动端按钮层级）。
- Windows 发布包**必须包含** PyInstaller 构建的本机伴随后端；本机模式只监听回环地址，不用 Token。
- 既有功能要求：本地文件导入、单章 / 多章导出、设备 TTS、链接任务与实时日志、单一 OpenAI 兼容翻译配置，以及 RapidOCR 漫画翻译链路。
- 后续版本升级**不得破坏**：现有后端数据、导入导出格式、阅读进度与设置；必须保证兼容（特殊场景要提供迁移说明 + 测试）。

---

## 7. 平台边界与“不支持”清单

支持：

- Windows 桌面客户端（带可选本机后端）
- Android 手机 / 平板（远程客户端）
- Linux x86_64 systemd 服务（后端 + 管理界面）

**不支持**（也禁止引入）：Android 本地 Python 后端、iOS、面向读者的 Web / PWA `客户端`、Electron、Capacitor、Vue 客户端。

> 特别注意：`fluent_ui` 是 Flutter 社区维护的 Fluent 组件库，不是 `microsoft/fluentui` 仓库里那套 React/Web 包。项目在 Flutter 技术栈中用它实现控件，并以 Microsoft Fluent 的布局、状态、动效、可访问性原则作为设计依据。

---

## 8. 最低强制要求（每条都很重要）

这些是所有代码的地基，改动任何部分都不得破坏它们：

1. **组件体系隔离**：Flutter 用 `fluent_ui`，管理界面用 Ant Design；两套体系绝不混用（Material 页面组件等于禁止）。
2. **分层清晰**：新功能按 Feature 拆；页面不直接处理 HTTP / 数据库 / 进程。
3. **数据模型分离**：网络 DTO、领域模型、状态控制、展示组件各自独立。
4. **异步界面五种状态**：任何异步界面都有 加载 / 空 / 成功 / 失败 / 重试 状态。
5. **用户可见错误用中文**：可执行的提示，不暴露堆栈、密钥。
6. **改动配套完整检查**：提交前跑完 格式化 → 静态分析 → 测试 → Windows / Android 构建。
7. **文档归位**：根目录只放 `README.md`；其他 Markdown 必须在 `docs/development/` 对应章节。
8. **不提交脏产物**：密钥、数据库、缓存、下载内容、日志、临时构建产物、个人数据一律不进 Git；`python-backend/app/admin_static/` 是唯一例外的构建产物。
9. **回环与安全**：无认证服务只能监听回环地址；客户端不向非青卷同源地址发送连接 Token。

## 规范优先级（冲突时按这个顺序取舍）

1. 安全、隐私、许可与用户明确要求；
2. 本开发规范；
3. Flutter / Dart / FastAPI 官方约定；
4. 现有代码模式。

原则：**不复制现有代码的坏习惯**。局部修改应该在可控范围内向规范靠拢，并用测试保护行为。

## 维护这份文档

- 架构、依赖、构建或 UI 基线变化时，**必须在同一个 PR** 更新对应文档。
- 不为一次性讨论新造一个 Markdown；把结论合并进现有章节。
- 同一条规则只保留一份权威位置，其余地方用链接引用。
- 客户端开发命令必须能在 **Windows PowerShell** 下执行；Linux 部署命令使用明确标注 **Bash** 的代码块。

## 下一步

- 想理清全部技术栈和目录职责 → [原则与架构](./01-principles-and-architecture.md)
- 想跑通开发环境与调试 → [快速上手：把项目跑起来](#5-快速上手把项目跑起来)（见上文 §5）
- 准备写代码 / 改页面 → [UI 与可访问性](./02-ui-and-accessibility.md) 与 [Flutter 客户端](./03-frontend.md)
- 准备发版本 → [工作流与迁移](./06-workflow-and-migration.md)
