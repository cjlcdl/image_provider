import 'dart:async';
import 'dart:io';

/// 上传队列管理器 — 支持多文件顺序上传。
///
/// 使用方式：
/// ```dart
/// final queue = UploadQueueManager();
/// queue.addAll(files);
/// queue.onProgress = (index, total, fileName) { ... };
/// queue.onItemComplete = (index, success) { ... };
/// await queue.start(uploadFn);
/// ```
class UploadQueueManager {
  final List<_QueuedFile> _queue = <_QueuedFile>[];
  int _currentIndex = -1;
  bool _cancelled = false;

  /// 队列中的文件数量。
  int get length => _queue.length;

  /// 当前正在处理的索引（-1 表示尚未开始）。
  int get currentIndex => _currentIndex;

  /// 是否已取消。
  bool get isCancelled => _cancelled;

  /// 是否全部完成。
  bool get isComplete => _currentIndex >= _queue.length;

  /// 进度回调：(当前索引, 总数, 文件名)。
  void Function(int index, int total, String fileName)? onProgress;

  /// 单项完成回调：(索引, 是否成功, 错误信息)。
  void Function(int index, bool success, String? error)? onItemComplete;

  /// 添加单个文件到队列。
  void add(File file) {
    _queue.add(_QueuedFile(file: file));
  }

  /// 批量添加文件。
  void addAll(List<File> files) {
    for (final file in files) {
      _queue.add(_QueuedFile(file: file));
    }
  }

  /// 取消队列。
  void cancel() {
    _cancelled = true;
  }

  /// 启动顺序上传。
  ///
  /// [uploadFn] 签名: `Future<String?> Function(File file)` —
  /// 返回 null 表示成功，返回错误信息字符串表示失败。
  Future<UploadQueueResult> start(
    Future<String?> Function(File file) uploadFn,
  ) async {
    _cancelled = false;
    var succeeded = 0;
    var failed = 0;
    final failures = <String, String>{};

    for (var i = 0; i < _queue.length; i++) {
      if (_cancelled) break;

      _currentIndex = i;
      final item = _queue[i];
      onProgress?.call(i, _queue.length, item.fileName);

      try {
        final error = await uploadFn(item.file);
        if (error == null) {
          item.success = true;
          succeeded++;
          onItemComplete?.call(i, true, null);
        } else {
          item.success = false;
          item.error = error;
          failed++;
          failures[item.fileName] = error;
          onItemComplete?.call(i, false, error);
        }
      } catch (e) {
        item.success = false;
        item.error = e.toString();
        failed++;
        failures[item.fileName] = e.toString();
        onItemComplete?.call(i, false, e.toString());
      }
    }

    _currentIndex = _queue.length;
    return UploadQueueResult(
      succeeded: succeeded,
      failed: failed,
      total: _queue.length,
      failures: failures,
      cancelled: _cancelled,
    );
  }

  /// 清空队列。
  void clear() {
    _queue.clear();
    _currentIndex = -1;
    _cancelled = false;
  }
}

class _QueuedFile {
  _QueuedFile({required this.file});

  final File file;
  bool success = false;
  String? error;

  String get fileName => file.path.split(RegExp(r'[\\/]')).last;
}

/// 上传队列执行结果。
class UploadQueueResult {
  const UploadQueueResult({
    required this.succeeded,
    required this.failed,
    required this.total,
    required this.failures,
    required this.cancelled,
  });

  final int succeeded;
  final int failed;
  final int total;
  final Map<String, String> failures;
  final bool cancelled;

  bool get allSuccess => failed == 0 && !cancelled;
}
