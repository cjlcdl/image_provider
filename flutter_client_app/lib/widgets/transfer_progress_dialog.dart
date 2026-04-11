import 'package:flutter/material.dart';

class TransferProgressDialog extends StatelessWidget {
  const TransferProgressDialog({
    super.key,
    required this.title,
    required this.fileName,
    this.summaryText,
    this.detailText,
    required this.transferredBytes,
    required this.totalBytes,
    required this.active,
    required this.onCancel,
  });

  final String title;
  final String fileName;
  final String? summaryText;
  final String? detailText;
  final int transferredBytes;
  final int? totalBytes;
  final bool active;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final progressValue = totalBytes == null || totalBytes == 0
        ? null
        : transferredBytes / totalBytes!;
    final progressText = totalBytes == null || totalBytes == 0
        ? '已传输 ${_formatBytes(transferredBytes)}'
        : '${_formatBytes(transferredBytes)} / ${_formatBytes(totalBytes!)}';
    final percentText = progressValue == null
        ? '处理中'
        : '${(progressValue * 100).clamp(0, 100).toStringAsFixed(1)}%';

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (summaryText != null && summaryText!.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                summaryText!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            LinearProgressIndicator(value: progressValue),
            const SizedBox(height: 12),
            Text(progressText),
            const SizedBox(height: 4),
            Text(percentText, style: Theme.of(context).textTheme.bodySmall),
            if (detailText != null && detailText!.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text(detailText!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: active ? onCancel : null,
          child: const Text('取消'),
        ),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
