import '../models/book.dart';
import 'api_exception.dart';

class ReadingProgressConflict extends ApiException {
  const ReadingProgressConflict(
      {required this.current,
      this.code = 'reading_progress_conflict',
      String message = '其他设备已更新阅读进度，请选择保留哪个位置'})
      : super(message, statusCode: 409);

  final ReadingProgress current;
  final String code;
}
