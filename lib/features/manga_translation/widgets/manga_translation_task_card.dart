import 'package:fluent_ui/fluent_ui.dart';

import '../manga_translation_controller.dart';
import '../manga_translation_models.dart';

class MangaTranslationTaskCard extends StatelessWidget {
  const MangaTranslationTaskCard({
    required this.controller,
    required this.outputController,
    required this.onBrowseOutput,
    required this.onOpenOutput,
    super.key,
  });

  final MangaTranslationController controller;
  final TextEditingController outputController;
  final VoidCallback onBrowseOutput;
  final VoidCallback onOpenOutput;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final busy = controller.isBusy;
    return Card(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('翻译任务', style: theme.typography.bodyStrong),
          const SizedBox(height: 12),
          const Text('输出目录：'),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Expanded(
                child: TextBox(
                  key: const ValueKey('manga-output-directory'),
                  controller: outputController,
                  enabled: !busy,
                  placeholder: '选择或输入输出文件夹…',
                  onChanged: controller.setOutputDirectory,
                ),
              ),
              const SizedBox(width: 8),
              Button(
                key: const ValueKey('browse-manga-output'),
                onPressed: busy ? null : onBrowseOutput,
                child: const Text('浏览…'),
              ),
              const SizedBox(width: 8),
              Button(
                key: const ValueKey('open-manga-output'),
                onPressed: onOpenOutput,
                child: const Text('打开'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '开始任务前请选择翻译流程模式。',
            style: theme.typography.caption?.copyWith(
              color: theme.resources.textFillColorSecondary,
            ),
          ),
          const SizedBox(height: 8),
          const Text('翻译流程模式：'),
          const SizedBox(height: 6),
          ComboBox<MangaWorkflowMode>(
            key: const ValueKey('manga-workflow-mode'),
            isExpanded: true,
            value: controller.mode,
            items: <ComboBoxItem<MangaWorkflowMode>>[
              for (final mode in MangaWorkflowMode.values)
                ComboBoxItem<MangaWorkflowMode>(
                  value: mode,
                  child: Text(mode.label),
                ),
            ],
            onChanged: busy
                ? null
                : (value) {
                    if (value != null) controller.selectMode(value);
                  },
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 44,
            child: FilledButton(
              key: const ValueKey('manga-translation-start-stop'),
              onPressed: switch (controller.runState) {
                MangaTranslationRunState.stopping => null,
                MangaTranslationRunState.importing ||
                MangaTranslationRunState.starting ||
                MangaTranslationRunState.running =>
                  controller.stop,
                _ => controller.run,
              },
              child: Text(
                switch (controller.runState) {
                  MangaTranslationRunState.importing => '停止导入',
                  MangaTranslationRunState.starting => '正在启动...',
                  MangaTranslationRunState.running => '停止翻译',
                  MangaTranslationRunState.stopping => '停止中...',
                  _ => controller.mode.startLabel,
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MangaTranslationProgressCard extends StatelessWidget {
  const MangaTranslationProgressCard({required this.controller, super.key});

  final MangaTranslationController controller;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final percentage = controller.total == 0
        ? 0
        : ((controller.current / controller.total) * 100).floor();
    return Card(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  controller.message,
                  key: const ValueKey('manga-progress-message'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.body,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${controller.current}/${controller.total} ($percentage%)',
                key: const ValueKey('manga-progress-count'),
                style: theme.typography.caption?.copyWith(
                  color: theme.resources.textFillColorSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ProgressBar(value: controller.progress, strokeWidth: 6),
        ],
      ),
    );
  }
}
