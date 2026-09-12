import 'package:flutter/material.dart';
import '../../core/models/book.dart';
import 'offline_reading_controller.dart';
import 'offline_save_page.dart';

class OfflineSaveButton extends StatelessWidget {
  const OfflineSaveButton(
      {required this.controller, required this.detail, super.key});
  final OfflineReadingController controller;
  final BookDetail detail;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
      key: const ValueKey('offline-save-button'),
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) =>
              OfflineSavePage(controller: controller, detail: detail))),
      icon: const Icon(Icons.download_for_offline_outlined),
      label: const Text('保存到本机'));
}
