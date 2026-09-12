import 'package:flutter/material.dart';
import 'offline_library_page.dart';
import 'offline_reading_controller.dart';

class OfflineLibraryEntry extends StatelessWidget {
  const OfflineLibraryEntry({required this.controller, super.key});
  final OfflineReadingController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => TextButton.icon(
          key: const ValueKey('offline-library-entry'),
          onPressed: controller.identity == null
              ? null
              : () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => OfflineLibraryPage(controller: controller))),
          icon: const Icon(Icons.offline_pin_outlined),
          label: Text(controller.identity == null
              ? '离线书库（尚未保存）'
              : '离线书库 · ${controller.books.length} 本')));
}
