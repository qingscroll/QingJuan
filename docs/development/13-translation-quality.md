# 小说翻译质量管理

本功能面向当前账号拥有的小说书库，Windows 和 Android 可在作品详情中直接打开 **术语与人名**，在下载或翻译章节前统一译名。
详情中的 **译文校对** 面向已下载章节，包含校对、每书术语表、人名映射、历史版本和模型用量。书库以后端为准，不在客户端另建译文副本。

## 1. 编辑与冲突

- 校对只接受已有原文文件的小说章节，漫画使用既有漫画译图流程。交互编辑限制为每章 1 MiB、20 万字符；超出限制的普通整章翻译仍走现有任务流程，暂不提供交互历史管理。
- 原文只读。译文可以人工修改，也可以从选段重译候选插入到草稿；只有点击 **保存校对** 才写入后端。阅读和导出随后读取同一译文文件。
- 每次保存、恢复或生成重译候选都必须携带读取时的 `expectedRevision`、`sourceHash`、`translationHash`。摘要以读取后统一换行的 UTF-8 文本计算 SHA-256。
  三者任一变化返回 `409`，不会覆盖新的原文或译文。客户端保留未提交草稿，并允许明确放弃草稿后重新加载。
- 对该书有运行中、请求暂停或请求取消的任务时，人工保存与历史恢复返回 `409`。先暂停任务并等待当前章节落盘再校对。
  正常小说翻译任务也使用相同的版本提交机制：开始调用模型前取得快照，调用完成后再次检查摘要与版本。
- 后端或账号切换会清空页面正文、草稿、术语表、历史、候选和用量，禁用已打开的确认框；迟到响应不能填入新账号或后端。

## 2. 术语和人名

- 每本小说最多 100 项，每项包含 `source`、`target`、`kind`（`term` / `name`）和可选 `note`。
  原文与译名各 1–100 字符，备注最多 200 字符；不允许空白、控制字符或重复的原文（忽略大小写）。
- 术语表独立使用 `expectedRevision` 比较并保存。更新术语表不会改写已有译文。
- 书籍级术语入口只读取术语接口，不要求有已下载章节，也不触发模型请求；保存失败保留表单，版本冲突需重新加载后核对。账号或后端切换会清空术语并禁用未提交表单。
- 普通小说章节翻译与选段重译会把原文中匹配的术语、译名、类型和备注作为提示数据提供给已配置模型。
  模型可能不完全遵守术语，因此仍需人工核对。术语不是自定义服务端代码或自动执行指令。

## 3. 历史和持久化

- `book_glossaries` 保存术语；`translation_quality_state` 保存每章当前版本与摘要；`translation_quality_history` 保存最近 100 个版本的完整译文、摘要和创建时间。
  历史类型为 `initial`、`edit`、`restore`、`translate`、`external`。首次校对时纳入已有的非空译文；外部文件变化在下次提交时单独保留。
- 查看历史不改变文件。恢复需要单独确认，并把历史内容保存为新版本；历史对应原文摘要与当前不同则拒绝恢复，用户可查看并复制需要的文字到草稿。
- SQLite 事务保存新历史和状态，译文文件用同目录临时文件、`fsync` 和原子替换发布。替换前创建 `.translation-quality-<章节>.json` 恢复记录；发布或事务提交失败会恢复旧文件。
  恢复记录只允许操作该书清单中对应章节的译文文件，禁止目录跳转、符号链接或修改原文。
- 进程意外退出后，`recover_translation_quality_writes(DATA_DIR)` 在数据库初始化后、任何工作器启动前执行。
  它根据 SQLite 中是否存在预期新版本判断保留新文件或恢复旧文件。无法确定的记录会阻止恢复流程完成，不静默覆盖内容。
- 以上记录均关联书籍并按 `owner_id` 隔离，删除书籍时级联删除。完整备份保留全部数据；显式本机书库迁移重新指定术语、状态、历史和用量归属，清除源实例选段请求记录。

## 4. 选段重译与模型用量

- 客户端必须明确选择原文及译文插入位置或替换范围。`sourceStart`、`sourceEnd` 使用 Unicode 码点偏移，不使用 UTF-16 code unit；Flutter 在请求前转换并拒绝截断代理对。
- 每次只翻译 1–4000 个原文字符，固定最多 8000 输出 Token、32,000 输出字符、60 秒总超时；复用当前模型设置、系统提示及安全模型 HTTP 客户端。
  不接受客户端提供模型端点、密钥或模型名称。无自动重试，无推理耗尽后的自动扩额；截断或空响应不会作为候选返回。
- 每个账号最多一个、全服最多两个在途选段请求，每账号每小时最多 20 次（包括失败和取消）。客户端为一次明确操作生成随机 `operationId`，后端在 `translation_quality_requests` 中先原子登记。
  相同账号、操作 ID 和参数的成功请求返回已有候选；参数不同、仍在执行或已失败返回 `409`，不会再次调用模型。重启把未完成请求标记失败，不自动重放付费请求。
- 返回值只是候选。模型调用期间若原文或现译文发生变化，返回 `409` 并保留已记录的模型用量，不覆盖当前内容。
  用户核对候选、替换到草稿后还须单独保存。失败错误不包含供应商正文、请求内容、密钥或内部路径。
- `translation_quality_usage` 记录普通小说翻译和选段重译每次实际模型请求的模型名、输入/输出/总 Token、耗时、状态和时间。
  缺少 Token 字段时为 `null`，不伪造为 0，不估算金额；服务商数据是自报数据，不是账单。失败和取消可能没有可用的 Token 数据。
- 每书最多保留 1000 条用量，API 展示最近 100 条。用量不保存提示文本、供应商错误原文、端点或密钥，普通账号只能查看自己书籍的记录。
  用量存储失败不得触发额外付费重试或丢弃有效模型输出，该次候选的 `usage` 会为空。

## 5. HTTP 和接入

路径相对 `/api/v1`，均要求有效用户且书籍属于该用户；跨账号统一返回 `404`，成功响应使用 `Cache-Control: no-store`。

| 路径 | 方法 | 请求与响应 |
| --- | --- | --- |
| `/books/{id}/glossary` | GET / PUT | `BookGlossary`；PUT 提交 `expectedRevision, entries` |
| `/books/{id}/translation/chapters/{index}` | GET / PUT | `ChapterTranslation`；PUT 提交三个 CAS 字段及 `text` |
| `/books/{id}/translation/chapters/{index}/history/{historyId}` | GET | 历史元数据与完整 `text` |
| `/books/{id}/translation/chapters/{index}/restore` | POST | 三个 CAS 字段和 `historyId`，返回新 `ChapterTranslation` |
| `/books/{id}/translation/chapters/{index}/retranslate` | POST | 三个 CAS 字段、`operationId, sourceStart, sourceEnd`，返回候选 `text` 和可空 `usage` |
| `/books/{id}/translation/usage` | GET | 当前书最近 100 条 `TranslationUsage` |

数据库 hook 为 `translation_quality_repository.ensure_translation_quality_schema(conn)`，Router 为 `api.translation_quality.router`，能力标记为 `translationQuality`。
Flutter DTO 位于 `core/models/translation_quality.dart`，章节入口为 `showTranslationQualityEditor(context, bookId:, chapterIndex:, mobile:)`，书籍术语入口为 `showBookGlossaryEditor(context, bookId:, mobile:)`。
写请求均关闭自动重试；重译请求客户端超时设为 70 秒，以涵盖后端的 60 秒上限及响应处理。

## 6. 验证

测试仅使用临时 SQLite、临时书库与固定模型响应，不读取真实用户书库，也不发出付费模型请求。
重点覆盖 CAS、跨账号、源文改变、任务占用、Unicode 选区、候选不自动保存、异常脱敏、无自动重试、防重、并发与取消、初始历史和版本恢复、文件/事务失败回滚、进程中断恢复及手机大字布局。

```powershell
Set-Location python-backend
python -m pytest tests/test_translation_quality.py tests/test_translation_quality_storage.py tests/test_translation_quality_retranslate.py tests/test_translation_quality_api.py tests/test_translation_quality_tasks.py
```

Flutter 相关测试位于 `test/features/translation_quality/`。

## 7. 资源限制

正式译文发布与普通下载共用账号文件配额，使用当前 SQLite 写事务检查实际增加量。超额返回 `413`，原文、旧译文和历史版本均保留；恢复日志和旧文件回滚不受新额度阻断。配额检查的发布锁保持到事务成功或文件回滚结束。具体文件计量与内部暂存规则见 [书籍空间与文件发布配额](12-storage-management.md)。

管理员配置的每日模型请求限制在安全 HTTP 客户端真正发送模型 POST 前原子登记，失败和重试也占请求次数；不能用供应商自报 Token 代替计数。选段重译保留其独立的并发和每小时限制，达到任一限制会明确失败，不自动增加预算或重放请求。
