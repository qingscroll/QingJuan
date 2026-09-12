import 'package:fluent_ui/fluent_ui.dart';
import 'audiobook_sleep_timer.dart';

class AudiobookTimerControl extends StatelessWidget {
  const AudiobookTimerControl({required this.timer, super.key});
  final AudiobookSleepTimer timer;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: timer,
        builder: (context, _) {
          final deadline = timer.deadline?.toLocal();
          final label = deadline == null
              ? '定时停止：未开启'
              : '将在 ${deadline.hour.toString().padLeft(2, '0')}:${deadline.minute.toString().padLeft(2, '0')} 停止';
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                const SizedBox(height: 8),
                ComboBox<int>(
                  placeholder: const Text('设置定时停止'),
                  items: [
                    const ComboBoxItem(value: 0, child: Text('关闭定时')),
                    for (final minutes in [5, 15, 30, 60])
                      ComboBoxItem(
                          value: minutes, child: Text('$minutes 分钟后停止')),
                  ],
                  onChanged: (minutes) {
                    if (minutes != null) {
                      timer.set(
                          minutes == 0 ? null : Duration(minutes: minutes));
                    }
                  },
                ),
                if (timer.error != null) Text(timer.error!),
              ]);
        },
      );
}
