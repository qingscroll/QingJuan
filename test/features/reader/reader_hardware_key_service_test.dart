import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/features/reader/reader_hardware_key_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a new owner survives a delayed detach from the previous page',
    () async {
      const channel = MethodChannel('qingjuan/reader-owner-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final disableStarted = Completer<void>();
      final releaseDisable = Completer<void>();
      final enabledStates = <bool>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'setVolumeKeyEnabled') return null;
        final enabled = call.arguments as bool;
        enabledStates.add(enabled);
        if (!enabled && !disableStarted.isCompleted) {
          disableStarted.complete();
          await releaseDisable.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final oldKeys = <ReaderHardwareKey>[];
      final newKeys = <ReaderHardwareKey>[];
      final oldService = ReaderHardwareKeyService(channel: channel);
      final newService = ReaderHardwareKeyService(channel: channel);
      await oldService.attach(enabled: true, onKey: oldKeys.add);

      final oldDetach = oldService.detach();
      await disableStarted.future;
      final newAttach = newService.attach(enabled: true, onKey: newKeys.add);

      await _sendVolumeKey(channel, 'down');
      expect(oldKeys, isEmpty);
      expect(newKeys, <ReaderHardwareKey>[ReaderHardwareKey.down]);

      releaseDisable.complete();
      await Future.wait(<Future<void>>[oldDetach, newAttach]);

      expect(enabledStates, <bool>[true, false, true]);
      await _sendVolumeKey(channel, 'up');
      expect(oldKeys, isEmpty);
      expect(newKeys, <ReaderHardwareKey>[
        ReaderHardwareKey.down,
        ReaderHardwareKey.up,
      ]);

      await newService.detach();
    },
  );
}

Future<void> _sendVolumeKey(MethodChannel channel, String direction) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(MethodCall('volumeKey', direction)),
    null,
  );
}
