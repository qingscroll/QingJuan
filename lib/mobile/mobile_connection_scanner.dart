import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/backend/backend_connection_link.dart';

class MobileConnectionScanner extends StatefulWidget {
  const MobileConnectionScanner({super.key});

  @override
  State<MobileConnectionScanner> createState() =>
      _MobileConnectionScannerState();
}

class _MobileConnectionScannerState extends State<MobileConnectionScanner> {
  bool _completed = false;
  String? _error;

  void _detected(BarcodeCapture capture) {
    if (_completed) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      try {
        final link = BackendConnectionLink.parse(value);
        _completed = true;
        Navigator.of(context).pop(link);
        return;
      } on FormatException {
        if (_error == null) {
          setState(() => _error = '这不是青卷连接二维码，请扫描 PC 设置中的二维码。');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('扫描连接二维码')),
        body: SafeArea(
            child: Column(children: [
          Expanded(
              child: MobileScanner(
            onDetect: _detected,
            errorBuilder: (context, error) => const Center(
                child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('无法使用相机。请在系统设置中允许青卷使用相机，或返回并选择“粘贴连接链接”。',
                  textAlign: TextAlign.center),
            )),
          )),
          Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                _error ?? '请将 PC“设置 → 手机连接”中的二维码放入取景框。',
                textAlign: TextAlign.center,
              )),
        ])),
      );
}
