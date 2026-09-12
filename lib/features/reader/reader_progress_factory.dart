import '../../core/api/api_client.dart';
import '../../core/models/book.dart';
import 'reader_progress_store.dart';
import 'reader_progress_writer.dart';

ReaderProgressWriter createReaderProgressWriter(
    {required ApiClient api,
    required BookDetail detail,
    required bool versioning,
    required String instanceId,
    required String ownerId}) {
  final supported = versioning && detail.progress.revision != null;
  return ReaderProgressWriter(api, detail.book.id,
      versioning: supported,
      initialProgress: detail.progress,
      store: supported
          ? FileReaderProgressStore(
              instanceId: instanceId, ownerId: ownerId, bookId: detail.book.id)
          : null);
}
