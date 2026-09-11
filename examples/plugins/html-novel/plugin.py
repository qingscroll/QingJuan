"""Replace the manifest domains and CSS selectors with your site's contract."""


async def preview(url, context):
    document = context.parse_html(await context.get_text(url))
    title = document.select_one("h1.book-title")
    if title is None:
        raise ValueError("作品页没有标题")
    author = document.select_one(".book-author")
    synopsis = document.select_one(".book-description")
    cover = document.select_one(".book-cover img")
    return {
        "title": title.get_text(strip=True),
        "author": author.get_text(strip=True) if author else None,
        "synopsis": synopsis.get_text("\n", strip=True) if synopsis else "",
        "cover": cover.get("src") if cover else None,
        "chapters": [
            {"title": link.get_text(strip=True), "url": link["href"]}
            for link in document.select(".chapter-list a[href]")
        ],
    }


async def chapter(url, context):
    document = context.parse_html(await context.get_text(url))
    content = document.select_one("#chapter-content")
    if content is None:
        raise ValueError("章节页没有正文")
    for element in content.select("script, style, .advertisement"):
        element.decompose()
    return {"text": content.get_text("\n", strip=True)}


async def search(keyword, limit, context):
    document = context.parse_html(await context.get_text("/search", params={"q": keyword}))
    return [
        {"title": link.get_text(strip=True), "sourceUrl": link["href"]}
        for link in document.select(".search-results a.book-title[href]")[:limit]
    ]
