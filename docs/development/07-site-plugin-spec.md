# 站点插件规范 v1

青卷支持把独立 Python 解析器作为 `.qjplugin` 或 `.zip` 文件导入当前后端。开发者无需修改青卷注册表、抓取代码或重新发布客户端。
本规范是外部插件的开发、打包、运行与维护契约；内置站点仍使用 `app/site_plugins/`，Legado JSON 规则仍由书源管理维护。

## 1. 安装与使用

1. Windows 本机模式：打开 **插件配置 → 导入插件**；Linux：使用管理员登录 **`/admin/#plugins` → 导入插件**。
2. 选择插件包，核对名称、ID、作者声明、版本及站点。确认信任来源后安装。读取这些信息时后端只校验清单和 Python 语法，不执行插件代码。
3. 安装成功后立即参与链接匹配；支持搜索的插件可在 Windows / Android 搜索页的 **导入插件** 中使用。远程客户端也能使用已安装插件，但安装和卸载由服务器管理网页负责。
4. 更新时导入同 ID、更高版本的包，界面展示版本变化。成功更新会保存上一版本，可在 **插件维护** 中运行自检并显式回退。
5. 自检检查包与接口兼容性，不访问站点；解析效果仍须通过实际导入或固定上游 Fixture 验证。卸载入口位于插件详情或管理表格，内置模块只能停用。

可立即使用的离线示例位于 `examples/plugins/demo-novel/`。在仓库根目录执行：

```powershell
python tool/package_site_plugin.py examples/plugins/demo-novel
```

导入生成的 `dist/plugins/demo-novel-1.0.0.qjplugin`，搜索“青卷”，或添加
`https://demo.qingjuan.test/book/1`（选择长小说、中文），即可阅读两章示例。该示例由插件直接返回固定数据，不进行 DNS 查询或公网请求。

## 2. 信任与运行边界

**Python 插件在后端进程内运行，不是沙箱。** 插件拥有后端进程的文件、网络及环境访问权限；仅应安装来自可信来源且经过审查的代码。
作者字段属于自我声明，不是签名认证。SHA-256 用于确认安装记录完整性，不证明作者身份。

- 安装、检查安装包、更新、维护自检（包括 GET）、回退和卸载要求管理员网页会话及 CSRF，或受信任 Windows 本机回环请求及 `X-QingJuan-Local-Request: 1`。
  普通连接 Token、远程客户端用户会话，即使用户角色为管理员，也不能上传执行代码。
- 清单/启停沿用原有用户授权。插件代码不接收青卷用户 Token、管理员 Cookie、站点账号会话、模型密钥或数据库对象。
- 插件应只使用 `context` 发起网络请求。其请求及重定向限制在 `domains + networkDomains`，并复用青卷公网 IP 校验和 DNS 固定机制；
  禁止本机、内网和云元数据地址，不继承代理环境。每次调用新建 HTTP 客户端，不共享用户凭据。
- `context` 的限制只约束 SDK 调用，无法限制任意 Python 代码。禁止插件绕过 SDK 发请求、执行系统命令、修改青卷数据、启动线程或进程、写入全局环境、采集凭据。
- 正常协作式异步调用限时 30 秒，上游单请求超时 15 秒。阻塞代码、死循环、进程退出及顶层导入副作用无法通过该超时隔离；维护者必须审查代码。
- v1 不提供 pip 自动安装、依赖解析、相对模块导入、多文件资源、持久化插件配置、账号登录扩展、市场或自动升级。
  运行环境是服务端当前 Python；Windows 冻结包仅保证已随青卷打包的模块可用，不能假设任意第三方包或整个标准库都已收录。
  为兼容 Windows 包，优先使用无需额外 import 的 `context` API。插件不得依赖开发机绝对路径。

## 3. 包结构和清单

ZIP 根目录必须且只能有以下两个普通 UTF-8 文件，不能压缩外层目录：

```text
my-site-1.0.0.qjplugin
├── manifest.json
└── plugin.py
```

包最大 2 MiB，解压后清单最大 32 KiB、代码最大 1 MiB；ZIP 仅支持 Store / Deflate，不允许重复文件名、符号链接、加密、路径穿越或额外文件。
后端从内存读取，不解压到服务器目录；持久化的是完整安装包。

```json
{
  "schemaVersion": 1,
  "apiVersion": 1,
  "id": "my-novel-site",
  "name": "我的小说站",
  "version": "1.0.0",
  "author": "作者名称",
  "description": "解析作品目录、正文和搜索结果。",
  "category": "novel",
  "domains": ["novels.example.test"],
  "networkDomains": ["cdn.example.test"],
  "bookKinds": ["长小说"],
  "language": "中文",
  "tags": ["中文", "小说"],
  "capabilities": ["preview", "chapter", "search", "on_demand"],
  "entrypoint": "plugin.py",
  "defaultEnabled": true
}
```

| 字段 | 必填 | 约束 |
| --- | --- | --- |
| `schemaVersion`、`apiVersion` | 是 | 整数 `1`，拒绝其他协议版本和布尔值 |
| `id` | 是 | 3–64 字符，小写字母开头，由小写字母、数字及单个连字符分段组成；发布后保持不变 |
| `name`、`author` | 是 | 非空，分别最多 80、100 字符 |
| `description` | 是 | 非空，最多 1000 字符 |
| `version` | 是 | `MAJOR.MINOR.PATCH` 非负整数，无前导零；v1 不接受前缀、预发布或构建后缀 |
| `category` | 是 | `novel` 或 `manga`，不允许外部通用回退插件 |
| `domains` | 是 | 1–20 个不同的纯 DNS 主机名；ASCII / Punycode，不含协议、IP、路径、端口、通配符 |
| `networkDomains` | 否 | 最多 40 个额外 API/CDN 域名；默认空，不参与作品匹配 |
| `bookKinds` | 是 | 小说为不重复的 `长小说` / `轻小说`，漫画必须为 `["漫画"]`；第一个是默认类型 |
| `language` | 否 | `中文` / `日文` / `英文`，默认中文，用于搜索结果 |
| `tags` | 否 | 最多 12 项，每项 1–40 字符，默认空 |
| `capabilities` | 是 | 不重复的 `preview`、`chapter`、`search`、`on_demand`；必须含 `preview`，`on_demand` 依赖 `chapter` |
| `entrypoint` | 是 | 固定 `plugin.py` |
| `defaultEnabled` | 否 | 严格布尔值，默认 `true`，只在首次安装初始化开关 |

未知字段、重复 JSON 键、能力和处理器不一致均拒绝安装。域名匹配包含其子域名，拒绝与任何内置或已安装插件的域名重叠，避免静默接管站点。
实际匹配顺序是内置专用插件、按 ID 排序的安装插件、通用网页回退。停用插件仍保留匹配权，发请求前报停用错误，不回退绕过开关。

[JSON Schema](./plugin-manifest-v1.schema.json) 可用于编辑器补全和字段校验，由后端 `PluginManifest.model_json_schema()` 生成；
域名交叉冲突、字段间依赖、函数签名及运行时内容仍由宿主验证。升级插件时应保留已有作品所依赖的域名别名。

## 4. Python 入口协议

清单声明的每项处理能力都必须提供下列签名的异步函数。`on_demand` 是宿主调度能力，不需要同名函数。
模块顶层只允许定义常量、函数和无副作用的类型；禁止顶层请求网络或执行耗时任务。

```python
async def preview(url, context):
    return {
        "title": "作品名",
        "author": "作者",             # 可省略或为 None
        "synopsis": "作品简介",       # 可省略
        "cover": "/cover.jpg",        # 可省略或为 None
        "chapters": [
            {"title": "第一章", "url": "/chapter/1", "pageCount": 0, "accessRestricted": False}
        ],
    }

async def chapter(url, context):
    return {"text": "第一段正文。\n\n第二段正文。"}

async def search(keyword, limit, context):
    return [{"title": "作品名", "sourceUrl": "/book/1", "author": "作者", "synopsis": "简介"}]
```

- 返回普通 `dict` / `list`，不要返回 HTTP 响应、Pydantic 模型或青卷内部类型。未知输出字段会被拒绝。
- 预览标题与目录必填，目录为 1–100000 项，标题非空、最多 500 字符；章节 URL 不得重复。`chapterCount` 由宿主计算，插件不返回该字段。
- `pageCount` 可省略，默认 0 且不得为负；`accessRestricted` 可省略，默认 `false`，只作为目录元数据，不代表授权判断。
- 小说章节要求非空 `text`，最多 4,194,304 个字符；可附带 `imageUrls` 作为插图。漫画章节要求非空 `imageUrls`，例如：

```python
async def chapter(url, context):
    data = await context.get_json(url)
    return {"imageUrls": [page["url"] for page in data["pages"]]}
```

- 漫画图片有序，最多 3000 个 URL；返回的是图片来源地址，宿主负责下载、缓存与阅读。禁止返回本地路径、数据 URL 或 Base64 代替图片链接。
- 搜索可返回空数组，最多 100 项，遵守传入的 `limit`；作品标题与 `sourceUrl` 必填，其他可选字段同预览。类型和来源由清单/宿主补齐。
- 作品/章节 URL 只能属于 `domains`；封面、图片可以属于 `domains + networkDomains`，URL 最多 4096 字符，不得内嵌凭据。
  相对 URL 以当前输入作品/章节 URL 为基准，搜索则以 `https://domains[0]/` 为基准。
- 解析不到正文、遇到验证页、结构变更或无可用图片时应抛异常；不得把错误、简介或反爬页面伪装成正文，不得虚构上游内容或授权状态。
  宿主向用户返回不含异常原文的中文错误，既有章节仍按原有原子写入流程保留。
- 每次调用可以并发进行；避免全局可变状态，不缓存用户私有数据。调用执行期间，以及有运行中任务或链接导入使用该插件的站点时，更新、回退与卸载返回 `409`。
  请先暂停任务并等待当前请求结束，再维护插件；排队或已暂停任务恢复后使用当前版本。被替换的旧处理器不接受新的调用。

## 5. Context SDK

| API | 返回值 / 行为 |
| --- | --- |
| `context.plugin_id` | 当前插件稳定 ID |
| `context.base_url` | 当前作品/章节 URL，搜索时为首个域名的 HTTPS 根地址 |
| `context.resolve_url(value)` | 解析相对链接并校验网络域名及公网 URL 格式 |
| `await context.get_text(url, params={"q": keyword})` | GET 文本，解析响应字符集；`params` 可省略 |
| `await context.get_json(url, params=...)` | GET 后解析 JSON |
| `context.parse_html(text)` | 使用 `html.parser` 的 BeautifulSoup 对象，支持 `.select()` / `.select_one()` |

每次调用最多 30 个 HTTP 请求（包含重定向），每次 GET 最多跟随 5 次重定向，解压后响应最大 4 MiB。
SDK 不支持自定义凭据请求头、POST 或登录流程；需要这些能力的扩展应先升级协议，再更新实现和客户端，不能随意发明清单字段。
完整 HTML 解析模板见 `examples/plugins/html-novel/`；它使用虚构域名，需先替换域名、CSS 选择器与上游请求契约。

## 6. 打包与验证

在配置了青卷后端 Python 依赖的环境中，于仓库根目录运行：

```powershell
python tool/package_site_plugin.py examples/plugins/html-novel --check
python tool/package_site_plugin.py examples/plugins/html-novel --output dist/plugins/my-site.qjplugin
```

测试请在后端目录运行（Python 模块搜索路径以此为准）：

```powershell
Set-Location python-backend
python -m pytest tests/test_plugin_packages.py tests/test_plugin_runtime.py tests/test_plugin_maintenance.py
```

打包工具仅收集上述两个文件，固定文件顺序与 ZIP 时间戳，相同源码生成相同内容。`--check` 只校验清单、包结构和语法，
不会执行模块，函数签名/实际解析效果还须用固定上游 Fixture 测试并安装验证。开发测试应覆盖相对链接、目录顺序、图片顺序、空响应、
异常、停用、超时和站点域名变化，不以实时网站请求代替稳定测试。

## 7. 生命周期与持久化

- 安装包、清单、摘要保存在当前后端 SQLite 的 `site_plugin_packages`；开关保存在既有 `site_plugin_settings`；上一版本保存在 `site_plugin_package_history`。
  三者在同一数据库中，升级后端保留，完整备份包含这些记录。切换后端不会同步插件。
- 更新必须显式提交 `replace=true` 且版本严格提高；加载失败的记录允许同版本修复。版本/ID/域名冲突、语法、签名、模块加载或保存失败均不会替换旧包和旧运行时。
  Python 顶层副作用无法回滚，因此插件必须遵守无副作用要求。
- 每个插件只保留一个上一版本，包括包、清单及摘要；成功更新才覆盖此记录。回退请求必须携带自检返回的当前版本及包摘要，后端再次校验以拒绝过期确认。
  只有显式回退允许降低版本；回退仍检查历史包、协议、内置 ID、域名冲突和运行接口。回退成功后，原当前版本成为上一版本，因此可以再次切回。
  历史包损坏或当前没有上一版本时拒绝回退。更新、回退及卸载在 SQLite 事务中切换运行注册表，发布或提交失败时恢复旧注册表；不提前释放旧模块。
- 维护自检校验当前包 SHA-256、保存清单一致性、ZIP 结构、Python 语法、协议版本，以及已加载模块的异步函数和参数签名，返回当前 Python/协议版本与兼容提示。
  自检不重新导入插件、不执行处理器、不请求第三方站点，也不证明插件可信或站点可用。上一版本仅做静态检查，回退时还需加载验证。
  不提供自动下载更新、任意更新 URL、作者身份认证或可信自动升级。
- 服务启动逐个校验摘要并恢复插件。一项加载失败不会阻止其他模块和后端启动；列表显示 `loadError`，相关操作拒绝执行，可更新修复或卸载。
- 卸载删除当前安装包、上一版本和该插件开关，不删除书籍、缓存正文、图片或阅读进度。未缓存章节需要可用解析器；链接重新按当前注册表匹配。
- 安装热生效针对后端单进程模型；Linux 继续使用单 worker。不能把该实现部署为多个共享数据库但互不通知的 worker。

## 8. HTTP 契约

路径均相对于 `/api/v1`，沿用现有实例认证与用户授权。

| 方法与路径 | 请求 | 响应 / 权限 |
| --- | --- | --- |
| `GET /plugins` | 无 | 插件公开清单；有效用户 |
| `PUT /plugins/{id}` | `{"enabled":false}` | 保存启停；管理员用户或管理网页 |
| `POST /plugins/inspect` | multipart `file` | `plugin` 元数据、`installedVersion`、`sha256`；管理网页或受信本机 |
| `POST /plugins/import` | multipart `file`、可选 `replace` | `201` + 插件元数据；管理网页或受信本机 |
| `GET /plugins/{id}/maintenance` | 无 | 当前维护报告；管理网页（含 CSRF）或受信本机 |
| `POST /plugins/{id}/check` | 无 | 显式运行自检，返回维护报告；管理网页或受信本机 |
| `POST /plugins/{id}/rollback` | `{"expectedVersion":"1.1.0","expectedSha256":"当前包的64位小写十六进制摘要"}` | 回退后的插件元数据；管理网页或受信本机 |
| `DELETE /plugins/{id}` | 无 | `204`；管理网页或受信本机 |
| `POST /plugins/search` | `{"keyword":"青卷","limit":20,"sourceIds":[]}` | 聚合外部插件搜索结果；有效用户 |

搜索的 `sourceIds` 为可选插件 ID 筛选（默认全部已启用且支持搜索的导入插件），`limit` 为 1–60，关键词最多 100 字符。
结果沿用 `BookSourceSearchResult`，`sourceName` 是插件名，`sourceId` 为空字符串，导入按 URL 匹配插件，不借用 Legado 规则 ID。
各插件最多返回 20 项至聚合搜索，全局并发为 4、总等待上限为 35 秒，超时取消剩余请求；单个插件异常不影响其他成功结果，所有插件均失败时返回 `502`。

新增公开元数据：`origin` 为 `builtin` / `installed`，`author` 为作者声明，`apiVersion` 为插件协议版本，`loadError` 可空。
不返回源代码、包内容、服务器路径或运行时对象。错误使用中文 `detail`：无管理会话 `401`，缺少 CSRF `403`，不存在 `404`，
重复安装/版本/域名/内置 ID 冲突、活跃调用或任务、过期回退确认 `409`，包过大 `413`，格式/加载失败 `422`，存储失败 `503`。

维护报告包含 `pluginId`、`version`、`sha256`、`apiVersion`、`supportedApiVersion`、`pythonVersion`、`enabled`、`compatible`、`activeCalls`、
`rollbackVersion`、`rollbackSha256`、`rollbackAvailable`、`checkedAt` 及 `checks`（每项含 `code`、`label`、`status`、`message`）。
`status` 为 `passed`、`failed` 或 `warning`。`activeCalls` 是检查时的在途处理器数量，操作提交时仍会检查任务和新请求，不能把零值当作回退预约。
`rollbackAvailable` 仅表示存在通过静态校验的历史包；回退时可能因为任务繁忙、域名冲突或运行接口加载失败而拒绝。维护与回退响应使用 `Cache-Control: no-store`。

## 9. COMICORES 当前边界

COMICORES 仍只支持搜索和作品元数据，`chapter_handler=None`，不能把空目录或文章图片列表标成可下载章节。2026-09-11 公开抽查的 [塔之迷宫](https://www.comicores.cc/tower-dungeon/.html)、[屠龙者布伦希尔德](https://www.comicores.cc/ryuugoroshi-no-brunhild/.html)只提供作品信息并提示登录后查看；[CLAYMORE](https://www.comicores.cc/claymore/.html)的文章图片缺少可验证卷章标识，抽查图片直链返回 403。后续需要可验证的公开章节或授权样例后再实现解析与下载，不绕过访问限制。
