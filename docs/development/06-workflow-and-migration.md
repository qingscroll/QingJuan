# 工作流、发布与迁移

> 这份文档回答“从写代码到发版本”的完整流程：分支与提交、PR 要求、CI 门禁、版本与发布规则、技术栈迁移、以及绝对禁止的反模式。
>
 > 适合：所有贡献者与发布负责人。**第 5 节（发布）是负责人必读；第 6、7 节是所有 PR 必读。**

---

## 1. 分支与提交

- 一个分支 / 一个 PR 只聚焦一个可描述的目标。
- 推荐提交前缀：`feat:`、`fix:`、`refactor:`、`test:`、`docs:`、`build:`、`chore:`。
- 不混入无关格式化、个人设置、下载资源或生成文件。
- 大重构分成可验证的阶段，每阶段保持可构建。
- **用户已有的未提交改动，不得擅自覆盖、重置或清理。**

## 2. 功能开发：从零到合并的路径

开工前（想清楚再写）：

1. 读相关开发规范与既有测试；
2. 明确 用户路径、数据来源、错误边界、权限边界；
3. 确定 Model / Controller / API / Widget 的职责；
4. 为行为先写失败测试。

实现顺序：

1. 领域模型与 API 契约；
2. Controller 用例与状态；
3. 最小 Fluent UI；
4. 补齐 错误、空状态、触控、系统返回、手机 / 平板适配；
5. 重构重复代码；
6. 三轮验证（见[质量与测试](./05-quality-and-testing.md)）；
7. 同步 README 或对应开发规范。

## 3. Pull Request 要求

PR 描述必须包含：

- 要解决的问题 + **不在范围内**的内容；
- 用户可见变化；
- 架构与依赖变化；
- 安全、数据迁移、兼容性影响；
- 测试命令与人工验证；
- UI 变化的亮 / 暗主题截图（如适用）。

评审顺序（从重到轻）：

1. 安全、数据丢失、路径边界；
2. 行为正确与错误恢复；
3. 依赖方向与模块职责；
4. 测试质量；
5. Fluent UI、一致性、可访问性；
6. 性能、命名、细节。

## 4. CI 与依赖：四道门禁并行

PR、`main` / `master` 推送（含合并推送）、手动触发，都先并行跑 4 道门禁，**全部成功后才构建产物**：

1. **Flutter 质量**：格式化、分析、测试；
2. **Python 后端**：Ruff + Pytest；
3. **Bash / systemd 校验** + Linux 原生后端 健康 / 认证 / 数据目录 冒烟；
4. **React 管理界面**：TypeScript、测试、生产构建，并校验 `python-backend/app/admin_static/` 已提交静态资源与构建结果**一致**。

4 道全绿 → CI 才并行构建 Android Release APK 与含随包后端的 Windows x64 组合包，并上传到本次 Actions 运行。Android 固定 JDK 17，两端统一 Flutter 3.24.3；构建**不依赖**开发机全局 Gradle、签名文件、缓存私配。

Dependabot 只维护当前技术栈：`pub`（Flutter/Dart）、`pip`（FastAPI）、`npm`（React）、`github-actions`（CI）。升级前读变更说明，尤其注意 Dart SDK / AGP / 平台插件 / FastAPI / Pydantic；不要在一个 PR 里无差别升所有大版本。

## 5. Windows 与 Android 发布

### 版本规则（唯一版本源是 `pubspec.yaml`）

- 格式 `major.minor.patch+build`；对外标签 `v<major.minor.patch>`。
- 默认：每次准备发布都自动递进 `patch` 和 `build`（如 `1.0.0+5` → `1.0.1+6`）。
- 用户 / 发布负责人指定版本时以其语义版本为准，但 `build` 必须大于上一版；major / minor / 预发布 / 跳号不得自行推断。
- 日常调试 / 重复构建**不得改版本号**；只有准备形成新发布才递增。
- 修改版本后验证：Android `versionName` / `versionCode`、FastAPI 元数据、Windows 文件属性都来自同一版本源；禁止在 Dart / Python / Kotlin / C++ / 发布脚本里出现独立硬编码版本。
- 当前基线：已发布 `2.0.1+33`；后续 build 必须 > `33`，不得回退 / 复用。`2.0.2+34` 为本次发布候选，面向移动端阅读体验优化（性能与书页稳定性），对外标签 `v2.0.2`。

### 发布前清单

1. 按规则更新 `pubspec.yaml` 版本；
2. 跑全部质量门禁；
3. 装 `requirements-dev.txt`，执行 `./tool/build_windows.ps1` 与 `flutter build apk --release`（商店分发再加 `flutter build appbundle --release`）；
4. 在无 Python 的 Windows 10/11 与 API 26 Android 设备安装验证；
5. Android 验证首次远程；Windows 验证本机后端启动 + Linux 远程连接，覆盖导入、任务、阅读、设置、切换、退出；
6. 扫描产物与构建配置：Windows 只允许预期的随包后端，两端都不含 数据库 / 缓存 / 日志 / Token / 签名材料 / 密钥；
7. 记录已知站点兼容性与实验功能。

### 打标签发版

合并并确认 `main` 的 CI 全绿后：

```powershell
git tag v2.0.2
git push origin v2.0.2
```

`release.yml` 会重跑 Flutter 检查 + Ruff + Pytest，再并行构建 Windows ZIP 与签名 Android APK；**只有标签、`pubspec.yaml`、两个客户端版本、后端元数据版本全部一致**才上传产物与 SHA-256 并创建 Release。禁止手工跳过失败门禁、用未提交本地工作区制作正式包。

产物命名：`QingJuan-v<语义版本>-windows-x64.zip` 与 `QingJuan-v<语义版本>-android.apk`。发布前验证 `versionName` / `versionCode` / 包名 / 签名证书；最低版本与当前版本双平台安装 + 连真实 Linux；Windows 包只含且必须含预期随包后端；两端无生产数据；扫描 `.env` / 数据库 / 日志 / Token / 签名 / 凭据，记录 SHA-256。

## 6. 技术栈迁移规则（什么不能碰）

面向读者的**唯一**客户端技术栈是 Flutter Windows / Android；React + Ant Design 仅限同源 Linux 管理界面。以下视为违禁并禁止回流：

- Vue、Pinia、面向读者的 Web 客户端；
- Electron 主进程 / preload / electron-builder；
- Capacitor、iOS、PWA、Service Worker；
- Flutter 里用 Web 专用 Fluent UI 包，或管理界面混入 Flutter / Material 组件；
- 独立于共享 FastAPI 的 Windows 专用业务分支（Windows 伴随后端必须由同一 `python-backend` 可复现构建）。

删除旧栈要**成套清理**：源码、依赖清单 + lockfile、构建与测试配置、CI / Dependabot / 脚本、文档示例与生成目录、未用分支与资源。

任何“恢复 iOS 或面向读者 Web 客户端”的提案 = 新产品决策，不能把管理界面扩展成第二套阅读客户端。

### 6.1 Windows 双模式兼容规则

- Android 忽略旧 `local` 偏好，必须让用户显式填 Linux 地址与 Token；APK 不内置后端。
- Windows 保留旧 `qingjuan.backendMode`；V1.4 无模式字段但已有远程地址 → 迁移为远程；完全没有服务器配置 → 默认本机。迁移**不得覆盖**已存远程地址或安全存储 Token。
- 本机固定回环 + 无 Token；远程保存前完成认证 + 版本握手，失败保留输入与诊断，成功才切数据源；远程失败**不回退本机**。
- 模式保存 `qingjuan.backendMode`，Linux 地址独立 `qingjuan.backend.remote.url`，Token 只存安全存储；首次读时只把旧 `backendUrl` 迁移为 Linux 地址，**不把旧回环当 Linux**；切本机保留 Linux 档案，切回无需重输。
- 数据：Windows 本机 `backend/data/`，Linux 数据目录不自动同步。迁移先 COPY 到隔离目录并校验清单，两个进程**不得同时开同一个 SQLite**。
- 旧 API 的绝对 `localPath` 仅限内部迁移，不断进公开 DTO；`targetPath` 导出迁移为服务端产物，漫画 ZIP 导出内容与顺序兼容。
- 迁移到 Linux 时绝对路径转相对存储键，不直接复用 Windows 路径。
- 已有密钥保留在后端，升级后只读接口返回配置状态；客户端空值不得误清已有密钥。
- 回滚必须保留升级前的完整备份；新版本写入后不让旧版本直接打开同一生产目录。

## 7. **禁止的反模式**（红牌，出现即退）

- 所有功能写进 `main.dart`、单个页面或 `main.py`；
- Widget 直接操作 HTTP / SQLite / 进程；
- 为复用一行样式创建无语义抽象；
- 引入第二套 UI 框架；
- 隐藏异常、空 `catch`、无限重试；
- 硬编码密钥、用户路径、远程地址、在业务里散落魔术端口；
- 默认让无认证后端监听局域网；
- 把连接 Token 写进 偏好 / 命令行 / URL / 日志 / 第三方请求；
- 把 Android URI / 目标路径发给 Linux 后端，或把服务端绝对路径当 API 结果；
- 用多个 Uvicorn worker 或多个 systemd 共享 SQLite；
- 删除目录前不校验绝对目标；
- 用真实公网请求当稳定单元测试；
- 在根目录增加无用 Markdown；
- 提交 `build/`、`release/`、数据库、缓存或个人内容。

## 8. 技术债管理

- 只在改动触及的范围偿还；不借机重写无关模块。
- 超过建议体积的旧文件：新功能优先提取明确领域，而不是继续堆。
- 临时方案必须有 可搜索说明 / 风险 / 退出条件 / 跟踪 Issue。
- 不能立即修复的，在交付报告里明说，不装作已经完成。
