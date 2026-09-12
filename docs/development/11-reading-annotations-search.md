# 书签、笔记与缓存正文搜索

阅读器顶部的“书签、笔记与搜索”入口在 Windows 和 Android 共用 `AnnotationsController`。连续阅读选中正文后可通过菜单“记笔记”保存摘录与精确位置；分页阅读使用每页独立的 `SelectionListenerNotifier` 读取选区，包括重复文字与反向选择。监听坐标与原分页字符串可能因空的段首 WidgetSpan、跨段片段而不同，保存前以实际摘录严格校验原坐标和移除占位符后的候选；仅一个位置精确匹配时映射回原 UTF-16 坐标。

## 正文中的持久划线

保存选区笔记后，返回或再次打开阅读器会在对应正文显示下划线。Windows 连续阅读、Android 连续和分页阅读共用同一定位与绘制逻辑；编辑笔记后保留划线，删除后移除。从笔记页返回阅读器、应用恢复前台时刷新当前可见章节的笔记。切换账号或服务会立即清除旧划线并忽略迟到结果；新加载的正文指纹变化时也会先清除旧位置。

划线复用既有 `quote`、`position.characterOffset`、`contentHash`，不改数据库格式。只接受当前作品、章节、原译模式和正文 SHA-256 一致，且摘录在指定 UTF-16 起点精确匹配的笔记。段首占位符可以跳过，但不会搜索其他位置代替失效锚点；无指纹、正文已改变、无法定位或非文本章节不绘制。文字选择、段首占位符、段间距和分页字符串保持不变，只给匹配 TextSpan 增加下划线装饰。

新选区使用 `selected-text-utf16-v2` 表示精确锚点。分页优先验证监听到的范围与可见摘录一致；仅在监听范围不可用时尝试唯一摘录映射，仍无法确定位置才记录 `selected-text-unresolved-v2`，笔记及页首跳转仍可使用，但不猜测划线。旧记录继续可编辑和跳转，仅当摘录在整章唯一且原起点精确匹配时恢复划线。多个重叠笔记的范围合并，跨段或跨页的范围按原 UTF-16 坐标裁切。

阅读器按章和原译模式分页读取笔记，完整拉取该章超过 50 条的记录，不只使用笔记列表首页。读取失败不阻塞正文；重新打开笔记页或恢复前台后可重新加载。当前划线依赖服务端笔记，未新增离线笔记副本。

## 服务端数据与并发

`reading_annotations` 按作品和账号隔离，保存类型、标题、摘录、笔记、阅读位置、正文指纹与修订号。更新和删除要求 `expectedRevision`，过期操作返回 409。创建请求带 `clientKey`，服务端校验初次请求指纹，同一请求重试返回现有记录；已删除记录保留幂等凭据，清除标题、笔记、摘录及位置，防止迟到请求重建内容。删除作品会级联删除这些记录。

书签和笔记独立于原文、译文、目录和阅读进度。正文指纹采用实际阅读器段落规范的 SHA-256；章节内容变化后列表返回 `contentChanged`，页面在跳转前提示核对摘录。单纯编辑笔记不会清除正文变化提示。

接口：

- `GET /api/v1/books/{id}/annotations?kind=bookmark&limit=50&offset=0`，kind 可为 bookmark 或 note；可选 `chapterIndex` 和 `mode=original|translated` 在分页前筛选，旧请求保持不变。
- `POST /api/v1/books/{id}/annotations`：clientKey、kind、label、quote、note、position。
- `PATCH /api/v1/books/{id}/annotations/{annotationId}`：expectedRevision 与待修改字段。
- `DELETE /api/v1/books/{id}/annotations/{annotationId}?expectedRevision=1`。
- `POST /api/v1/books/{id}/search-text`：query、mode、可选 chapterIndex/cursor，limit 默认 50、最多 100。

`position` 包括 chapterIndex、scrollRatio、anchorType、anchorIndex、anchorOffsetRatio、pageIndex、pageCount、layoutKey、contentMode、characterOffset。字符偏移一律为 UTF-16；客户端独立 DTO 转换为既有 `ReadingProgress`，不会将书签修订号用作阅读进度修订号。

## 搜索约束

搜索仅读取服务端已有缓存，不下载内容，不初始化目录。原文和译文分别搜索，译文缺失时不回退原文。查询是大小写不敏感的字面文本，最多 120 字符。单次最多扫描 100 章、读取 8 MiB 章节字节，单章最多 2 MiB，目录最多 16 MiB，同时最多两个搜索。错误编码消耗扫描预算，超过单章限制的文件会跳过。响应带未缓存章数、跳过章数、扫描章数及可续查游标。

正文会依次去掉空行、旧缩进和重复段首标记，再按阅读器规范添加段首标记并以两个换行连接。命中位置包含 UTF-16 字符偏移；客户端强制检查 `offsetEncoding`。游标绑定关键词、原译模式和章节范围，修改条件后须重新搜索。

路径读取限制在受管理的数据目录，拒绝越界目录和章节文件。取消搜索时等待工作线程退出后释放请求，避免维护恢复在后台文件读取结束前切换数据库。

## 客户端生命周期与能力

`readingAnnotations` 和 `cachedTextSearch` 分别控制入口。列表和搜索各有请求序号，迟到结果不能覆盖新筛选或新关键词。写操作禁止重复提交，保存失败保留草稿和创建键；编辑冲突可显式放弃草稿并重载。切换账号或后端会清除列表、查询、草稿，旧页面永久失效。

回归覆盖账号隔离、CAS 并发、幂等创建和删除重放、原文件保留、正文变化、缓存与路径限制、跨段落和表情字符偏移、续查预算、双端 200% 字号表单、实际阅读器选区笔记与跨章搜索跳转。

持久划线回归还覆盖真实阅读器保存、重开、编辑与删除，真实 SelectionListener 正向/反向选择第二个重复词，旧锚点和无法定位摘录降级，指纹/原译模式/章节不匹配不绘制，章节内容刷新与迟到请求，超过 50 条笔记的分页，以及 200% 字号时划线前后逐字符选择框与段间距完全一致。
