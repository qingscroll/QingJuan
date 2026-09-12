import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../core/models/book_metadata.dart';
import 'library_controller.dart';

class LibraryOrganizationControls extends f.StatelessWidget {
  const LibraryOrganizationControls(
      {required this.controller, this.mobile = false, super.key});
  final LibraryController controller;
  final bool mobile;

  f.Widget _select(String label, String value, Map<String, String> values,
      f.ValueChanged<String> changed) {
    final control = mobile
        ? m.DropdownButtonFormField<String>(
            key: f.ValueKey('library-filter-$label-$value'),
            initialValue: value,
            isExpanded: true,
            decoration: m.InputDecoration(
                labelText: label, border: const m.OutlineInputBorder()),
            items: [
              for (final entry in values.entries)
                m.DropdownMenuItem(
                    value: entry.key,
                    child:
                        m.Text(entry.value, overflow: m.TextOverflow.ellipsis))
            ],
            onChanged: (value) {
              if (value != null) changed(value);
            })
        : f.InfoLabel(
            label: label,
            child: f.ComboBox<String>(
                value: value,
                isExpanded: true,
                items: [
                  for (final entry in values.entries)
                    f.ComboBoxItem(
                        value: entry.key,
                        child: f.Text(entry.value,
                            overflow: f.TextOverflow.ellipsis))
                ],
                onChanged: (value) {
                  if (value != null) changed(value);
                }));
    return f.SizedBox(width: mobile ? double.infinity : 175, child: control);
  }

  @override
  f.Widget build(f.BuildContext context) => f.AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final groups = {
          '': '全部分组',
          'g:': '未分组',
          for (final group in controller.groups) 'g:$group': group
        };
        final tags = {
          '': '全部标签',
          for (final tag in controller.tags) 't:$tag': tag
        };
        if (controller.groupFilter != null) {
          groups['g:${controller.groupFilter}'] =
              controller.groupFilter!.isEmpty ? '未分组' : controller.groupFilter!;
        }
        if (controller.tagFilter != null) {
          tags['t:${controller.tagFilter}'] = controller.tagFilter!;
        }
        void change(
                {String? group,
                String? tag,
                String? state,
                bool? pinned,
                String? changed}) =>
            controller.setOrganization(
                group: changed == 'group' ? group : controller.groupFilter,
                tag: changed == 'tag' ? tag : controller.tagFilter,
                readingState:
                    changed == 'state' ? state : controller.readingStateFilter,
                pinned: pinned ?? controller.pinnedOnly,
                newUpdates: controller.onlyNewUpdates);
        final controls = <f.Widget>[
          _select(
              '分组',
              controller.groupFilter == null
                  ? ''
                  : 'g:${controller.groupFilter}',
              groups,
              (value) => change(
                  group: value.isEmpty ? null : value.substring(2),
                  changed: 'group')),
          _select(
              '标签',
              controller.tagFilter == null ? '' : 't:${controller.tagFilter}',
              tags,
              (value) => change(
                  tag: value.isEmpty ? null : value.substring(2),
                  changed: 'tag')),
          _select(
              '阅读状态',
              controller.readingStateFilter ?? '',
              {'': '全部阅读状态', ...readingStateLabels},
              (value) => change(
                  state: value.isEmpty ? null : value, changed: 'state')),
          _select(
              '排序',
              controller.sort.name,
              {for (final value in LibrarySort.values) value.name: value.label},
              (value) => controller.setSort(LibrarySort.values.byName(value))),
          if (mobile)
            m.CheckboxListTile(
                contentPadding: f.EdgeInsets.zero,
                title: const m.Text('只看置顶'),
                value: controller.pinnedOnly,
                onChanged: (value) => change(pinned: value ?? false))
          else
            f.Checkbox(
                content: const f.Text('只看置顶'),
                checked: controller.pinnedOnly,
                onChanged: (value) => change(pinned: value ?? false)),
          if (controller.hasOrganizationFilters)
            if (mobile)
              m.TextButton(
                  onPressed: () => controller.setOrganization(),
                  child: const m.Text('清除筛选'))
            else
              f.Button(
                  onPressed: () => controller.setOrganization(),
                  child: const f.Text('清除筛选')),
          if (controller.serials.enabled)
            if (mobile)
              m.CheckboxListTile(
                  contentPadding: f.EdgeInsets.zero,
                  title: const m.Text('只看更新'),
                  value: controller.onlyNewUpdates,
                  onChanged: (value) =>
                      controller.setOnlyNewUpdates(value ?? false))
            else
              f.Checkbox(
                  content: const f.Text('只看更新'),
                  checked: controller.onlyNewUpdates,
                  onChanged: (value) =>
                      controller.setOnlyNewUpdates(value ?? false)),
        ];
        return mobile
            ? f.Column(
                crossAxisAlignment: f.CrossAxisAlignment.stretch,
                children: [
                    for (final control in controls)
                      f.Padding(
                          padding: const f.EdgeInsets.only(bottom: 12),
                          child: control)
                  ])
            : f.Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: f.WrapCrossAlignment.end,
                children: controls);
      });
}
