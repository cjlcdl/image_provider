import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 存储空间使用比例饼图 + 图例。
///
/// 数据来源：[segments] 是一个列表，每项包含标签、字节数和颜色。
class StorageChart extends StatelessWidget {
  const StorageChart({
    super.key,
    required this.segments,
    this.emptyMessage = '暂无数据',
    this.pieSize = 100,
  });

  final String emptyMessage;
  final List<StorageSegment> segments;
  final double pieSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalBytes =
        segments.fold<int>(0, (sum, seg) => sum + seg.bytes);
    final hasData = totalBytes > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: pieSize,
              height: pieSize,
              child: hasData
                  ? CustomPaint(
                      painter: _StoragePiePainter(
                        segments: segments,
                        totalBytes: totalBytes,
                      ),
                    )
                  : Center(
                      child: Text(
                        emptyMessage,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: segments.map((seg) {
                  final percentage = totalBytes > 0
                      ? (seg.bytes / totalBytes * 100)
                      : 0.0;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: seg.color,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            seg.label,
                            style: theme.textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${percentage.toStringAsFixed(1)}%',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(growable: false),
              ),
            ),
          ],
        ),
        if (hasData && totalBytes > 0) ...[
          const SizedBox(height: 12),
          Text(
            '总计: ${_formatBytes(totalBytes)}',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// 存储段数据。
class StorageSegment {
  const StorageSegment({
    required this.label,
    required this.bytes,
    required this.color,
  });

  final String label;
  final int bytes;
  final Color color;
}

class _StoragePiePainter extends CustomPainter {
  _StoragePiePainter({required this.segments, required this.totalBytes});

  final List<StorageSegment> segments;
  final int totalBytes;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 2;

    var startAngle = -math.pi / 2; // 从顶部开始
    for (final seg in segments) {
      if (seg.bytes <= 0) continue;
      final sweepAngle = (seg.bytes / totalBytes) * 2 * math.pi;
      final paint = Paint()
        ..color = seg.color
        ..style = PaintingStyle.fill;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        true,
        paint,
      );
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _StoragePiePainter oldDelegate) {
    return segments != oldDelegate.segments || totalBytes != oldDelegate.totalBytes;
  }
}
