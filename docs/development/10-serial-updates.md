# 连载追更

Windows 书库卡片、Android 长按单选工具栏及作品详情提供“连载追更”入口。作品是否连载由后端读取来源元数据判断，客户端不再要求用户手工启用追更。支持手动检查、定时检查、未确认更新标记，以及用户选择的自动下载。连载作品的检查间隔默认 6 小时，可设置为 1 到 168 小时；可检查但状态未知的来源至少间隔 24 小时确认，不能把未知显示为连载。明确完结后停止周期目录检查，仍保留手动检查、已有章节与更新标记。定时检查由运行中的后端执行，客户端每 30 秒刷新书库摘要。

## 来源连载状态

`PreviewResponse.sourceStatus` 使用 `ongoing / completed / unknown`，与 `BookRecord.status` 的下载和翻译状态完全独立。`sourceStatusEvidence` 只包含字段或元数据位置，不返回供应商完整响应。完整下载和仅导入目录两条路径都把 `source_status`、`source_status_evidence`、`source_status_checked_at` 写入 manifest；每次目录检查也更新这些字段，即使没有新增章节。来源字段缺失、冲突、暂停、非公开或未验证的数值都保留未知；不得根据章节数、书名、简介或“已下载”推断完结。

2026-09-12 的字段依据与支持范围：

| 来源 | 字段及判定 | 核对依据 |
| --- | --- | --- |
| 番茄 | `page.creationStatus`：0 完结、1 连载；其余未知 | [官方作品页](https://fanqienovel.com/page/7654593151348247614) 的元数据与状态标签；[官方公共脚本](https://lf-fe.fqnovelstatic.com/obj/novel-fanqie-fe/toutiao/muye/js/muye_a2c8e2a7.js) 明确 `DONE=0 / DOING=1` 与中文标签。脚本 SHA256：`6ab30580f1dee8f57939998a18a300ddd9d366eee270541dde20b9b26b887973`。只有作品信息区的状态标签可作为后备，正文不参与判断。 |
| 起点 | `bookInfo.bookStatus` 的“连载／完本”等明确文字，以及严格布尔 `finish` | [官方作品信息 API](https://wxapp.qidian.com/api/book/info?bookId=1010868264) 实返“完本”和 `finish: true`；两个字段冲突时为未知，不猜 `state` 数字码。 |
| 夸克／书旗 | `xapi/book/info` 作品对象 `state`：1 连载、2 完结 | 官方 API 与 [8869540 作品页](https://www.shuqi.com/book/8869540.html) 的“连载”、[7106468 作品页](https://www.shuqi.com/book/7106468.html) 的“完结”交叉核对。不能读取外层响应 `state: 200` 作为作品状态。 |
| Kakuyomu | `work.serialStatus`：`RUNNING / COMPLETED` | 复用现有推荐 API 已记录的枚举；作品 GraphQL 查询显式请求该字段。`SUSPENDED / DRAFT` 不归类为连载或完结。 |
| 拷贝漫画 | `comic.status.display` 的明确文字 | 只读显示名称，不推断附带数值编码。 |
| Bika／SF 轻小说 | 作品对象的严格布尔 `isFinished / isFinish` | 缺字段或字符串不按 JavaScript 真值推断。SF 字段与现有推荐接口一致。 |
| 通用来源 | 明确的小说状态 meta，或作品 JSON 的 `sourceStatus / publicationStatus` | 精确匹配状态文字；普通 HTTP、下载或任务 `status` 不参与推断。 |

## 目录与来源

导入 manifest 保存 `source_id` 和 `site_plugin_id`。检查使用原始 URL 和来源记录，验证原书源、原插件仍存在且启用。旧作品只有唯一内置专用插件能确认来源时兼容；缺少来源记录的旧通用网页、已替换的插件和使用自定义解析规则的书源会明确返回原因。

网络请求在 manifest 锁外执行，提交时使用 `_chapter_manifest_lock_for(book_id)` 并重新读取磁盘目录。只比较章节 URL，追加新的 `max(index)+1`，不修改旧章节顺序、标题、文件名、译文或阅读位置。空目录、无 URL 交集及无效章节链接均拒绝更新。

网络请求前和发布前都检查本书是否有 `running`、`pause_requested` 或 `cancel_requested` 任务；存在时返回 409“正在处理章节，请稍后检查更新”。发布前检查、manifest 原子写入和计数更新之间没有 await。只更新数据库计数，不把旧 BookRecord 写回数据库。

## 持久状态和恢复

`book_updates` 按 `book_id` 主键和 `owner_id` 保存设置、来源状态、支持情况、确认位置、尝试时间、成功时间、下次检查时间、错误和设置版本。后端周期自动发现新书与已有书籍；导入保存成功后还会调用同步 `register_book` 提前登记。该钩子失败不影响已成功的导入，下一周期补偿。没有有效来源、原插件被替换／停用、仅支持作品信息或目录不可用的书籍不入检查队列，响应明确 `supported: false` 与原因；状态未知且可检查时则 `supported: true`，两者不混同。

新章标记直接由 manifest 章节编号与确认位置比较计算，因此 manifest 已发布但数据库更新失败也不会丢失标记。来源状态也以已发布 manifest 为准，重启会重新同步调度。失败后定时检查会稍后重试，手动检查至少间隔 30 秒，同一作品的并发手动请求共享一次检查。

自动下载复用章节缓存协调器，仅排队未确认且尚未缓存的新增章节。每分钟重试未完成下载，重启后仍可恢复；不会因为本次目录没有新增内容就遗漏此前的下载。确认更新不会修改阅读进度。

周期快照读取、目录检查和后台下载均受维护门控制。关停会取消追更循环及进行中的预览，备份恢复后重新启动。

## 接口

- `GET /api/v1/book-updates`：当前账号书籍的自动追更摘要，包括不支持时的明确原因。
- `GET /api/v1/books/{id}/updates`：单本状态及设置。
- `PUT /api/v1/books/{id}/updates`：`expectedRevision`、`intervalHours`、`autoDownload`；版本冲突返回 409。`enabled` 仅作为旧客户端可选兼容字段接收，不覆盖后端根据来源计算的有效调度状态。不支持的书籍仍可保存偏好，但不会启动检查或下载。
- `POST /api/v1/books/{id}/updates/check`：手动检查；限频返回 429。
- `POST /api/v1/books/{id}/updates/ack`：`throughChapterIndex` 确认到客户端已看到的位置，不会确认并发检查后来发现的章节。

能力标志是 `bookUpdates`。状态包含 `automatic: true`、`supported`、`unsupportedReason`、`sourceStatus`、`sourceStatusCheckedAt`，以及 `newChapterCount`、`latestChapterIndex`、`acknowledgedChapterIndex`、检查时间、错误和设置版本。`enabled` 表示后端计算的有效调度状态，不是连载证据。客户端切换账号或服务会清除摘要、待处理操作与表单，并忽略迟到响应。

回归测试位于 `python-backend/tests/test_book_updates.py`、`test_source_status.py`、`test/features/library/book_updates_controller_test.dart` 和 `book_updates_page_test.dart`。在线核对只读取公开元数据与官方脚本，不下载正文，不使用用户账号；回归测试使用模拟上游和临时目录。
