# 原则与架构

## 1. 工程目标

青卷将抓取、下载、翻译和阅读能力组合为 Windows / Android Flutter 客户端、随服务提供的 React 管理界面，
以及可作为 Windows 回环伴随进程或 Linux 多用户服务运行的 FastAPI 后端。工程设计优先级为：

1. 数据与凭据安全；
2. 功能正确、故障可恢复；
3. 代码边界清楚、可测试；
4. Windows 键鼠与 Android 触控体验一致；
5. 性能与可扩展性。

避免为了“以后可能用到”提前抽象。只有出现稳定边界、重复实现或明确测试需求时才提取接口。

## 2. 总体架构

```text
Flutter View / Widget
        ↓ 用户意图与展示状态
Feature Controller
        ↓ 领域模型
ApiClient / BackendConnectionManager
        ↓ loopback HTTP / HTTPS / private-network HTTP
FastAPI Router / Auth
        ↓
Service / Site Plugin / Repository
        ↓
SQLite / Files / Third-party sites

React Admin / Ant Design
        ↓ 同源 Cookie 会话 + CSRF
FastAPI Router / Auth

```

依赖只能向下：

- Widget 不调用 `http`、`Process`、SQLite 或文件抓取。
- Controller 不依赖具体页面实例，不持有 `BuildContext`。
- `core/models` 不依赖 Feature 和 UI。
- API 层负责序列化、状态码与错误归一化，不包含页面跳转。
- Windows 客户端只有在用户明确选择本机模式时才可由基础设施层启动随包后端；Android 始终只有远程连接。
  远程未配置、认证失败或版本不兼容时不得自动启动或回退到本机后端。
- 连接 Token 只由 API 基础设施层读取，不进入领域模型、页面日志或第三方请求。
- 管理界面默认不加载连接 Token；仅在管理员登录后主动点击“显示”时，通过同源 CSRF 保护接口按需读取，
  结果只保存在当前页面内存并自动隐藏，不写入浏览器存储、普通业务响应、错误或日志。登录密码只提交给
  同源登录接口，业务请求使用 HttpOnly 会话 Cookie。
- Linux 远程服务继续使用连接 Token 的 SHA-256 摘要完成 Bearer 校验；原始值只保存在受限的服务器连接文件中，
  供 `qingjuan-info` 和管理界面的按需显示使用。模型供应商 API 密钥不属于该连接凭据展示能力。
- Linux 用户会话与连接 Token 分层：连接 Token 只控制实例入口，用户会话 Token 标识书架主体。用户会话保存在平台安全存储，
  服务端只保存摘要；任何书籍、阅读进度、任务和异步导入查询都必须由服务端当前主体限定，客户端不得提交任意 `userId`。
- 翻译模型配置只以当前后端 SQLite 中的记录为准。Windows 本机模式可在客户端设置页编辑并提交到回环后端；Linux
  远程模式仍由管理界面维护。Android 与 Windows 远程客户端只创建翻译任务并读取自检状态，不得直连或回退客户端模型。
- Windows / Android 客户端为每次应用安装生成稳定随机设备 ID，并随同源业务请求上报有限的设备名称与平台信息。
  后端只用它维护设备在线状态和封禁规则；设备 ID 不是新的用户身份、不能替代 Bearer Token，也不得用于跨服务追踪。
- FastAPI Router 校验输入、调用业务函数并映射响应，不编写大段抓取或 SQL。
- 数据层不导入 FastAPI、Flutter 或 HTTP 请求对象。

当前选中的后端是书籍、任务、阅读进度、模型设置和文件的唯一权威来源。本机后端与 Linux 后端的数据互不自动同步。
Android 可保存按后端实例与账号隔离的离线章节副本；设备只提交带版本和操作标识的阅读位置，冲突必须由用户选择。客户端还可保存同样隔离的听书位置。退出账号或切换实例须撤下原身份内容，临时断网可继续读取已保存副本，不能回退到其他账号或实例。
客户端文件选择器产生的 URI 或临时路径只属于对应客户端设备：导入时上传文件，导出时下载服务端产物，任何 API 都不得要求后端写入
客户端路径。设备 TTS 始终在客户端运行；OCR、抓取与翻译能力属于后端，并通过能力握手暴露。

## 3. 目录职责

```text
lib/
├─ app/                 # 组合根、主题、AppScope、全局偏好
├─ core/
│  ├─ api/              # HTTP 客户端与统一异常
│  ├─ backend/          # 后端连接状态、Windows 本机进程与安全凭据
│  ├─ models/           # 跨功能领域模型
│  └─ state/            # 通用加载状态
├─ features/<feature>/  # 页面、控制器与本功能 Widget
└─ shared/              # 至少两个 Feature 使用的轻量共享能力

python-backend/
├─ app/api/             # 路由声明
├─ app/application.py   # FastAPI 组装
├─ app/chapter_cache.py # Linux 顺序缓存、阅读抢占/相邻章预取与应用级任务生命周期
├─ app/models.py        # 请求、响应与领域数据模型
├─ app/db.py            # SQLite 与持久化
├─ app/site_plugins/    # 每个内置站点一个模块，声明匹配、能力与运行处理器
├─ app/plugin_system/   # 外部插件清单、包持久化、安装生命周期和公共运行 SDK
├─ app/scraper.py       # 共享抓取、下载、OCR 与翻译基础设施
└─ tests/               # 后端测试

admin-web/              # React + TypeScript + Ant Design 管理界面源码与前端测试
python-backend/app/admin_static/
                        # 可复现构建并随后端提供的管理界面静态资源
deploy/linux/           # Linux 原生安装、systemd 服务、更新与连接信息脚本

android/                # Android Manifest、Gradle 与原生资源
windows/                # Windows Runner、插件注册与原生资源
assets/                 # 品牌图片、文档截图与应用图标
```

文件放置原则：

- 只服务一个功能的组件放进该 Feature，不提前放入 `shared`。
- `shared` 不导入具体 Feature。
- 应用启动只负责依赖组装，不实现业务。
- 内置站点解析器必须通过 `app/site_plugins/` 注册；一个模块只描述一个站点或一个明确的通用回退协议，
  不允许重新在 `scraper.py` 中追加散落的域名分支。站点模块可复用共享 HTTP、清洗、下载和持久化能力。
- 需要站点账号的解析器仍随单个后端进程运行：第三方项目只能作为接入契约和实现来源，发布产物不得依赖开发机上的
  兄弟目录或额外常驻服务。扫码流程、站点 Cookie 和账号会话由对应插件运行时在内存中保管，普通插件清单、错误与日志
  只暴露是否登录等非敏感状态。
- Android / Windows Runner 只承载 Flutter、权限与平台资源，不放业务逻辑；Windows 本机进程生命周期位于 Dart 基础设施层。
- `admin-web/` 只负责展示与用户操作；认证、授权、数据校验和敏感配置始终由 FastAPI 执行。
- 服务器运行日志由后端写入受限轮转文件；管理界面只读取已脱敏的结构化尾部日志，不直接授予浏览器
  journal、文件系统或进程执行权限。
- 系统诊断是管理端只读能力：请求计数与耗时窗口只保存在当前进程内存，服务状态、任务统计和磁盘容量
  由后端按需聚合。诊断响应与下载报告不得包含凭据、正文、绝对路径、环境变量值或任意文件内容，也不得
  通过诊断入口执行 shell、重启服务或修改数据。

## 4. 单一职责与拆分

出现任一情况就应拆分：

- 同一文件同时包含 UI、网络、持久化或进程管理中的两个以上职责；
- 一个 Widget 有多个独立可测试区域；
- 同一段解析、状态转换或错误处理出现两次；
- 修改一个功能需要理解大量无关代码；
- 测试必须依赖整个应用才能验证一个小行为。

建议阈值不是机械上限，但超出时必须在评审中说明：

| 文件类型 | 建议上限 | 首选拆分方向 |
| --- | ---: | --- |
| Flutter 页面 | 300 行 | 局部 Widget、Controller、对话框 |
| 通用 Widget | 220 行 | 子控件、样式模型 |
| Controller / Service | 260 行 | 按用例或资源拆分 |
| Dart Model | 220 行 | 按领域拆分 |
| Python Router | 300 行 | 按资源拆分 |
| Python Service / Adapter | 400 行 | 按站点、用例或协议拆分 |
| 测试文件 | 400 行 | 按行为组拆分 |

函数通常不超过 50 行，嵌套不超过 3 层。优先使用早返回、语义化私有函数和不可变值。

## 5. 命名与配置

- Dart 文件、Python 模块：`snake_case`。
- Dart 类型、Widget、Python 类：`PascalCase`。
- 变量、函数、字段：Dart 使用 `lowerCamelCase`，Python 使用 `snake_case`。
- 布尔值以 `is`、`has`、`can`、`should` 开头。
- 禁止含糊的 `data`、`item`、`manager`；必须表达业务含义。
- 端口、超时、并发数、路径和服务地址集中为常量或配置，禁止散落魔术值。

## 6. 文档与仓库卫生

- 根目录只允许 `README.md`；许可证文件不属于 Markdown，可保留。
- 开发规范只写入本目录已有主题，避免新增重复文档。
- 临时分析、调试记录和生成报告不得提交。
- `build/`、`release/`、缓存、数据库与 IDE 状态必须被忽略。
- 删除技术栈时同时删除依赖、配置、脚本、CI、文档和测试遗留。

## 7. 架构变更

以下变更应在实现前形成明确决策，并在 PR 中说明替代方案：

- 新增顶层目录或第三方框架；
- 改变 Flutter 与后端通信协议；
- 改变数据目录、Schema 或迁移策略；
- 改变远程后端连接、认证与服务器切换方式；
- 引入认证、远程监听或外部服务；
- 改变单用户数据归属、远程文件传输或 Linux 部署方式；
- 大规模移动文件或破坏兼容性。
