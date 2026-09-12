import 'dart:async';
import 'package:flutter/foundation.dart';

class AudiobookSleepTimer extends ChangeNotifier {
  AudiobookSleepTimer({required this.onElapsed, DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final Future<void> Function() onElapsed;
  final DateTime Function() _now;
  Timer? _timer;
  DateTime? _deadline;
  DateTime? get deadline => _deadline;
  String? error;
  bool _disposed = false;
  int _generation = 0;
  Duration? get remaining {
    final deadline = _deadline;
    if (deadline == null) return null;
    final value = deadline.difference(_now());
    return value.isNegative ? Duration.zero : value;
  }

  void set(Duration? duration) {
    if (_disposed) return;
    if (duration != null &&
        (duration < const Duration(seconds: 1) ||
            duration > const Duration(hours: 12))) {
      throw ArgumentError('定时停止范围为 1 秒至 12 小时');
    }
    _generation++;
    error = null;
    _timer?.cancel();
    _deadline = duration == null ? null : _now().add(duration);
    if (duration != null) {
      final generation = _generation;
      _timer = Timer(duration, () => unawaited(_expire(generation)));
    }
    notifyListeners();
  }

  Future<void> checkOnResume() async {
    if (_deadline != null && remaining == Duration.zero) {
      await _expire(_generation);
    }
  }

  Future<void> _expire(int generation) async {
    if (_disposed || generation != _generation || _deadline == null) return;
    _deadline = null;
    _timer?.cancel();
    _timer = null;
    _generation++;
    notifyListeners();
    try {
      await onElapsed();
    } catch (_) {
      if (!_disposed) {
        error = '定时停止未能完成，请手动停止听书';
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    super.dispose();
  }
}
