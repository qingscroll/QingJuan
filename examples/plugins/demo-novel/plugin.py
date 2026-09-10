"""Runnable without network access. Use only as an installation/SDK example."""

TITLE = "青卷插件示例"
CHAPTERS = {
    "1": "这是第一章。正文由独立导入的 Python 插件返回，没有修改青卷内置解析器。\n\n你可以在插件配置中停用它，已缓存的内容仍可阅读。",
    "2": "这是第二章。修改本文件后，提高 manifest.json 的 version，重新打包并导入即可更新插件。",
}


async def preview(url, context):
    return {
        "title": TITLE,
        "author": "青卷项目",
        "synopsis": "用于验证外部插件完整链路的两章示例。",
        "chapters": [
            {"title": "第一章：独立导入", "url": "/chapter/1"},
            {"title": "第二章：更新插件", "url": "/chapter/2"},
        ],
    }


async def chapter(url, context):
    chapter_id = url.rstrip("/").rsplit("/", 1)[-1]
    if chapter_id not in CHAPTERS:
        raise ValueError("示例章节不存在")
    return {"text": CHAPTERS[chapter_id]}


async def search(keyword, limit, context):
    if keyword not in TITLE:
        return []
    return [{"title": TITLE, "sourceUrl": "/book/1", "author": "青卷项目"}][:limit]
