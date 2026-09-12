import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:qingjuan/core/models/tts_voice.dart';
import 'package:qingjuan/features/audiobook/flutter_tts_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('selected voice is applied instead of the language default', () async {
    final plugin = _FakeFlutterTts();
    const voice = TtsVoice(
      name: 'Microsoft Xiaoxiao',
      locale: 'zh-CN',
      gender: 'female',
      identifier: 'voice-xiaoxiao',
    );
    final engine = FlutterTtsEngine(voice: voice, flutterTts: plugin);

    await engine.initialize('en-US');

    expect(plugin.selectedVoice, voice.pluginValue);
    expect(plugin.language, isNull);
  });

  test('system default voice follows the book language', () async {
    final plugin = _FakeFlutterTts();
    final engine = FlutterTtsEngine(flutterTts: plugin);

    await engine.initialize('ja-JP');

    expect(plugin.language, 'ja-JP');
    expect(plugin.selectedVoice, isNull);
  });

  test('speech waits for the device completion event without native await',
      () async {
    final plugin = _FakeFlutterTts();
    final engine = FlutterTtsEngine(flutterTts: plugin);
    await engine.initialize('zh-CN');

    var completed = false;
    final speaking = engine.speak('逐段朗读').then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);

    expect(plugin.awaitCompletion, isFalse);
    expect(plugin.spoken, <String>['逐段朗读']);
    expect(completed, isFalse);

    plugin.completeSpeech();
    await speaking;
    expect(completed, isTrue);
  });

  test('paused speech remains pending and resumes using the original utterance',
      () async {
    final plugin = _FakeFlutterTts();
    final engine = FlutterTtsEngine(flutterTts: plugin);
    await engine.initialize('zh-CN');
    var finished = false;
    final speaking = engine.speak('完整的原始片段').then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    await engine.pause();
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    await engine.resume();
    expect(plugin.spoken, ['完整的原始片段', '完整的原始片段']);
    plugin.completeSpeech();
    await speaking;
    expect(finished, isTrue);
  });
}

class _FakeFlutterTts extends FlutterTts {
  String? language;
  Map<String, String>? selectedVoice;
  double? pitch;
  bool? awaitCompletion;
  final List<String> spoken = <String>[];
  void Function()? _completionHandler;
  void Function()? _cancelHandler;

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async {
    this.awaitCompletion = awaitCompletion;
    return 1;
  }

  @override
  void setCompletionHandler(void Function() callback) {
    _completionHandler = callback;
  }

  @override
  void setCancelHandler(void Function() callback) {
    _cancelHandler = callback;
  }

  @override
  void setErrorHandler(void Function(dynamic) handler) {}

  @override
  Future<dynamic> setLanguage(String language) async {
    this.language = language;
    return 1;
  }

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    selectedVoice = voice;
    return 1;
  }

  @override
  Future<dynamic> setPitch(double pitch) async {
    this.pitch = pitch;
    return 1;
  }

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spoken.add(text);
    return 1;
  }

  @override
  Future<dynamic> stop() async {
    _cancelHandler?.call();
    return 1;
  }

  @override
  Future<dynamic> pause() async {
    _cancelHandler?.call();
    return 1;
  }

  void completeSpeech() => _completionHandler?.call();
}
