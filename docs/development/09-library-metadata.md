# 书库整理与元数据

书库中的分组、标签、置顶和阅读状态属于作品的当前账号。Windows 书库卡片的“编辑信息”和 Android 长按单选后的“编辑信息”打开同一套编辑流程；详情页也可进入。筛选按分组、标签、阅读状态和置顶取交集，关键词同时匹配书名、作者、简介和标签。四种排序方式均优先显示置顶作品。

## 数据与 API

`book_metadata` 使用 `book_id` 主键及书籍外键，记录 `owner_id`、`metadata_json`、`revision` 和 `updated_at`。删除书籍会级联删除覆盖记录。分组以名称保存，清空名称表示未分组。阅读状态为 `unread`、`reading`、`finished`、`on_hold`；未显式设置时有阅读记录的作品显示“在读”。

- `GET /api/v1/books/{bookId}/metadata`：返回当前生效的书名、作者、简介、分组、标签、置顶、阅读状态，以及 `revision`、`updatedAt`、`overriddenFields`。
- `PATCH /api/v1/books/{bookId}/metadata`：必须携带 `expectedRevision`，其余仅发送修改字段。版本不一致返回 409。重复提交完全相同的覆盖内容不增加版本。
- `title`、`author`、`synopsis` 为 `null` 时恢复来源值；空作者和空简介可以作为显式覆盖。`groupName: null` 取消分组。标签最多 20 个，每个最多 80 字，去除首尾空白并去重。
- 能力标志为 `libraryMetadata`。作品列表使用 `metadataRevision`；独立元数据响应使用 `revision`。

## 内容安全与并发

覆盖记录与下载状态、源 manifest、章节和译文分开保存。`apply_book_metadata` 只用于最终响应副本；不得把该副本传回 `save_book`。`metadata_manifest` 仅返回用于导出的副本，保留原章节数组。下载目录必须先使用源书名与源路径解析，再替换展示字段。

来源读取优先使用调用方传入的 manifest，回退只读取 `DATA_DIR` 内的 manifest 文件，解析失败时使用书籍记录。元数据模块不初始化目录、不写 manifest、不移动文件。

客户端保存成功后立即更新对应书库条目，保留下载计数、封面和阅读位置。保存会使较早开始的书库刷新失效。切换账号或服务会清除筛选及编辑草稿，迟到的读取和保存响应不会写入新账号状态。保存失败保留草稿，409 后可显式重新加载最新信息再编辑。

## 回归检查

- `python-backend/tests/test_library_metadata_overlay.py`：覆盖文件不变、后台源记录更新、恢复来源、并发版本冲突、账号隔离、级联删除、字段校验及安全路径。
- `test/features/library/book_metadata_controller_test.dart`：筛选排序、保存和刷新竞争、保留阅读字段、失败重试及账号切换。
- `test/features/library/book_metadata_editor_test.dart`：两端 200% 字号、错误草稿、恢复来源、筛选和 Windows 入口。
- `test/mobile/library_store_test.dart`：Android 长按编辑、整理筛选，以及既有书库行为。
