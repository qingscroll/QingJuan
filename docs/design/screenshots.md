# 移动端最终截图

本目录收录2026-09-05主操作按钮与配色统一后重新生成的47张 PNG，来源为本轮314项 Flutter 测试中的实际 Widget 渲染。页面接入生产 Widget、主题和控制器，网络返回、作品内容、账号及任务状态由测试 fixture 提供。图片可用于检查布局和深浅主题，不能作为 Android 真机、实际远端内容服务或原生插件运行成功的证据。归档文件已与 `build/mobile-ui-preview/` 逐一核对SHA256。

手机主流程使用390 × 844逻辑像素；小屏额外覆盖320dp宽度与200%文字，账号安全使用320dp宽度与180%文字；平板图为1024 × 768逻辑像素。PNG以2倍像素比导出。截图使用本机可用的中文字体，不作为跨操作系统逐像素基准。

## 主路径与详情

| 场景 | 浅色 | 深色 | 其他布局 |
| --- | --- | --- | --- |
| 书库与小液态胶囊导航 | [查看](screenshots/library-light.png) | [查看](screenshots/library-dark.png) | [320dp / 200%文字](screenshots/library-320-large-text.png)、[平板](screenshots/library-tablet-light.png) |
| 发现：来源、搜索与作品结果 | [查看](screenshots/store-light.png) | [查看](screenshots/store-dark.png) | [320dp / 200%文字](screenshots/store-320-large-text.png)、[平板深色](screenshots/search-tablet-dark.png) |
| 任务：阶段、章节进度、失败及重试 | [查看](screenshots/tasks-light.png) | [查看](screenshots/tasks-dark.png) | — |
| 我的：阅读偏好与账号服务 | [查看](screenshots/my-light.png) | [查看](screenshots/my-dark.png) | [320dp / 200%文字](screenshots/my-320-large-text.png) |
| 作品详情与目录 | [查看](screenshots/detail-light.png) | [查看](screenshots/detail-dark.png) | — |
| 作品的下载、翻译与导出操作 | [查看](screenshots/detail-actions-light.png) | [查看](screenshots/detail-actions-dark.png) | — |

## 导入、阅读与听书

| 场景 | 浅色 | 深色 |
| --- | --- | --- |
| 导入方式选择 | [查看](screenshots/import-chooser-light.png) | [查看](screenshots/import-chooser-dark.png) |
| 链接导入完整页面 | [查看](screenshots/import-form-light.png) | [查看](screenshots/import-form-dark.png) |
| 当前导入的处理阶段 | [查看](screenshots/import-running-light.png) | [查看](screenshots/import-running-dark.png) |
| 导入中断后的恢复操作 | [查看](screenshots/import-recovery-light.png) | [查看](screenshots/import-recovery-dark.png) |
| 小说正文与按需控制栏 | [查看](screenshots/reader-light.png) | [查看](screenshots/reader-dark.png) |
| 阅读排版与主题面板 | [查看](screenshots/reader-settings-light.png) | [查看](screenshots/reader-settings-dark.png) |
| 漫画单图错误与就地重试 | [查看](screenshots/manga-image-error-light.png) | [查看](screenshots/manga-image-error-dark.png) |
| 听书的章节、播放与正文 | [查看](screenshots/audiobook-light.png) | [查看](screenshots/audiobook-dark.png) |
| 听书的语速、音量与声音入口 | [查看](screenshots/audiobook-settings-light.png) | [查看](screenshots/audiobook-settings-dark.png) |

漫画截图刻意使用加载失败状态验证错误恢复，未通过测试图片推断长漫画解码或真机帧率。听书截图使用测试引擎，不代表已验收设备音色和实际发声。

## 连接、账号与偏好

| 场景 | 截图 | 范围说明 |
| --- | --- | --- |
| 服务连接 | [浅色](screenshots/backend-sheet-light.png) | 独立完整页面，地址与连接 Token 表单 |
| 账号入口 | [浅色](screenshots/account-sheet-light.png) | 独立完整页面 |
| 登录失效 | [浅色](screenshots/login-required-light.png) | 恢复账号访问的入口 |
| 密码登录 | [浅色](screenshots/login-form-light.png) | 登录表单 |
| 键盘避让状态 | [浅色](screenshots/login-keyboard-light.png) | 测试注入底部300dp键盘边距，没有绘制或启动 Android 输入法 |
| 连接中断 | [浅色](screenshots/connection-interrupted-light.png) | 保留书库内容并给出恢复入口 |
| 外观偏好 | [320dp / 200%文字](screenshots/appearance-320-large-text.png) | 大字下主题选择与滚动布局 |
| 账号安全 | [320dp浅色](screenshots/security-320-light.png)、[320dp深色](screenshots/security-320-dark.png) | 180%文字，分区列表与安全操作 |
| 两步验证设置 | [320dp深色](screenshots/security-2fa-320-dark.png) | 180%文字，完整页面与就地说明 |
| 书源管理 | [浅色](screenshots/sources-light.png)、[深色](screenshots/sources-dark.png) | 真实权限驱动的来源列表 |

文件名中的 `store` 沿用测试产物命名，当前界面入口为“发现”；`account-sheet` 和 `backend-sheet` 同样为历史文件名，图中已是完整页面路由，不代表继续使用复杂弹层。

## 复现

在项目根目录执行：

```powershell
flutter test --no-pub --dart-define=QINGJUAN_CAPTURE_MOBILE_UI=true
```

输出位于 `build/mobile-ui-preview/`。主流程见 [mobile_app_test.dart](../../test/mobile/mobile_app_test.dart)，安全流程见 [mobile_account_test.dart](../../test/mobile/mobile_account_test.dart)，作品与阅读见 [book_detail_page_test.dart](../../test/features/detail/book_detail_page_test.dart)、[reader_page_test.dart](../../test/features/reader/reader_page_test.dart) 和 [audiobook_page_test.dart](../../test/features/audiobook/audiobook_page_test.dart)。截图导出不会替代这些测试中的行为断言。

本目录保留最终产物；[before/](before/) 为重构前的早期证据，不计入47张最终截图。完整验收边界见 [验证报告](validation.md)。
