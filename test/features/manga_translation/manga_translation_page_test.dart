import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/manga_translation/manga_bookshelf_import.dart';
import 'package:qingjuan/features/manga_translation/manga_translation_controller.dart';
import 'package:qingjuan/features/manga_translation/manga_translation_models.dart';
import 'package:qingjuan/features/manga_translation/manga_translation_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('page mirrors mode title, hint, controls, and progress footer',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      preferences: preferences,
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async =>
          throw UnimplementedError(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(_pageHarness(controller));
    await tester.pumpAndSettle();

    expect(find.text('正常翻译流程'), findsWidgets);
    expect(find.textContaining('检测、OCR、翻译和渲染'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-manga-files')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-manga-folder')), findsOneWidget);
    expect(find.byKey(const ValueKey('clear-manga-files')), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-translation-empty-files')),
        findsOneWidget);
    expect(find.text('输出目录：'), findsOneWidget);
    expect(find.text('翻译流程模式：'), findsOneWidget);
    expect(find.text('开始翻译'), findsOneWidget);
    expect(find.text('0/0 (0%)'), findsOneWidget);

    await controller.selectMode(MangaWorkflowMode.inpaintOnly);
    await tester.pump();

    expect(find.text('仅修复'), findsWidgets);
    expect(find.textContaining('输出无字干净图'), findsOneWidget);
    expect(find.text('开始修复'), findsOneWidget);
  });

  testWidgets('bookshelf picker lists only manga and queues the selection',
      (tester) async {
    MangaBookshelfImportRequest? capturedRequest;
    final preferences = await SharedPreferences.getInstance();
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      preferences: preferences,
      loadBookshelfBooks: () async => <Book>[
        _book(id: 'novel-1', title: '不应显示的小说', kind: '长小说'),
        _book(id: 'manga-2', title: '乙漫画'),
        _book(id: 'manga-1', title: '甲漫画'),
      ],
      importBookshelfBook: (
        request, {
        onProgress,
        abortTrigger,
      }) async {
        capturedRequest = request;
        onProgress?.call(
          const MangaBookshelfImportProgress(
            message: '正在导入 1/1 页',
            completedPages: 1,
            totalPages: 1,
          ),
        );
        return MangaBookshelfImportResult(
          bookId: request.bookId,
          bookTitle: request.bookTitle,
          sourceRoot: '',
          filePaths: const <String>[],
          chapterCount: 1,
        );
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      _pageHarness(
        controller,
        workspaceIdentity: 'https://backend.example:user-7',
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('select-manga-bookshelf-book')),
      findsOneWidget,
    );
    expect(find.text('从书架选择'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('select-manga-bookshelf-book')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('从书架选择漫画'), findsOneWidget);
    expect(find.text('甲漫画'), findsOneWidget);
    expect(find.text('乙漫画'), findsOneWidget);
    expect(find.text('不应显示的小说'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('manga-bookshelf-book-manga-1')),
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(capturedRequest, isNotNull);
    expect(capturedRequest!.bookId, 'manga-1');
    expect(
      capturedRequest!.workspaceIdentity,
      'https://backend.example:user-7',
    );
  });
}

Widget _pageHarness(
  MangaTranslationController controller, {
  String? workspaceIdentity,
}) {
  return FluentApp(
    theme: buildQingJuanTheme(
      Brightness.light,
      platform: TargetPlatform.windows,
    ),
    home: MediaQuery(
      data: const MediaQueryData(size: Size(1200, 900)),
      child: SizedBox(
        width: 1200,
        height: 900,
        child: MangaTranslationPage(
          controller: controller,
          workspaceIdentity: workspaceIdentity,
        ),
      ),
    ),
  );
}

Book _book({
  required String id,
  required String title,
  String kind = '漫画',
}) {
  return Book(
    id: id,
    title: title,
    sourceUrl: 'https://example.com/$id',
    kind: kind,
    language: '日文',
    status: '已导入',
    chapterCount: 2,
    translated: false,
    synopsis: '',
    lastReadChapterIndex: 1,
  );
}
