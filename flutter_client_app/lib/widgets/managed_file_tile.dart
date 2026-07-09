import 'dart:math';

import 'package:flutter/material.dart';
import 'package:courage_storage/models/managed_file.dart';

class ManagedFileTile extends StatelessWidget {
  const ManagedFileTile({
    super.key,
    required this.file,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final ManagedFile file;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  static String formatSize(int bytes) {
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

  static String compactDisplayName(String value) {
    final normalized = value.trim().isEmpty ? '(unnamed)' : value.trim();
    if (normalized.length <= 30) {
      return normalized;
    }

    final dotIndex = normalized.lastIndexOf('.');
    if (dotIndex <= 0 || dotIndex == normalized.length - 1) {
      return '${normalized.substring(0, 14)}...${normalized.substring(normalized.length - 6)}';
    }

    final extension = normalized.substring(dotIndex);
    final prefixLength = max(8, min(22, 30 - extension.length - 3));
    final prefix = normalized.substring(
      0,
      prefixLength.clamp(0, normalized.length),
    );
    return '$prefix...$extension';
  }

  static String formatUploadedAt(String? uploadedAt) {
    if (uploadedAt == null || uploadedAt.trim().isEmpty) {
      return '上传时间未知';
    }

    final value = uploadedAt.trim().replaceFirst('T', ' ');
    if (value.length <= 19) {
      return value;
    }
    return value.substring(0, 19);
  }

  static IconData iconForFile(ManagedFile file) {
    final mimeType = file.mimeType.toLowerCase();
    final fileName =
        (file.indexedName.isEmpty ? file.systemName : file.indexedName)
            .toLowerCase();
    if (mimeType.startsWith('image/')) {
      return Icons.image_outlined;
    }
    if (mimeType.startsWith('video/')) {
      return Icons.movie_outlined;
    }
    if (mimeType.startsWith('audio/')) {
      return Icons.audio_file_outlined;
    }
    if (mimeType.contains('pdf')) {
      return Icons.picture_as_pdf_outlined;
    }
    if (mimeType.contains('zip') ||
        mimeType.contains('rar') ||
        mimeType.contains('7z') ||
        fileName.endsWith('.zip') ||
        fileName.endsWith('.rar') ||
        fileName.endsWith('.7z') ||
        fileName.endsWith('.tar') ||
        fileName.endsWith('.gz')) {
      return Icons.folder_zip_outlined;
    }
    if (fileName.endsWith('.apk') ||
        fileName.endsWith('.exe') ||
        fileName.endsWith('.msi') ||
        fileName.endsWith('.dmg')) {
      return Icons.install_desktop_outlined;
    }
    if (fileName.endsWith('.txt') ||
        fileName.endsWith('.md') ||
        mimeType.startsWith('text/')) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  /// 返回基于扩展名的文件类型标签（如"zip文件""apk文件"）。
  static String fileTypeLabel(ManagedFile file) {
    final fileName =
        (file.indexedName.isEmpty ? file.systemName : file.indexedName)
            .toLowerCase();
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex > 0 && dotIndex < fileName.length - 1) {
      final ext = fileName.substring(dotIndex + 1);
      // 特殊处理常见压缩格式
      return "${ext.toUpperCase()}文件";
    }
    final mimeType = file.mimeType.toLowerCase();
    if (mimeType.startsWith('image/')) return '图片文件';
    if (mimeType.startsWith('video/')) return '视频文件';
    if (mimeType.startsWith('audio/')) return '音频文件';
    return '文件';
  }

  @override
  Widget build(BuildContext context) {
    final displayName = file.indexedName.isEmpty ? file.systemName : file.indexedName;
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
      fontSize: 14,
      height: 1.15,
    );
    final metaStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: const Color(0xFF5F5F5F),
      fontSize: 11,
      height: 1.2,
    );

    return Material(
      color: selected ? const Color(0xFFF3F3F3) : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  iconForFile(file),
                  size: 20,
                  color: const Color(0xFF6A625A),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        if (file.isTemporary)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFDE8B7),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              '临时',
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.1,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF7B5A00),
                              ),
                            ),
                          ),
                        Text(
                          formatUploadedAt(file.uploadedAt),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle?.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 10,
                          ),
                        ),
                        Text(
                          fileTypeLabel(file),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  selected ? 
                      Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF3A3A3A),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            '已选择',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          )) : 
                      Text(
                        formatSize(file.size),
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          fontSize: 11,
                        ),
                      )
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
