import 'dart:async';
import 'dart:io';

import 'package:courage_storage/data/global.dart';
import 'package:courage_storage/controllers/file_manager_controller.dart';
import 'package:courage_storage/models/base_url_preset.dart';
import 'package:courage_storage/models/indexed_folder.dart';
import 'package:courage_storage/models/managed_file.dart';
import 'package:courage_storage/pages/trash_page.dart';
import 'package:courage_storage/services/image_bed_client.dart';
import 'package:courage_storage/services/shared_file_handler.dart';
import 'package:courage_storage/services/notification_service.dart';
import 'package:courage_storage/services/storage_permission_service.dart';
import 'package:courage_storage/widgets/managed_file_tile.dart';
import 'package:courage_storage/widgets/panel_card.dart';
import 'package:courage_storage/widgets/transfer_progress_dialog.dart';
import 'package:courage_storage/widgets/storage_chart.dart';
import 'package:courage_storage/widgets/detail_table.dart';
import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class FileManagerPage extends StatefulWidget {
  const FileManagerPage({super.key, this.autoLoad = true, this.controller});

  final bool autoLoad;
  final FileManagerController? controller;

  @override
  State<FileManagerPage> createState() => _FileManagerPageState();
}

class _FileManagerPageState extends State<FileManagerPage> {
  int _manualPreviewThresholdBytes = 2097152; // 2 MB 默认

  late final FileManagerController _controller;
  late final bool _ownsController;
  late final TextEditingController _keywordController;
  late final TextEditingController _pageController;
  late final TextEditingController _pageSizeController;

  int _currentIndex = 0;
  bool _batchMode = false;
  bool _draggingUpload = false;
  bool _wasDetailView = false;
  String _storageFilter = '';
  String? _dropTargetFolderId;
  bool _contextMenuOpen = false;
  StreamSubscription<List<String>>? _sharedFileSubscription;

  String _normalizedFileLabel(ManagedFile file) {
    final value =
        (file.indexedName.isEmpty ? file.systemName : file.indexedName).trim();
    return value.isEmpty ? '(unnamed)' : value;
  }

  int _compareCaseInsensitive(String left, String right) {
    return left.toLowerCase().compareTo(right.toLowerCase());
  }

  IconData _folderIcon(IndexedFolder folder) {
    final vis = folder.effectiveVisibility;
    if (vis == 'encrypted') {
      return _controller.isFolderUnlocked(folder.id)
          ? Icons.lock_open_rounded
          : Icons.lock_outline_rounded;
    }
    if (vis == 'private') {
      return Icons.folder_shared_outlined;
    }
    return Icons.folder_outlined;
  }

  String _folderSubtitle(IndexedFolder folder) {
    final vis = folder.effectiveVisibility;
    final path = folder.path;
    if (vis == 'encrypted') {
      return _controller.isFolderUnlocked(folder.id)
          ? '$path  ·  已解锁'
          : '$path  ·  加密';
    }
    if (vis == 'private') {
      return '$path  ·  非公开';
    }
    return '$path  ·  公开';
  }

  List<_BrowserEntry> get _browserEntries {
    final folders = _controller.currentChildFolders.toList(growable: false)
      ..sort((left, right) => _compareCaseInsensitive(left.name, right.name));
    final files = _controller.files.toList(growable: false)
      ..sort(
        (left, right) => _compareCaseInsensitive(
          _normalizedFileLabel(left),
          _normalizedFileLabel(right),
        ),
      );
    return <_BrowserEntry>[
      ...folders.map(_BrowserEntry.folder),
      ...files.map(_BrowserEntry.file),
    ];
  }

  List<IndexedFolder> get _sortedChildFolders {
    final childFolders = _controller.currentChildFolders;
    final col = _controller.sortColumnName;
    if (col == null) return childFolders;
    final sorted = List<IndexedFolder>.from(childFolders);
    sorted.sort((a, b) {
      switch (col) {
        case 'name':
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'uploadedAt':
          return (a.createdAt ?? '').compareTo(b.createdAt ?? '');
        default:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    });
    return _controller.sortAscending ? sorted : sorted.reversed.toList();
  }

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        FileManagerController(
          initialBaseUrl: Global.baseUrl,
          publicKeyPem: Global.publicKeyPem,
        );
    _storageFilter = _controller.storageFilter;
    _keywordController = TextEditingController(text: _controller.keyword);
    _pageController = TextEditingController(text: _controller.page.toString());
    _pageSizeController = TextEditingController(
      text: _controller.pageSize.toString(),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _controller.loadPreferences();
      if (!mounted || !widget.autoLoad) {
        return;
      }
      _manualPreviewThresholdBytes = _controller.previewThresholdBytes;
      await _loadInitialFiles();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.refreshCacheSize();
    });

    if (SharedFileHandler.instance.isAvailable) {
      _sharedFileSubscription = SharedFileHandler
          .instance.onSharedFilesReceived
          .listen(_handleSharedFiles);
    }
  }

  @override
  void dispose() {
    _sharedFileSubscription?.cancel();
    if (_ownsController) {
      _controller.dispose();
    }
    _keywordController.dispose();
    _pageController.dispose();
    _pageSizeController.dispose();
    super.dispose();
  }

  int _parsePositiveInt(String value, int fallback) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed <= 0) {
      return fallback;
    }
    return parsed;
  }

  Future<void> _loadInitialFiles() async {
    await _controller.refreshWorkspace();
  }

  String _resolveAbsoluteUrl(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return _controller.baseUrl;
    }
    if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
      return normalized;
    }
    return Uri.parse(_controller.baseUrl)
        .resolve(normalized.startsWith('/') ? normalized : '/$normalized')
        .toString();
  }

  /// 综合 indexedName / systemName / extension 字段判断文件扩展名
  bool _fileHasExtension(ManagedFile file, Set<String> extensions) {
    final candidates = <String>{
      file.indexedName.toLowerCase(),
      file.systemName.toLowerCase(),
      if (file.extension != null && file.extension!.isNotEmpty)
        '.${file.extension!.toLowerCase()}',
    };
    return candidates.any(
      (name) => extensions.any((ext) => name.endsWith(ext)),
    );
  }

  bool _isImageFile(ManagedFile file) {
    const imageExtensions = <String>{
      '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp',
      '.svg', '.ico', '.tiff', '.tif', '.avif', '.heic',
    };
    if (_fileHasExtension(file, imageExtensions)) return true;
    return file.mimeType.startsWith('image/');
  }

  bool _isOfficeDocument(ManagedFile file) {
    const officeExtensions = <String>{
      '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    };
    return _fileHasExtension(file, officeExtensions);
  }

  bool _isTextFile(ManagedFile file) {
    const textExtensions = <String>{
      '.txt', '.md', '.json', '.xml', '.csv', '.log',
      '.yaml', '.yml', '.ini', '.cfg', '.sh', '.bat',
      '.py', '.js', '.ts', '.dart', '.html', '.css',
      '.c', '.cpp', '.h', '.java', '.kt', '.swift', '.rs',
      '.php', '.rb', '.go', '.sql', '.lua', '.pl', '.r',
    };
    if (_fileHasExtension(file, textExtensions)) return true;
    return file.mimeType.startsWith('text/');
  }

  bool _isPreviewable(ManagedFile file) =>
      _isImageFile(file) || _isPdfFile(file) || _isTextFile(file);

  bool _isPdfFile(ManagedFile file) {
    return _fileHasExtension(file, const {'.pdf'});
  }

  void _syncQueryFromInputs() {
    _controller.updateQuery(
      storageFilter: _storageFilter,
      keyword: _keywordController.text,
      page: _parsePositiveInt(_pageController.text, 1),
      pageSize: _parsePositiveInt(_pageSizeController.text, 20),
    );
  }

  Future<void> _showResultSnackBar(
    String successMessage,
    Future<bool> future,
  ) async {
    final success = await future;
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(success ? successMessage : '操作失败，请查看日志')),
    );
  }

  Future<void> _refreshFiles() async {
    _syncQueryFromInputs();
    await _showResultSnackBar('文件列表已刷新', _controller.refreshFiles());
  }

  Future<void> _healthCheck() async {
    await _showResultSnackBar('健康检查成功', _controller.healthCheck());
  }

  Future<void> _downloadFile(ManagedFile file) async {
    if (!_controller.hasDownloadDirectory) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('请先在设置页选择固定下载目录'),
          action: SnackBarAction(
            label: '前往设置',
            onPressed: () {
              setState(() {
                _currentIndex = 1;
              });
            },
          ),
        ),
      );
      return;
    }

    final permissionResult =
        await StoragePermissionService.ensureFileWritePermission();
    if (!mounted) {
      return;
    }

    if (permissionResult != StoragePermissionResult.granted) {
      final deniedPermanently =
          permissionResult == StoragePermissionResult.permanentlyDenied;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            deniedPermanently
                ? '文件写入权限被永久拒绝，请前往系统设置开启后重试'
                : '未获得文件写入权限，无法下载到外部目录',
          ),
          action: deniedPermanently
              ? SnackBarAction(label: '设置', onPressed: openAppSettings)
              : null,
        ),
      );
      return;
    }

    final fileName =
        (file.indexedName.isEmpty ? file.systemName : file.indexedName)
            .split(RegExp(r'[\\/]'))
            .last;

    File? savedFile;
    try {
      savedFile = await _runTransferWithDialog<File?>(
        title: '下载中',
        fileName: fileName,
        action: (onProgress, cancelToken) {
          return _controller.downloadFileToConfiguredDirectoryWithProgress(
            file,
            onProgress: onProgress,
            cancelToken: cancelToken,
          );
        },
      );
    } on TransferCancelledException {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('下载已取消，可再次下载以继续传输')));
      return;
    }

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          savedFile != null ? '已下载到 ${savedFile.path}' : '下载失败，请查看日志',
        ),
      ),
    );
  }

  Future<void> _chooseDownloadDirectory() async {
    final directoryPath = await FilePicker.getDirectoryPath(
      dialogTitle: '选择固定下载目录',
    );
    if (!mounted || directoryPath == null || directoryPath.trim().isEmpty) {
      return;
    }

    await _controller.setDownloadDirectory(directoryPath);
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('固定下载目录已更新')));
  }

  Future<void> _showPreviewDialog(ManagedFile file) async {
    final folder = _controller.folderById(file.folderId);
    final disableDirectDownload =
        folder?.encrypted == true && folder?.allowDirectDownload == false;
    final isPreviewable = _isPreviewable(file);
    final needsManualPreview =
        !disableDirectDownload &&
        isPreviewable &&
        file.size > _manualPreviewThresholdBytes;
    var previewRequested = !needsManualPreview && !disableDirectDownload;

    if (previewRequested && isPreviewable) {
      _controller.loadPreview(file);
    }

    final resolvedUrl = _resolveAbsoluteUrl(file.path);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final screenSize = MediaQuery.sizeOf(dialogContext);

        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          child: StatefulBuilder(
            builder: (context, setDialogState) {
              return AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final previewWidget = disableDirectDownload
                      ? _buildFileTypePreview(file)
                      : !previewRequested
                      ? _buildManualPreviewPrompt(
                          file,
                          onLoadPressed: () {
                            setDialogState(() {
                              previewRequested = true;
                            });
                            _controller.loadPreview(file);
                          },
                        )
                      : _buildPreviewBody(
                          file,
                          _controller.previewImageBytes,
                          _controller.previewPdfPages,
                          _controller.previewError,
                        );

                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 860,
                      maxHeight: screenSize.height * 0.84,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  '文件信息',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ),
                              IconButton(
                                onPressed: () =>
                                    Navigator.of(dialogContext).pop(),
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  SizedBox(
                                    height: 300,
                                    width: double.infinity,
                                    child: previewWidget,
                                  ),
                                  const SizedBox(height: 16),
                                  _buildMetaRow('文件名称', file.indexedName),
                                  _buildMetaRow(
                                    '文件大小',
                                    ManagedFileTile.formatSize(file.size),
                                  ),
                                  _buildMetaRow('文件类型', file.mimeType),
                                  _buildMetaRow('存储方式', file.storageLabel),
                                  _buildMetaRow(
                                    disableDirectDownload ? '文件路径' : '文件链接',
                                    disableDirectDownload
                                        ? file.path
                                        : resolvedUrl,
                                    wrapText: true,
                                  ),
                                  _buildMetaRow(
                                    '上传时间',
                                    ManagedFileTile.formatUploadedAt(
                                      file.uploadedAt,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );

    _controller.clearPreview();
  }

  Future<void> _showUpsertBaseUrlPresetDialog({BaseUrlPreset? preset}) async {
    final result = await showDialog<_BaseUrlPresetDialogResult>(
      context: context,
      builder: (context) => _BaseUrlPresetDialog(preset: preset),
    );
    if (!mounted || result == null) {
      return;
    }

    try {
      if (preset == null) {
        await _controller.addBaseUrlPreset(
          name: result.name,
          baseUrl: result.baseUrl,
        );
      } else {
        await _controller.updateBaseUrlPreset(
          presetId: preset.id,
          name: result.name,
          baseUrl: result.baseUrl,
        );
      }
    } on ArgumentError catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message?.toString() ?? '新增预设失败')),
      );
      return;
    }

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(preset == null ? '服务端预设已添加' : '服务端预设已更新')),
    );

    if (preset != null && preset.id == _controller.selectedBaseUrlPresetId) {
      final refreshed = await _controller.refreshWorkspace();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(refreshed ? '当前服务器已刷新' : '当前服务器已更新，但刷新失败，请查看日志'),
        ),
      );
    }
  }

  Future<void> _showServerPresetBottomSheet() async {
    while (mounted) {
      if (!mounted) {
        return;
      }
      final action = await showModalBottomSheet<_ServerPresetSheetAction>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) {
          return FractionallySizedBox(
            heightFactor: 0.78,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '服务器地址',
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _controller.baseUrlPresets.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final preset = _controller.baseUrlPresets[index];
                          return _buildBaseUrlPresetTile(
                            preset,
                            onTap: () {
                              Navigator.of(
                                sheetContext,
                              ).pop(_ServerPresetSheetAction.select(preset));
                            },
                            onEdit: preset.isBuiltIn
                                ? null
                                : () {
                                    Navigator.of(sheetContext).pop(
                                      _ServerPresetSheetAction.edit(preset),
                                    );
                                  },
                            onDelete: preset.isBuiltIn
                                ? null
                                : () {
                                    Navigator.of(sheetContext).pop(
                                      _ServerPresetSheetAction.delete(preset),
                                    );
                                  },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: _controller.busy
                                ? null
                                : () {
                                    Navigator.of(
                                      sheetContext,
                                    ).pop(const _ServerPresetSheetAction.add());
                                  },
                            icon: const Icon(Icons.add_link_rounded),
                            label: const Text('新增服务器'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        TextButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );

      if (!mounted || action == null) {
        return;
      }

      switch (action.type) {
        case _ServerPresetSheetActionType.add:
          await _showUpsertBaseUrlPresetDialog();
        case _ServerPresetSheetActionType.edit:
          await _showUpsertBaseUrlPresetDialog(preset: action.preset);
        case _ServerPresetSheetActionType.delete:
          if (action.preset != null) {
            await _deleteBaseUrlPreset(action.preset!);
          }
        case _ServerPresetSheetActionType.select:
          if (action.preset != null) {
            await _selectBaseUrlPreset(action.preset!.id);
          }
          return;
      }
    }
  }

  Future<void> _showServerLatencyDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _ServerLatencyDialog(controller: _controller),
    );
  }

  Future<void> _selectBaseUrlPreset(String presetId) async {
    final changed = await _controller.selectBaseUrlPreset(presetId);
    if (!mounted || !changed) {
      return;
    }

    final refreshed = await _controller.refreshWorkspace();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(refreshed ? '已切换服务端并刷新数据' : '已切换服务端，但刷新失败，请查看日志')),
    );
  }

  Future<void> _deleteBaseUrlPreset(BaseUrlPreset preset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除服务端预设'),
          content: Text('确认删除“${preset.name}”吗？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    final wasSelected = preset.id == _controller.selectedBaseUrlPresetId;
    final removed = await _controller.removeBaseUrlPreset(preset.id);
    if (!mounted || !removed) {
      return;
    }

    var refreshed = true;
    if (wasSelected) {
      refreshed = await _controller.refreshWorkspace();
      if (!mounted) {
        return;
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          wasSelected
              ? (refreshed ? '预设已删除，已回退到默认服务器' : '预设已删除，但刷新失败，请查看日志')
              : '服务端预设已删除',
        ),
      ),
    );
  }

  Widget _buildBaseUrlPresetTile(
    BaseUrlPreset preset, {
    VoidCallback? onTap,
    VoidCallback? onEdit,
    VoidCallback? onDelete,
  }) {
    final theme = Theme.of(context);
    final selected = preset.id == _controller.selectedBaseUrlPresetId;

    return Container(
      decoration: BoxDecoration(
        color: selected
            ? theme.colorScheme.secondaryContainer
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: selected
              ? theme.colorScheme.secondary
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _controller.busy
            ? null
            : (onTap ?? () => _selectBaseUrlPreset(preset.id)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: selected
                    ? theme.colorScheme.secondary
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      preset.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      preset.baseUrl,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        if (selected)
                          _PresetTag(
                            label: '当前使用',
                            backgroundColor: theme.colorScheme.secondary,
                            foregroundColor: theme.colorScheme.onSecondary,
                          ),
                        if (preset.isBuiltIn)
                          _PresetTag(
                            label: '默认',
                            backgroundColor:
                                theme.colorScheme.surfaceContainerHighest,
                            foregroundColor: theme.colorScheme.onSurfaceVariant,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!preset.isBuiltIn)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      tooltip: '编辑预设',
                      onPressed: _controller.busy
                          ? null
                          : (onEdit ??
                                () {
                                  _showUpsertBaseUrlPresetDialog(
                                    preset: preset,
                                  );
                                }),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: '删除预设',
                      onPressed: _controller.busy
                          ? null
                          : (onDelete ??
                                () {
                                  _deleteBaseUrlPreset(preset);
                                }),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildManualPreviewPrompt(
    ManagedFile file, {
    required VoidCallback onLoadPressed,
  }) {
    final isImage = _isImageFile(file);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                isImage ? Icons.image_outlined : Icons.description_outlined,
                size: 64,
                color: const Color(0xFF8A8A8A),
              ),
              const SizedBox(height: 12),
              Text(
                '该文件较大，当前大小为 ${ManagedFileTile.formatSize(file.size)}。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onLoadPressed,
                child: const Text('加载预览'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showLogsDialog() async {
    final screenSize = MediaQuery.sizeOf(context);
    final scrollController = ScrollController();

    await showDialog<void>(
      context: context,
      builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!scrollController.hasClients) {
            return;
          }
          scrollController.jumpTo(scrollController.position.maxScrollExtent);
        });
        return AlertDialog(
          title: const Text('操作日志'),
          content: SizedBox(
            width: screenSize.width * 0.88,
            height: screenSize.height * 0.6,
            child: SingleChildScrollView(
              controller: scrollController,
              child: SelectableText(
                _controller.logText,
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
    scrollController.dispose();
  }

  Future<String?> _promptPassword({
    required String title,
    required String description,
    String confirmLabel = '确定',
  }) async {
    var password = '';
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(description),
              const SizedBox(height: 12),
              TextFormField(
                autofocus: true,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码'),
                onChanged: (value) {
                  password = value;
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(password.trim()),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _ensureFolderUnlocked(
    String? folderId, {
    required String purpose,
  }) async {
    final folder = _controller.folderById(folderId);
    if (folder == null || !folder.encrypted) {
      return true;
    }
    if (_controller.isFolderUnlocked(folder.id)) {
      return true;
    }
    final password = await _promptPassword(
      title: '解锁文件夹',
      description: '进入“${folder.name}”前需要输入密码以$purpose。',
      confirmLabel: '解锁',
    );
    if (password == null || password.trim().isEmpty) {
      return false;
    }
    _controller.unlockFolder(folder.id, password);
    return true;
  }

  List<IndexedFolder> _buildAvailableTargetFolders(
    List<IndexedFolder> movingFolders,
  ) {
    if (movingFolders.isEmpty) {
      return _controller.folders;
    }
    final movingIds = movingFolders.map((folder) => folder.id).toSet();
    bool isDescendantOfMovingFolder(IndexedFolder folder) {
      var cursorId = folder.parentId;
      while (cursorId != null && cursorId.isNotEmpty) {
        if (movingIds.contains(cursorId)) {
          return true;
        }
        cursorId = _controller.folderById(cursorId)?.parentId;
      }
      return false;
    }

    return _controller.folders
        .where((folder) {
          if (movingIds.contains(folder.id)) {
            return false;
          }
          if (isDescendantOfMovingFolder(folder)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  Future<Map<String, String>?> _collectFolderPasswords(
    List<IndexedFolder> folders, {
    required String purpose,
  }) async {
    final encryptedFolders =
        folders.where((folder) => folder.encrypted).toList(growable: false)
          ..sort(
            (left, right) => _compareCaseInsensitive(left.path, right.path),
          );
    if (encryptedFolders.isEmpty) {
      return const <String, String>{};
    }

    final passwords = <String, String>{};
    for (final folder in encryptedFolders) {
      final password = await _promptPassword(
        title: '验证文件夹密码',
        description: '$purpose“${folder.name}”前需要输入该文件夹密码。',
        confirmLabel: '验证',
      );
      if (password == null) {
        return null;
      }
      final normalizedPassword = password.trim();
      if (normalizedPassword.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已加密文件夹必须输入密码')));
        }
        return null;
      }
      passwords[folder.id] = normalizedPassword;
    }
    return passwords;
  }

  bool get _supportsDesktopDrop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<List<FileSystemEntity>> _pickUploadEntities({
    required bool pickDirectory,
  }) async {
    if (pickDirectory) {
      final directoryPath = await FilePicker.getDirectoryPath(
        dialogTitle: '选择要上传的文件夹',
      );
      if (directoryPath == null || directoryPath.trim().isEmpty) {
        return const <FileSystemEntity>[];
      }
      return <FileSystemEntity>[Directory(directoryPath)];
    }

    final picked = await FilePicker.pickFiles();
    if (picked == null || picked.files.isEmpty) {
      return const <FileSystemEntity>[];
    }
    return picked.files
        .map((item) => item.path)
        .whereType<String>()
        .where((path) => path.trim().isNotEmpty)
        .map<FileSystemEntity>((path) => File(path))
        .toList(growable: false);
  }

  Future<List<FileSystemEntity>> _normalizeDroppedEntities(
    List<XFile> droppedFiles,
  ) async {
    final deduplicated = <String, FileSystemEntity>{};
    for (final droppedFile in droppedFiles) {
      final rawPath = droppedFile.path.trim();
      if (rawPath.isEmpty) {
        continue;
      }
      final entityType = await FileSystemEntity.type(rawPath);
      if (entityType == FileSystemEntityType.file) {
        deduplicated[rawPath] = File(rawPath);
      } else if (entityType == FileSystemEntityType.directory) {
        deduplicated[rawPath] = Directory(rawPath);
      }
    }
    return deduplicated.values.toList(growable: false);
  }

  String _describeUploadSelection(List<FileSystemEntity> entries) {
    if (entries.isEmpty) {
      return '未选择内容';
    }
    if (entries.length == 1) {
      return entries.first.path.split(RegExp(r'[\\/]')).last;
    }
    final fileCount = entries.whereType<File>().length;
    final folderCount = entries.whereType<Directory>().length;
    return '共选择 $fileCount 个文件、$folderCount 个文件夹';
  }

  Future<String?> _resolveUploadFolderPassword(
    IndexedFolder folder,
    String purpose,
  ) async {
    final cachedPassword = _controller.unlockedFolderPassword(folder.id);
    if (cachedPassword != null && cachedPassword.isNotEmpty) {
      return cachedPassword;
    }
    final password = await _promptPassword(
      title: '验证文件夹密码',
      description: '$purpose“${folder.name}”前需要输入该文件夹密码。',
      confirmLabel: '验证',
    );
    if (password == null || password.trim().isEmpty) {
      return null;
    }
    _controller.unlockFolder(folder.id, password.trim());
    return password.trim();
  }

  Future<Map<String, String>?> _collectArchiveFolderPasswords(
    IndexedFolder folder,
  ) async {
    return _collectFolderPasswords(
      _controller.encryptedFoldersForArchive(folder.id),
      purpose: '下载文件夹压缩包',
    );
  }

  Future<void> _openFolder(String? folderId) async {
    final folder = _controller.folderById(folderId);
    String? password;
    if (folder != null &&
        folder.encrypted &&
        !_controller.isFolderUnlocked(folder.id)) {
      password = await _promptPassword(
        title: '解锁文件夹',
        description: '进入“${folder.name}”前需要输入密码。',
        confirmLabel: '解锁',
      );
      if (password == null || password.trim().isEmpty) {
        return;
      }
    }

    _syncQueryFromInputs();
    final success = await _controller.openFolder(
      folderId,
      folderPassword: password,
    );
    if (!mounted || success) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('文件夹打开失败，请查看日志')));
  }

  Future<void> _showCreateFolderDialog() async {
    final parentFolderId = _controller.currentFolderId;
    final parentUnlocked = await _ensureFolderUnlocked(
      parentFolderId,
      purpose: '创建子文件夹',
    );
    if (!mounted || !parentUnlocked) {
      return;
    }

    final result = await showDialog<_CreateFolderDialogResult>(
      context: context,
      builder: (context) => _CreateFolderDialog(
        parentPathLabel: _controller.currentFolderPathLabel,
      ),
    );

    if (!mounted || result == null) {
      return;
    }

    final success = await _controller.createFolder(
      name: result.name,
      parentId: parentFolderId,
      visibility: result.visibility,
      encrypted: result.encrypted,
      password: result.password,
      parentFolderPassword: _controller.unlockedFolderPassword(parentFolderId),
    );

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(success ? '文件夹已创建' : '文件夹创建失败，请查看日志')),
    );
  }

  Future<void> _showMoveItemsToFolderDialog({
    List<ManagedFile> files = const <ManagedFile>[],
    List<IndexedFolder> folders = const <IndexedFolder>[],
    String? targetFolderId,
  }) async {
    if (files.isEmpty && folders.isEmpty) {
      return;
    }

    final availableTargetFolders = _buildAvailableTargetFolders(folders);
    String? selectedFolderId = targetFolderId ?? _controller.currentFolderId;
    if (selectedFolderId != null &&
        !availableTargetFolders.any(
          (folder) => folder.id == selectedFolderId,
        )) {
      selectedFolderId = null;
    }
    var targetPassword =
        _controller.unlockedFolderPassword(selectedFolderId) ?? '';

    final result = await showDialog<_MoveToFolderDialogResult>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final selectedFolder = _controller.folderById(selectedFolderId);
            final needsPassword = selectedFolder?.encrypted == true;
            final title = files.isNotEmpty && folders.isNotEmpty
                ? '移动文件和文件夹'
                : folders.isNotEmpty
                ? (folders.length == 1 ? '移动文件夹' : '批量移动文件夹')
                : (files.length == 1 ? '移动到文件夹' : '批量移动到文件夹');
            return AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (files.isNotEmpty || folders.isNotEmpty)
                      Text(
                        '将 ${files.length} 个文件、${folders.length} 个文件夹移动到目标目录',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (files.isNotEmpty || folders.isNotEmpty)
                      const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedFolderId ?? '',
                      decoration: const InputDecoration(labelText: '目标文件夹'),
                      items: <DropdownMenuItem<String>>[
                        const DropdownMenuItem<String>(
                          value: '',
                          child: Text('根目录'),
                        ),
                        ...availableTargetFolders.map(
                          (folder) => DropdownMenuItem<String>(
                            value: folder.id,
                            child: Text(folder.path),
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          selectedFolderId = value == null || value.isEmpty
                              ? null
                              : value;
                          targetPassword =
                              _controller.unlockedFolderPassword(
                                selectedFolderId,
                              ) ??
                              '';
                        });
                      },
                    ),
                    if (needsPassword) ...<Widget>[
                      const SizedBox(height: 12),
                      TextFormField(
                        key: ValueKey<String?>('move-$selectedFolderId'),
                        initialValue: targetPassword,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: '目标文件夹密码'),
                        onChanged: (value) {
                          targetPassword = value;
                        },
                      ),
                    ],
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(context).pop(
                      _MoveToFolderDialogResult(
                        folderId: selectedFolderId,
                        password: targetPassword.trim(),
                      ),
                    );
                  },
                  child: const Text('移动'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) {
      return;
    }

    final selectedFolder = _controller.folderById(result.folderId);
    final resolvedTargetPassword = selectedFolder?.encrypted == true
        ? result.password
        : null;
    if (selectedFolder?.encrypted == true &&
        !(resolvedTargetPassword?.isNotEmpty ?? false)) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('目标文件夹已加密，请输入目标文件夹密码')));
      return;
    }

    final sourceFolderPasswords = await _collectFolderPasswords(
      folders,
      purpose: '移动文件夹',
    );
    if (sourceFolderPasswords == null) {
      return;
    }

    if (selectedFolder?.encrypted == true &&
        (resolvedTargetPassword?.isNotEmpty ?? false)) {
      _controller.unlockFolder(selectedFolder!.id, resolvedTargetPassword!);
    }
    for (final entry in sourceFolderPasswords.entries) {
      _controller.unlockFolder(entry.key, entry.value);
    }

    final success = await _controller.moveItemsToFolder(
      files: files,
      folders: folders,
      targetFolderId: result.folderId,
      targetFolderPassword: resolvedTargetPassword,
      sourceFolderPasswords: sourceFolderPasswords,
    );

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(success ? '所选内容已移动到目标文件夹' : '移动失败，请查看日志')),
    );
  }

  Future<void> _showFolderManagementDialog(IndexedFolder folder) async {
    var name = folder.name;
    var currentPassword = _controller.unlockedFolderPassword(folder.id) ?? '';
    var newPassword = '';
    String? selectedParentId = folder.parentId;
    var encrypted = folder.encrypted;
    var allowDirectDownload = folder.allowDirectDownload;

    final action = await showDialog<_FolderManagementDialogResult>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('文件夹设置: ${folder.name}'),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    TextFormField(
                      initialValue: name,
                      decoration: const InputDecoration(labelText: '文件夹名称'),
                      onChanged: (value) {
                        name = value;
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedParentId ?? '',
                      decoration: const InputDecoration(labelText: '父级文件夹'),
                      items: <DropdownMenuItem<String>>[
                        const DropdownMenuItem<String>(
                          value: '',
                          child: Text('根目录'),
                        ),
                        ..._controller.folders
                            .where((item) => item.id != folder.id)
                            .map(
                              (item) => DropdownMenuItem<String>(
                                value: item.id,
                                child: Text(item.path),
                              ),
                            ),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          selectedParentId = value == null || value.isEmpty
                              ? null
                              : value;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      value: encrypted,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (value) {
                        setDialogState(() {
                          encrypted = value ?? false;
                          if (!encrypted) {
                            allowDirectDownload = false;
                            newPassword = '';
                          }
                        });
                      },
                      title: const Text('加密文件夹'),
                    ),
                    if (folder.encrypted) ...<Widget>[
                      TextFormField(
                        initialValue: currentPassword,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: '当前密码'),
                        onChanged: (value) {
                          currentPassword = value;
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (encrypted) ...<Widget>[
                      CheckboxListTile(
                        value: allowDirectDownload,
                        contentPadding: EdgeInsets.zero,
                        onChanged: (value) {
                          setDialogState(() {
                            allowDirectDownload = value ?? false;
                          });
                        },
                        title: const Text('允许直链免密下载'),
                      ),
                      TextFormField(
                        key: ValueKey<String>(
                          'folder-password-${folder.id}-$encrypted',
                        ),
                        initialValue: newPassword,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: folder.encrypted ? '修改密码（可选）' : '设置密码',
                        ),
                        onChanged: (value) {
                          newPassword = value;
                        },
                      ),
                    ],
                  ],
                ),
              ),
              actions: <Widget>[
                if (folder.parentId != null || folder.encrypted)
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop(
                        _FolderManagementDialogResult(
                          action: _FolderManagementAction.delete,
                          currentPassword: currentPassword.trim(),
                        ),
                      );
                    },
                    child: const Text('删除'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(context).pop(
                      _FolderManagementDialogResult(
                        action: _FolderManagementAction.save,
                        name: name.trim(),
                        parentId: selectedParentId,
                        encrypted: encrypted,
                        allowDirectDownload: allowDirectDownload,
                        currentPassword: currentPassword.trim(),
                        newPassword: newPassword.trim(),
                      ),
                    );
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );

    if (action == null) {
      return;
    }

    if (action.action == _FolderManagementAction.delete) {
      final success = await _controller.deleteFolder(
        folderId: folder.id,
        currentPassword: action.currentPassword,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? '文件夹已删除' : '文件夹删除失败，请查看日志')),
      );
      return;
    }

    final success = await _controller.updateFolder(
      folderId: folder.id,
      name: action.name,
      parentId: action.parentId,
      encrypted: action.encrypted,
      allowDirectDownload: action.encrypted == true
          ? action.allowDirectDownload
          : null,
      currentPassword: action.currentPassword,
      targetParentPassword: _controller.unlockedFolderPassword(action.parentId),
      newPassword: action.newPassword,
    );

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(success ? '文件夹已更新' : '文件夹更新失败，请查看日志')),
    );
  }

  Future<void> _handleSharedFiles(List<String> filePaths) async {
    if (filePaths.isEmpty || !mounted) return;

    // 等待页面初始化完成后再处理
    await WidgetsBinding.instance.endOfFrame;

    final entities = <FileSystemEntity>[];
    for (final path in filePaths) {
      final file = File(path);
      if (await file.exists()) {
        entities.add(file);
      }
    }

    if (entities.isEmpty || !mounted) return;

    await _showUploadDialog(initialEntries: entities);
  }

  Future<void> _showUploadDialog({
    List<FileSystemEntity>? initialEntries,
    bool pickDirectory = false,
    String? targetFolderId,
  }) async {
    final currentFolderId = _controller.currentFolderId;
    final currentFolder = _controller.folderById(currentFolderId);
    final currentFolderUnlocked = await _ensureFolderUnlocked(
      currentFolderId,
      purpose: pickDirectory ? '上传文件夹到当前目录' : '上传文件到当前目录',
    );
    if (!mounted || !currentFolderUnlocked) {
      return;
    }

    var selectedEntries = initialEntries?.toList(growable: true) ??
        <FileSystemEntity>[];
    var permanent = false;
    var selectedFolderId = targetFolderId ?? currentFolderId;
    var selectedFolderPassword =
        _controller.unlockedFolderPassword(selectedFolderId) ?? '';

    final uploadDialogResult = await showDialog<_UploadDialogResult>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final selectedFolder =
                _controller.folderById(selectedFolderId);
            final needsTargetPassword =
                selectedFolder?.encrypted == true;
            return AlertDialog(
              title: Text(pickDirectory ? '上传文件夹' : '上传文件'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        final picked = await _pickUploadEntities(
                          pickDirectory: pickDirectory,
                        );
                        if (picked.isEmpty) {
                          return;
                        }
                        setDialogState(() {
                          selectedEntries = picked.toList(growable: true);
                        });
                      },
                      icon: Icon(
                        pickDirectory
                            ? Icons.drive_folder_upload_outlined
                            : Icons.attach_file_rounded,
                      ),
                      label: Text(pickDirectory ? '选择文件夹' : '选择文件'),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      selectedEntries.isEmpty
                          ? (pickDirectory ? '尚未选择文件夹' : '尚未选择文件')
                          : _describeUploadSelection(selectedEntries),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (selectedEntries.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: selectedEntries
                                .take(5)
                                .map(
                                  (entry) => Text(
                                    entry.path.split(RegExp(r'[\\/]')).last,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        ),
                      ),
                      if (selectedEntries.length > 5)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '其余 ${selectedEntries.length - 5} 项将在上传时一并处理',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: selectedFolderId ?? '',
                      decoration: const InputDecoration(
                        labelText: '上传到',
                        isDense: true,
                      ),
                      items: <DropdownMenuItem<String>>[
                        const DropdownMenuItem<String>(
                          value: '',
                          child: Text('根目录 /'),
                        ),
                        ..._controller.folders.map(
                          (folder) => DropdownMenuItem<String>(
                            value: folder.id,
                            child: Text(
                              folder.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          selectedFolderId =
                              value == null || value.isEmpty
                                  ? null
                                  : value;
                          selectedFolderPassword =
                              _controller.unlockedFolderPassword(
                                selectedFolderId,
                              ) ??
                              '';
                        });
                      },
                    ),
                    if (needsTargetPassword) ...<Widget>[
                      const SizedBox(height: 12),
                      TextFormField(
                        key: ValueKey<String>(
                          'upload-folder-password-$selectedFolderId',
                        ),
                        initialValue: selectedFolderPassword,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: '目标文件夹密码',
                          isDense: true,
                        ),
                        onChanged: (value) {
                          selectedFolderPassword = value;
                        },
                      ),
                    ],
                    const SizedBox(height: 8),
                    if(pickDirectory)
                      Text('将保留所选文件夹的完整目录结构；若遇到同名文件夹，会合并到现有目录。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (currentFolder?.encrypted == true &&
                        selectedFolderId == currentFolderId) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        '当前目录已加密，本次上传将使用当前目录已验证的密码。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 16),
                    CheckboxListTile(
                      value: permanent,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (value) {
                        setDialogState(() {
                          permanent = value ?? false;
                        });
                      },
                      title: const Text('不自动删除'),
                      subtitle: const Text('不勾选时次日将自动清除'),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: selectedEntries.isEmpty
                      ? null
                      : () {
                          Navigator.of(context).pop(
                            _UploadDialogResult(
                              entries:
                                  selectedEntries.toList(growable: false),
                              permanent: permanent,
                              folderId: selectedFolderId,
                            ),
                          );
                        },
                  child: const Text('开始上传'),
                ),
              ],
            );
          },
        );
      },
    );

    if (uploadDialogResult == null) {
      return;
    }

    final effectiveFolderId = uploadDialogResult.folderId ?? currentFolderId;
    final effectiveFolderPassword =
        uploadDialogResult.folderId != null &&
                uploadDialogResult.folderId != currentFolderId
            ? selectedFolderPassword
            : currentFolder?.encrypted == true
                ? _controller.unlockedFolderPassword(currentFolderId)
                : null;

    try {
      final resolvedPassword = effectiveFolderPassword?.isNotEmpty == true
          ? effectiveFolderPassword
          : _controller.unlockedFolderPassword(effectiveFolderId);
      final uploadResult = await _runBatchTransferWithDialog<BatchUploadResult>(
        title: '上传中',
        initialFileName: _describeUploadSelection(uploadDialogResult.entries),
        summaryText: '正在校验目录并准备上传',
        action: (onProgress, cancelToken) {
          return _controller.uploadFileSystemEntitiesWithProgress(
            entities: uploadDialogResult.entries,
            permanent: uploadDialogResult.permanent,
            folderId: effectiveFolderId,
            folderPassword: resolvedPassword,
            cancelToken: cancelToken,
            resolveFolderPassword: _resolveUploadFolderPassword,
            onBatchProgress: onProgress,
          );
        },
      );
      if (!mounted) {
        return;
      }
      if (uploadResult.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              uploadResult.totalItems <= 1
                  ? '上传完成，已成功处理 1 项'
                  : '批量上传完成，已成功处理 ${uploadResult.succeededItems} 项',
            ),
          ),
        );
      } else {
        await _showBatchUploadSummaryDialog(uploadResult);
      }
    } on TransferCancelledException {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('上传已取消，已完成的项目会保留，未完成的项目可稍后重试')));
    } on StateError catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message.toString())));
    }
  }

  Future<void> _downloadFolderArchive(IndexedFolder folder) async {
    if (!_controller.hasDownloadDirectory) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('请先在设置页选择固定下载目录'),
          action: SnackBarAction(
            label: '前往设置',
            onPressed: () {
              setState(() {
                _currentIndex = 1;
              });
            },
          ),
        ),
      );
      return;
    }

    final permissionResult =
        await StoragePermissionService.ensureFileWritePermission();
    if (!mounted) {
      return;
    }

    if (permissionResult != StoragePermissionResult.granted) {
      final deniedPermanently =
          permissionResult == StoragePermissionResult.permanentlyDenied;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            deniedPermanently
                ? '文件写入权限被永久拒绝，请前往系统设置开启后重试'
                : '未获得文件写入权限，无法下载到外部目录',
          ),
          action: deniedPermanently
              ? SnackBarAction(label: '设置', onPressed: openAppSettings)
              : null,
        ),
      );
      return;
    }

    final folderPasswords = await _collectArchiveFolderPasswords(folder);
    if (folderPasswords == null) {
      return;
    }
    for (final entry in folderPasswords.entries) {
      _controller.unlockFolder(entry.key, entry.value);
    }

    try {
      final savedFile = await _runTransferWithDialog<File?>(
        title: '下载压缩包',
        fileName: '${folder.name}.zip',
        summaryText: '正在打包并下载“${folder.name}”的全部内容',
        action: (onProgress, cancelToken) {
          return _controller.downloadFolderArchiveToConfiguredDirectoryWithProgress(
            folder,
            folderPasswords: folderPasswords,
            onProgress: onProgress,
            cancelToken: cancelToken,
          );
        },
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savedFile != null
                ? '“${folder.name}”压缩包已下载到固定目录'
                : '“${folder.name}”压缩包下载失败，请查看日志',
          ),
        ),
      );
    } on TransferCancelledException {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('“${folder.name}”压缩包下载已取消')));
    }
  }

  Future<void> _showBatchUploadSummaryDialog(BatchUploadResult result) async {
    final failurePreview = result.failures.take(8).toList(growable: false);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(result.succeededItems > 0 ? '批量上传部分完成' : '批量上传失败'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '本次共处理 ${result.totalItems} 项，成功 ${result.succeededItems} 项，失败 ${result.failedItems} 项。',
                ),
                const SizedBox(height: 12),
                if (failurePreview.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: failurePreview
                            .map(
                              (failure) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: RichText(
                                  text: TextSpan(
                                    style: Theme.of(context).textTheme.bodySmall,
                                    children: <InlineSpan>[
                                      TextSpan(
                                        text: '[${failure.type.label}] ${failure.label}\n',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(fontWeight: FontWeight.w700),
                                      ),
                                      TextSpan(text: failure.error),
                                    ],
                                  ),
                                ),
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ),
                  ),
                if (result.failedItems > failurePreview.length)
                  Text(
                    '其余 ${result.failedItems - failurePreview.length} 项失败详情已写入操作日志。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                Text(
                  '如果同一批次里同时出现网络失败、密码失败和服务端拒绝，建议优先处理密码失败项，再针对其余项重试。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<T> _runBatchTransferWithDialog<T>({
    required String title,
    required String initialFileName,
    String? summaryText,
    required Future<T> Function(
      BatchTransferProgressCallback onProgress,
      TransferCancellationToken cancelToken,
    )
    action,
  }) async {
    final progressNotifier = ValueNotifier<_TransferDialogState>(
      _TransferDialogState(
        fileName: initialFileName,
        summaryText: summaryText,
        detailText: null,
        transferredBytes: 0,
        totalBytes: null,
        active: true,
      ),
    );
    final cancelToken = TransferCancellationToken();
    final navigator = Navigator.of(context, rootNavigator: true);
    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: true,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            final state = progressNotifier.value;
            if (state.active) {
              progressNotifier.value = state.copyWith(active: false);
              cancelToken.cancel();
            }
          },
          child: ValueListenableBuilder<_TransferDialogState>(
            valueListenable: progressNotifier,
            builder: (context, state, _) {
              return TransferProgressDialog(
                title: title,
                fileName: state.fileName,
                summaryText: state.summaryText,
                detailText: state.detailText,
                transferredBytes: state.transferredBytes,
                totalBytes: state.totalBytes,
                active: state.active,
                onCancel: () {
                  if (!state.active) {
                    return;
                  }
                  progressNotifier.value = state.copyWith(active: false);
                  cancelToken.cancel();
                },
              );
            },
          ),
        );
      },
    );

    var notifId = -1;
    try {
      notifId = NotificationService.instance.showProgress(
        title: title,
        body: '准备中: $initialFileName',
        maxProgress: 100,
      );
      final result = await action((progress) {
        final state = progressNotifier.value;
        progressNotifier.value = state.copyWith(
          fileName: progress.currentItemLabel,
          summaryText: progress.totalItems <= 1
              ? '当前正在处理 1 项内容'
              : '当前第 ${progress.completedItems + 1 > progress.totalItems ? progress.totalItems : progress.completedItems + 1} / ${progress.totalItems} 项',
          detailText: progress.statusText,
          transferredBytes: progress.transferredBytes,
          totalBytes: progress.totalBytes,
        );
        if (progress.totalBytes > 0) {
          final pct = ((progress.transferredBytes / progress.totalBytes) * 100)
              .clamp(0, 100)
              .toInt();
          NotificationService.instance.updateProgress(
            notifId,
            body: '${progress.currentItemLabel} — $pct%',
            progress: pct,
          );
        }
      }, cancelToken);
      if (navigator.mounted) {
        navigator.pop();
      }
      NotificationService.instance.complete(notifId, body: '传输完成');
      await dialogFuture;
      return result;
    } catch (_) {
      if (navigator.mounted) {
        navigator.pop();
      }
      NotificationService.instance.fail(notifId, body: '传输中断');
      await dialogFuture;
      rethrow;
    } finally {
      progressNotifier.dispose();
    }
  }

  Future<T> _runTransferWithDialog<T>({
    required String title,
    required String fileName,
    String? summaryText,
    required Future<T> Function(
      TransferProgressCallback onProgress,
      TransferCancellationToken cancelToken,
    )
    action,
  }) async {
    final progressNotifier = ValueNotifier<_TransferDialogState>(
      _TransferDialogState(
        fileName: fileName,
        summaryText: summaryText,
        detailText: null,
        transferredBytes: 0,
        totalBytes: null,
        active: true,
      ),
    );
    final cancelToken = TransferCancellationToken();
    final navigator = Navigator.of(context, rootNavigator: true);
    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: true,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            final state = progressNotifier.value;
            if (state.active) {
              progressNotifier.value = state.copyWith(active: false);
              cancelToken.cancel();
            }
          },
          child: ValueListenableBuilder<_TransferDialogState>(
            valueListenable: progressNotifier,
            builder: (context, state, _) {
              return TransferProgressDialog(
                title: title,
                fileName: state.fileName,
                summaryText: state.summaryText,
                detailText: state.detailText,
                transferredBytes: state.transferredBytes,
                totalBytes: state.totalBytes,
                active: state.active,
                onCancel: () {
                  if (!state.active) {
                    return;
                  }
                  progressNotifier.value = state.copyWith(active: false);
                  cancelToken.cancel();
                },
              );
            },
          ),
        );
      },
    );

    var notifId2 = -1;
    try {
      notifId2 = NotificationService.instance.showProgress(
        title: title,
        body: '准备中: $fileName',
        maxProgress: 100,
      );
      final result = await action((transferredBytes, totalBytes) {
        final current = progressNotifier.value;
        progressNotifier.value = current.copyWith(
          transferredBytes: transferredBytes,
          totalBytes: totalBytes,
        );
        if (totalBytes != null && totalBytes > 0) {
          final pct = ((transferredBytes / totalBytes) * 100)
              .clamp(0, 100)
              .toInt();
          NotificationService.instance.updateProgress(
            notifId2,
            body: '$fileName — $pct%',
            progress: pct,
          );
        }
      }, cancelToken);
      if (navigator.mounted) {
        navigator.pop();
      }
      NotificationService.instance.complete(notifId2, body: '传输完成');
      await dialogFuture;
      return result;
    } catch (_) {
      if (navigator.mounted) {
        navigator.pop();
      }
      NotificationService.instance.fail(notifId2, body: '传输中断');
      await dialogFuture;
      rethrow;
    } finally {
      progressNotifier.dispose();
    }
  }

  Future<void> _showRenameDialog(ManagedFile file) async {
    var renameValue = file.indexedName.isEmpty
        ? file.systemName
        : file.indexedName;
    final newName = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('重命名文件'),
          content: TextFormField(
            initialValue: renameValue,
            autofocus: true,
            decoration: const InputDecoration(labelText: '新的 indexedName'),
            onChanged: (value) {
              renameValue = value;
            },
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(renameValue.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (newName == null || newName.trim().isEmpty) {
      return;
    }

    await _showResultSnackBar(
      '索引文件名已更新',
      _controller.renameFile(file: file, indexedName: newName),
    );
  }

  Future<void> _showMoveDialog(List<ManagedFile> files) async {
    if (files.isEmpty) {
      return;
    }

    var targetStorage = files.every((file) => file.isTemporary)
        ? 'permanent'
        : 'temporary';
    final selectedTarget = await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(
                files.length == 1 ? '设置存储方式' : '批量设置 ${files.length} 个文件的存储方式',
              ),
              content: DropdownButtonFormField<String>(
                initialValue: targetStorage,
                decoration: const InputDecoration(labelText: '存储方式'),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                    value: 'temporary',
                    child: Text('临时'),
                  ),
                  DropdownMenuItem<String>(
                    value: 'permanent',
                    child: Text('永久'),
                  ),
                ],
                onChanged: (value) {
                  setDialogState(() {
                    targetStorage = value ?? targetStorage;
                  });
                },
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(targetStorage),
                  child: const Text('保存设置'),
                ),
              ],
            );
          },
        );
      },
    );

    if (selectedTarget == null) {
      return;
    }

    await _showResultSnackBar(
      files.length == 1 ? '文件存储方式已更新' : '批量存储方式已更新',
      _controller.moveFiles(files: files, targetStorage: selectedTarget),
    );
  }

  Future<void> _confirmDeleteItems({
    List<ManagedFile> files = const <ManagedFile>[],
    List<IndexedFolder> folders = const <IndexedFolder>[],
  }) async {
    if (files.isEmpty && folders.isEmpty) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final title = files.isNotEmpty && folders.isNotEmpty
            ? '批量删除文件和文件夹'
            : folders.isNotEmpty
            ? (folders.length == 1 ? '删除文件夹' : '批量删除文件夹')
            : (files.length == 1 ? '删除文件' : '批量删除 ${files.length} 个文件');
        final content = files.isNotEmpty && folders.isNotEmpty
            ? '确认删除当前选中的 ${files.length} 个文件和 ${folders.length} 个文件夹吗？所选文件夹将递归删除其全部内容。'
            : folders.isNotEmpty
            ? (folders.length == 1
                  ? '确认递归删除文件夹 ${folders.first.name} 及其全部内容吗？'
                  : '确认递归删除当前选中的 ${folders.length} 个文件夹及其全部内容吗？')
            : (files.length == 1
                  ? '确认删除 ${files.first.indexedName.isEmpty ? files.first.systemName : files.first.indexedName} 吗？'
                  : '确认删除当前选中的 ${files.length} 个文件吗？');
        return AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF8C2F1B),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    final folderPasswords = await _collectFolderPasswords(
      folders,
      purpose: '删除文件夹',
    );
    if (folderPasswords == null) {
      return;
    }
    for (final entry in folderPasswords.entries) {
      _controller.unlockFolder(entry.key, entry.value);
    }

    final success = await _controller.deleteItems(
      files: files,
      folders: folders,
      currentFolderPasswords: folderPasswords,
    );

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(success ? '删除完成' : '删除失败，请查看日志')));

    if (_batchMode && !_controller.hasSelection && mounted) {
      setState(() {
        _batchMode = false;
      });
    }
  }

  void _toggleBatchMode() {
    setState(() {
      final nextValue = !_batchMode;
      _batchMode = nextValue;
      if (!nextValue) {
        _controller.clearSelection();
      }
    });
  }

  Future<void> _showBatchActionsSheet() async {
    final selectedFiles = _controller.selectedFiles;
    final selectedFolders = _controller.selectedFolders;
    if (selectedFiles.isEmpty && selectedFolders.isEmpty) {
      return;
    }

    final selectedCount = selectedFiles.length + selectedFolders.length;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              if (selectedFiles.isNotEmpty && selectedFolders.isEmpty)
                ListTile(
                  leading: const Icon(Icons.drive_file_move_outline),
                  title: Text('批量设置存储方式 (${selectedFiles.length})'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _showMoveDialog(selectedFiles);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: Text('批量移动 ($selectedCount)'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showMoveItemsToFolderDialog(
                    files: selectedFiles,
                    folders: selectedFolders,
                  );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Color(0xFF8C2F1B),
                ),
                title: Text('删除所选 ($selectedCount)'),
                textColor: const Color(0xFF8C2F1B),
                iconColor: const Color(0xFF8C2F1B),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _confirmDeleteItems(
                    files: selectedFiles,
                    folders: selectedFolders,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.clear_all_rounded),
                title: const Text('清空选择'),
                onTap: () {
                  _controller.clearSelection();
                  Navigator.of(sheetContext).pop();
                },
              ),
              ListTile(
                leading: const Icon(Icons.close_rounded),
                title: const Text('退出批量模式'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _toggleBatchMode();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _handleFileTap(ManagedFile file) {
    if (_batchMode) {
      final isSelected = _controller.selectedPaths.contains(file.path);
      _controller.toggleSelection(file, !isSelected);
      return;
    }

    _showPreviewDialog(file);
  }

  void _handleFileTapDesktop(ManagedFile file) {
    if (_batchMode) {
      final isSelected = _controller.selectedPaths.contains(file.path);
      _controller.toggleSelection(file, !isSelected);
      return;
    }
    final ctrl = HardwareKeyboard.instance.logicalKeysPressed
        .intersection(<LogicalKeyboardKey>{
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.controlRight,
        })
        .isNotEmpty;
    if (ctrl) {
      _controller.toggleSelection(
          file, !_controller.selectedPaths.contains(file.path));
    } else {
      _controller.clearSelection();
      _controller.toggleSelection(file, true);
    }
  }

  void _handleFileLongPress(ManagedFile file) {
    if (_batchMode) {
      final isSelected = _controller.selectedPaths.contains(file.path);
      if (!isSelected) {
        _controller.toggleSelection(file, true);
        return;
      }
      _showBatchActionsSheet();
      return;
    }

    _showFileActions(file);
  }

  void _handleFolderTap(IndexedFolder folder) {
    if (_batchMode) {
      final isSelected = _controller.selectedFolderIds.contains(folder.id);
      _controller.toggleFolderSelection(folder, !isSelected);
      return;
    }

    _openFolder(folder.id);
  }

  void _handleFolderTapDesktop(IndexedFolder folder) {
    if (_batchMode) {
      final isSelected = _controller.selectedFolderIds.contains(folder.id);
      _controller.toggleFolderSelection(folder, !isSelected);
      return;
    }
    final ctrl = HardwareKeyboard.instance.logicalKeysPressed
        .intersection(<LogicalKeyboardKey>{
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.controlRight,
        })
        .isNotEmpty;
    if (ctrl) {
      _controller.toggleFolderSelection(
          folder, !_controller.selectedFolderIds.contains(folder.id));
    } else {
      _controller.clearSelection();
      _controller.toggleFolderSelection(folder, true);
    }
  }

  void _handleFolderLongPress(IndexedFolder folder) {
    if (_batchMode) {
      final isSelected = _controller.selectedFolderIds.contains(folder.id);
      if (!isSelected) {
        _controller.toggleFolderSelection(folder, true);
        return;
      }
      _showBatchActionsSheet();
      return;
    }

    _showFolderActions(folder);
  }

  Future<void> _showShareLinkDialog({ManagedFile? file, IndexedFolder? folder}) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _ShareLinkDialog(
        controller: _controller,
        file: file,
        folder: folder,
      ),
    );
  }

  Future<void> _showFileActions(ManagedFile file) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('获取分享链接'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showShareLinkDialog(file: file);
                },
              ),
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('下载到目录'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _downloadFile(file);
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('移动到...'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showMoveItemsToFolderDialog(files: <ManagedFile>[file]);
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline_rounded),
                title: const Text('重命名'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showRenameDialog(file);
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline),
                title: const Text('设置存储方式'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showMoveDialog(<ManagedFile>[file]);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Color(0xFF8C2F1B),
                ),
                title: const Text('删除文件'),
                textColor: const Color(0xFF8C2F1B),
                iconColor: const Color(0xFF8C2F1B),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _confirmDeleteItems(files: <ManagedFile>[file]);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showFolderActions(IndexedFolder folder) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                leading: Icon(_folderIcon(folder)),
                title: const Text('打开文件夹'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openFolder(folder.id);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('获取分享链接'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showShareLinkDialog(folder: folder);
                },
              ),
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('下载为压缩包'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _downloadFolderArchive(folder);
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('管理文件夹'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showFolderManagementDialog(folder);
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline),
                title: const Text('移动到其他文件夹'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showMoveItemsToFolderDialog(
                    folders: <IndexedFolder>[folder],
                  );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Color(0xFF8C2F1B),
                ),
                title: const Text('删除文件夹'),
                textColor: const Color(0xFF8C2F1B),
                iconColor: const Color(0xFF8C2F1B),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _confirmDeleteItems(folders: <IndexedFolder>[folder]);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSettingsPage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;
        final contentMaxWidth = isWide ? 960.0 : double.infinity;

        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: contentMaxWidth),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: isWide
                  ? _buildSettingsWideLayout()
                  : _buildSettingsNarrowLayout(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettingsWideLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          flex: 5,
          child: Column(
            children: [
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  return PanelCard(
                    title: '空间概览',
                    child: Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: StorageChart(
                            pieSize: 140,
                            segments: <StorageSegment>[
                              StorageSegment(
                                label: '已用空间',
                                bytes: _controller.diskTotalBytes - _controller.diskFreeBytes,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              StorageSegment(
                                label: '可用空间',
                                bytes: _controller.diskFreeBytes,
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 20,
                          runSpacing: 12,
                          children: [
                            FilledButton.tonal(
                              onPressed: _controller.busy ? null : _healthCheck,
                              child: const Text('健康检查'),
                            ),
                            OutlinedButton(
                              onPressed: _controller.busy ? null : _showServerLatencyDialog,
                              child: const Text('测速'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              PanelCard(
                title: '图片预览',
                child: _buildPreviewThresholdSlider(),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              PanelCard(
                title: '下载目录',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SelectableText(
                      _controller.hasDownloadDirectory
                          ? _controller.downloadDirectory
                          : '当前未设置固定下载目录',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.tonalIcon(
                      onPressed: _chooseDownloadDirectory,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('选择文件下载目录'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              PanelCard(
                title: '缓存管理',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _controller.cacheBusy
                          ? '正在统计临时内容大小...'
                          : '当前临时内容大小: ${_controller.cacheSizeLabel}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: _controller.cacheBusy
                              ? null
                              : () async {
                                  final success = await _controller.clearCache();
                                  if (!mounted) {
                                    return;
                                  }
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(success ? '缓存已清除' : '缓存清除失败，请查看日志'),
                                    ),
                                  );
                                },
                          icon: _controller.cacheBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.cleaning_services_outlined),
                          label: const Text('一键清除缓存'),
                        ),
                        IconButton(
                          onPressed: _controller.cacheBusy
                              ? null
                              : () {
                                  _controller.refreshCacheSize();
                                },
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              PanelCard(
                title: '回收站',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('管理已删除的文件，可恢复或永久删除。',
                        style: TextStyle(fontSize: 13)),
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TrashPage(baseUrl: _controller.baseUrl),
                          ),
                        );
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('打开回收站'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsNarrowLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return PanelCard(
              title: '空间概览',
              child: Column(
                children: [
                  StorageChart(
                    segments: <StorageSegment>[
                      StorageSegment(
                        label: '已用空间',
                        bytes: _controller.diskTotalBytes - _controller.diskFreeBytes,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      StorageSegment(
                        label: '可用空间',
                        bytes: _controller.diskFreeBytes,
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 20,
                    runSpacing: 12,
                    children: [
                      FilledButton.tonal(
                        onPressed: _controller.busy ? null : _healthCheck,
                        child: const Text('健康检查'),
                      ),
                      OutlinedButton(
                        onPressed: _controller.busy ? null : _showServerLatencyDialog,
                        child: const Text('测速'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        PanelCard(
          title: '下载目录',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SelectableText(
                _controller.hasDownloadDirectory
                    ? _controller.downloadDirectory
                    : '当前未设置固定下载目录',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _chooseDownloadDirectory,
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('选择文件下载目录'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        PanelCard(
          title: '缓存管理',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _controller.cacheBusy
                    ? '正在统计临时内容大小...'
                    : '当前临时内容大小: ${_controller.cacheSizeLabel}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _controller.cacheBusy
                        ? null
                        : () async {
                            final success = await _controller.clearCache();
                            if (!mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(success ? '缓存已清除' : '缓存清除失败，请查看日志'),
                              ),
                            );
                          },
                    icon: _controller.cacheBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cleaning_services_outlined),
                    label: const Text('一键清除缓存'),
                  ),
                  IconButton(
                    onPressed: _controller.cacheBusy
                        ? null
                        : () {
                            _controller.refreshCacheSize();
                          },
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        PanelCard(
          title: '图片预览',
          child: _buildPreviewThresholdSlider(),
        ),
        const SizedBox(height: 16),
        PanelCard(
          title: '回收站',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('管理已删除的文件，可恢复或永久删除。',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => TrashPage(baseUrl: _controller.baseUrl)),
                  );
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('打开回收站'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewThresholdSlider() {
    final level = _controller.previewThresholdLevel;
    final desc = level <= 0 
        ? '不自动加载预览'
        : level >= 21
        ? '总是自动加载预览'
        : '大于 ${_thresholdLabel(level)} 的图片需手动点击加载预览';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(desc, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            const Text('不加载', style: TextStyle(fontSize: 10)),
            Expanded(
              child: Slider(
                value: level.toDouble(),
                min: 0,
                max: 21,
                divisions: 21,
                label: _thresholdLabel(level),
                onChanged: (v) {
                  final newLevel = v.round();
                  _controller.setPreviewThresholdLevel(newLevel);
                  _manualPreviewThresholdBytes =
                      _controller.previewThresholdBytes;
                },
              ),
            ),
            const Text('总是加载', style: TextStyle(fontSize: 10)),
          ],
        ),
      ],
    );
  }

  String _thresholdLabel(int level) {
    if (level == 0) return '不加载';
    if (level >= 21) return '总是加载';
    final bytes = _controller.previewThresholdBytes;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${bytes ~/ 1024} KB';
    return '${bytes ~/ 1048576} MB';
  }

  Widget _buildPreviewBody(
    ManagedFile file,
    Uint8List? imageBytes,
    List<Uint8List>? pdfPages,
    String? error,
  ) {
    if (_isPdfFile(file)) {
      return _buildPdfPreview(file, imageBytes, pdfPages, error);
    }
    if (_isImageFile(file)) {
      return _buildImagePreview(file, imageBytes, error);
    }
    if (_isOfficeDocument(file)) {
      return _buildFileTypePreview(file);
    }
    if (_isTextFile(file)) {
      return _buildTextPreview(file);
    }
    return _buildFileTypePreview(file);
  }

  Widget _buildPdfPreview(
    ManagedFile file,
    Uint8List? imageBytes,
    List<Uint8List>? pdfPages,
    String? error,
  ) {

    if (_controller.previewLoading && imageBytes == null) {
      final totalBytes = _controller.previewTotalBytes;
      final transferredBytes = _controller.previewTransferredBytes;
      final progressValue = totalBytes == null || totalBytes <= 0
          ? null
          : transferredBytes / totalBytes;
      final progressText = totalBytes == null || totalBytes <= 0
          ? '已加载 ${ManagedFileTile.formatSize(transferredBytes)}'
          : '${ManagedFileTile.formatSize(transferredBytes)} / ${ManagedFileTile.formatSize(totalBytes)}';
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF7F7F7),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.downloading_rounded, size: 56, color: Color(0xFF8A8A8A)),
                  const SizedBox(height: 20),
                  LinearProgressIndicator(value: progressValue),
                  const SizedBox(height: 14),
                  Text(
                    progressValue == null ? '正在获取 PDF…' : '正在获取 PDF… ${(progressValue * 100).clamp(0, 100).toStringAsFixed(1)}%',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(progressText, textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (error != null) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF7F7F7),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(error, textAlign: TextAlign.center),
          ),
        ),
      );
    }

    if (imageBytes == null) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF7F7F7),
          borderRadius: BorderRadius.circular(22),
        ),
        child: const Center(child: Text('PDF 数据为空')),
      );
    }

    return GestureDetector(
      onTap: () {
        if (pdfPages != null && pdfPages.isNotEmpty) {
          _openImageFullscreen(file, pdfPages.first, pdfPages: pdfPages);
        } else {
          _openImageFullscreen(file, imageBytes);
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(22),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: Image.memory(imageBytes, fit: BoxFit.contain),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImagePreview(
    ManagedFile file,
    Uint8List? imageBytes,
    String? error,
  ) {
    final panelDecoration = BoxDecoration(
      color: Colors.white.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(22),
    );

    if (_controller.previewLoading && imageBytes == null) {
      final totalBytes = _controller.previewTotalBytes;
      final transferredBytes = _controller.previewTransferredBytes;
      final progressValue = totalBytes == null || totalBytes <= 0
          ? null
          : transferredBytes / totalBytes;
      final progressText = totalBytes == null || totalBytes <= 0
          ? '已加载 ${ManagedFileTile.formatSize(transferredBytes)}'
          : '${ManagedFileTile.formatSize(transferredBytes)} / ${ManagedFileTile.formatSize(totalBytes)}';
      final percentText = progressValue == null
          ? '正在获取图片...'
          : '正在获取图片... ${(progressValue * 100).clamp(0, 100).toStringAsFixed(1)}%';

      return Container(
        decoration: panelDecoration,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.downloading_rounded,
                    size: 56,
                    color: Color(0xFF8A8A8A),
                  ),
                  const SizedBox(height: 20),
                  LinearProgressIndicator(value: progressValue),
                  const SizedBox(height: 14),
                  Text(
                    percentText,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    progressText,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (error != null) {
      return Container(
        decoration: panelDecoration,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(error, textAlign: TextAlign.center),
          ),
        ),
      );
    }

    if (imageBytes == null) {
      return Container(
        decoration: panelDecoration,
        child: const Center(child: Text('图片数据为空')),
      );
    }

    return GestureDetector(
      onTap: () {
        _openImageFullscreen(file, imageBytes);
      },
      child: Container(
        decoration: panelDecoration,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: Image.memory(imageBytes, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.fullscreen, color: Colors.white70, size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openImageFullscreen(ManagedFile file, Uint8List bytes, {List<Uint8List>? pdfPages}) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.black87,
        transitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, _, _) => _ImageFullscreenViewer(
          file: file,
          imageBytes: bytes,
          pdfPages: pdfPages,
          onFileAction: (action) {
            Navigator.of(context).pop();
            _handleFileContextAction(file, action);
          },
        ),
      ),
    );
  }

  Widget _buildTextPreview(ManagedFile file) {
    final text = _controller.previewTextContent;
    if (_controller.previewLoading && text == null) {
      final transferredBytes = _controller.previewTransferredBytes;
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF7F7F7),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(width: 32, height: 32,
                  child: CircularProgressIndicator(strokeWidth: 2.2)),
              const SizedBox(height: 12),
              Text(
                '正在加载文本… ${ManagedFileTile.formatSize(transferredBytes)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    if (_controller.previewError != null) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF7F7F7),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_controller.previewError!),
          ),
        ),
      );
    }
    if (text == null) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF7F7F7),
          borderRadius: BorderRadius.circular(22),
        ),
        child: const Center(child: Text('无文本内容')),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          text,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildFileTypePreview(ManagedFile file) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              ManagedFileTile.iconForFile(file),
              size: 72,
              color: const Color(0xFF8A725F),
            ),
            const SizedBox(height: 12),
            Text(
              file.indexedName,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(file.mimeType, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaRow(String label, String value, {bool wrapText = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: wrapText
                ? SelectableText(value)
                : Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _buildFilesPanel() {
    if (_controller.currentFolderLoading &&
        !_controller.showingCachedFolderContent) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 12),
            Text('正在加载文件夹内容...', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
    }

    final entries = _browserEntries;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDetail = _isDetailView(constraints);
        if (isDetail != _wasDetailView) {
          _wasDetailView = isDetail;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _controller.clearSelection();
          });
        }

        if (entries.isEmpty) {
          final empty = RefreshIndicator(
            onRefresh: _refreshFiles,
            child: _buildEmptyView(),
          );
          return _wrapWithDrop(empty);
        }

        Widget content;
        if (isDetail) {
          content = _buildDetailTableView();
        } else {
          content = _buildCardListView(entries);
        }

        content = RefreshIndicator(
          onRefresh: _refreshFiles,
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: content),
              if (_controller.currentFolderLoading &&
                  _controller.showingCachedFolderContent)
                _buildLoadingOverlay(),
            ],
          ),
        );

        if (!_supportsDesktopDrop) return content;

        return _wrapWithDrop(content);
      },
    );
  }

  Widget _wrapWithDrop(Widget child) {
    if (!_supportsDesktopDrop) return child;
    return DropTarget(
      onDragEntered: (_) {
        if (_controller.busy) return;
        setState(() => _draggingUpload = true);
      },
      onDragExited: (_) {
        if (!_draggingUpload) return;
        setState(() => _draggingUpload = false);
      },
      onDragDone: (detail) async {
        if (_draggingUpload && mounted) {
          setState(() => _draggingUpload = false);
        }
        final droppedEntries = await _normalizeDroppedEntities(detail.files);
        if (!mounted || droppedEntries.isEmpty) return;
        await _showUploadDialog(
          initialEntries: droppedEntries,
          targetFolderId: _dropTargetFolderId,
        );
        _dropTargetFolderId = null;
      },
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: child),
          if (_draggingUpload) _buildDragOverlay(),
        ],
      ),
    );
  }

  bool _isDetailView(BoxConstraints constraints) =>
      constraints.maxWidth >= constraints.maxHeight * 0.9;

  Widget _buildEmptyView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      physics: const AlwaysScrollableScrollPhysics(),
      children: <Widget>[
        const SizedBox(height: 72),
        Icon(Icons.folder_open_rounded, size: 56, color: Colors.grey.shade400),
        const SizedBox(height: 12),
        Text(
          '当前目录没有可显示的文件或文件夹',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    );
  }

  Widget _buildDetailTableView() {
    return DetailTable(
      files: _controller.sortedFiles,
      folders: _sortedChildFolders,
      selectedFilePaths: _controller.selectedPaths,
      selectedFolderIds: _controller.selectedFolderIds,
      batchMode: _batchMode,
      sortColumn: _sortColumnFromName(_controller.sortColumnName),
      sortDirection: _controller.sortAscending
          ? SortDirection.asc
          : SortDirection.desc,
      columnWidths: _columnWidthsForTable(),
      onFileTap: (file, isCtrlHeld) {
        if (isCtrlHeld) {
          _controller.toggleSelection(
              file, !_controller.selectedPaths.contains(file.path));
        } else {
          _controller.clearSelection();
          _controller.toggleSelection(file, true);
        }
      },
      onFolderTap: (folder, isCtrlHeld) {
        if (isCtrlHeld) {
          _controller.toggleFolderSelection(
              folder, !_controller.selectedFolderIds.contains(folder.id));
        } else {
          _controller.clearSelection();
          _controller.toggleFolderSelection(folder, true);
        }
      },
      onFileDoubleTap: (file) => _showPreviewDialog(file),
      onFolderDoubleTap: (folder) => _openFolder(folder.id),
      onFileContextMenu: (file, position) {
              final selected = _controller.selectedFiles;
              if (selected.length > 1 &&
                  selected.any((f) => f.path == file.path)) {
                _showDesktopContextMenu(
                    file: file, position: position,
                    isBatch: true, selectedFiles: selected);
              } else {
                _showDesktopContextMenu(
                    file: file, position: position);
              }
            },
      onFolderContextMenu: (folder, position) {
              final selected = _controller.selectedFolders;
              if (selected.length > 1 &&
                  selected.any((f) => f.id == folder.id)) {
                _showDesktopContextMenu(
                    folder: folder, position: position,
                    isBatch: true, selectedFolders: selected);
              } else {
                _showDesktopContextMenu(
                    folder: folder, position: position);
              }
            },
      onToggleFileSelection: _controller.toggleSelection,
      onToggleFolderSelection: _controller.toggleFolderSelection,
      onSortChanged: (col) => _controller.setSortColumn(_columnName(col)),
      onColumnWidthsChanged: (widths) {
        final converted = <String, double>{
          for (final e in widths.entries) _columnName(e.key): e.value,
        };
        _controller.saveColumnWidths(converted);
      },
      onDragToFolder: (folder) => _dropTargetFolderId = folder.id,
      onFolderHover: (folder) => _dropTargetFolderId = folder.id,
      onFolderUnhover: () => _dropTargetFolderId = null,
      onFolderAcceptDrop: (folder, files) {
        if (files.isNotEmpty) {
          _showMoveItemsToFolderDialog(
            files: files,
            targetFolderId: folder.id,
          );
        }
      },
      isDesktop: _supportsDesktopDrop,
      folderIcon: _folderIcon,
    );
  }

  Widget _buildCardListView(List<_BrowserEntry> entries) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.folder != null) {
          final folder = entry.folder!;
          return DragTarget<List<ManagedFile>>(
            onWillAcceptWithDetails: (_) => true,
            onAcceptWithDetails: (details) {
              final files = details.data;
              if (files.isNotEmpty) {
                _showMoveItemsToFolderDialog(
                  files: files,
                  targetFolderId: folder.id,
                );
              }
            },
            builder: (context, candidateData, rejectedData) {
              final isHovering = candidateData.isNotEmpty;
              Widget tile = _FolderListTile(
                folder: folder,
                icon: _folderIcon(folder),
                selected: _controller.selectedFolderIds.contains(folder.id),
                highlightDrop: isHovering,
                subtitle: _folderSubtitle(folder),
                onTap: _supportsDesktopDrop
                    ? () => _handleFolderTapDesktop(folder)
                    : () => _handleFolderTap(folder),
                onLongPress: () => _handleFolderLongPress(folder),
              );
              if (_supportsDesktopDrop) {
                tile = GestureDetector(
                  onDoubleTap: () => _openFolder(folder.id),
                  onSecondaryTapDown: (details) {
                    final selected = _controller.selectedFolders;
                    if (selected.length > 1 &&
                        selected.any((f) => f.id == folder.id)) {
                      _showDesktopContextMenu(
                          folder: folder, position: details.globalPosition,
                          isBatch: true, selectedFolders: selected);
                    } else {
                      _showDesktopContextMenu(
                          folder: folder, position: details.globalPosition);
                    }
                  },
                  child: tile,
                );
              }
              return tile;
            },
          );
        }
        final file = entry.file!;
        final isSelected = _controller.selectedPaths.contains(file.path);

        Widget fileTile = ManagedFileTile(
          file: file,
          selected: isSelected,
          onTap: _supportsDesktopDrop
              ? () => _handleFileTapDesktop(file)
              : () => _handleFileTap(file),
          onLongPress: () => _handleFileLongPress(file),
        );

        // 桌面端：右击打开上下文菜单
        if (_supportsDesktopDrop) {
          fileTile = GestureDetector(
            onSecondaryTapDown: (details) {
              final selected = _controller.selectedFiles;
              if (selected.length > 1 && selected.any((f) => f.path == file.path)) {
                _showDesktopContextMenu(
                    file: file, position: details.globalPosition,
                    isBatch: true, selectedFiles: selected);
              } else {
                _showDesktopContextMenu(
                    file: file, position: details.globalPosition);
              }
            },
            child: fileTile,
          );
        }

        // 桌面端：长按拖拽移动文件
        if (_supportsDesktopDrop) {
          fileTile = LongPressDraggable<List<ManagedFile>>(
            data: () {
              if (isSelected && _controller.hasSelection) {
                return _controller.selectedFiles;
              }
              return <ManagedFile>[file];
            }(),
            delay: const Duration(milliseconds: 300),
            feedback: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.drive_file_move_outline, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      isSelected && _controller.hasSelection
                          ? '移动 ${_controller.selectedItemCount} 项'
                          : '移动文件',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
            child: fileTile,
          );
        }

        return fileTile;
      },
    );
  }

  Widget _buildLoadingOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: const Alignment(0, 0.55),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(18),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x22000000),
                  blurRadius: 18,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                  const SizedBox(width: 10),
                  Text('正在获取文件夹内容...',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDragOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.74),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          ),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(20),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 18,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.file_upload_outlined, size: 36),
                  const SizedBox(height: 10),
                  Text('松开以上传文件或文件夹',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text(
                    '将上传到 ${_controller.currentFolderPathLabel}，文件夹会保留原有层级。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showDesktopContextMenu({
    ManagedFile? file,
    IndexedFolder? folder,
    Offset? position,
    bool isBatch = false,
    List<ManagedFile>? selectedFiles,
    List<IndexedFolder>? selectedFolders,
  }) async {
    final items = <PopupMenuEntry<String>>[];
    if (file != null) {
      if (isBatch && selectedFiles != null) {
        items.addAll(_batchFileContextMenuItems(selectedFiles));
      } else {
        items.addAll(_fileContextMenuItems(file));
      }
    } else if (folder != null) {
      if (isBatch && selectedFolders != null) {
        items.addAll(_batchFolderContextMenuItems(selectedFolders));
      } else {
        items.addAll(_folderContextMenuItems(folder));
      }
    }

    // 如果已有打开的菜单，先关闭
    if (_contextMenuOpen) {
      final nav = Navigator.of(context);
      nav.pop();
      // 等待关闭动画完成
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _contextMenuOpen = true;

    final result = await showMenu<String>(
      context: context,
      position: position != null
          ? RelativeRect.fromLTRB(
              position.dx, position.dy, position.dx + 1, position.dy + 1)
          : const RelativeRect.fromLTRB(100, 100, 101, 101),
      items: items,
    );

    _contextMenuOpen = false;
    if (result == null) return;
    if (file != null) {
      if (isBatch && selectedFiles != null) {
        await _handleBatchFileContextAction(selectedFiles, result);
      } else {
        await _handleFileContextAction(file, result);
      }
    } else if (folder != null) {
      if (isBatch && selectedFolders != null) {
        await _handleBatchFolderContextAction(selectedFolders, result);
      } else {
        await _handleFolderContextAction(folder, result);
      }
    }
  }

  List<PopupMenuEntry<String>> _fileContextMenuItems(ManagedFile file) => [
    const PopupMenuItem(value: 'download', child: ListTile(leading: Icon(Icons.download_rounded), title: Text('下载到目录'), contentPadding: EdgeInsets.zero)),
    PopupMenuItem(value: 'shareLink', child: ListTile(leading: const Icon(Icons.share_outlined), title: const Text('获取分享链接'), contentPadding: EdgeInsets.zero)),
    const PopupMenuItem(value: 'move', child: ListTile(leading: Icon(Icons.folder_open_rounded), title: Text('移动到...'), contentPadding: EdgeInsets.zero)),
    const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.drive_file_rename_outline_rounded), title: Text('重命名'), contentPadding: EdgeInsets.zero)),
    const PopupMenuItem(value: 'storage', child: ListTile(leading: Icon(Icons.drive_file_move_outline), title: Text('设置存储方式'), contentPadding: EdgeInsets.zero)),
    const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline_rounded, color: Color(0xFF8C2F1B)), title: Text('删除文件', style: TextStyle(color: Color(0xFF8C2F1B))), contentPadding: EdgeInsets.zero)),
  ];

  List<PopupMenuEntry<String>> _folderContextMenuItems(IndexedFolder folder) => [
    const PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.folder_open_rounded), title: Text('打开文件夹'), contentPadding: EdgeInsets.zero)),
    const PopupMenuItem(value: 'downloadArchive', child: ListTile(leading: Icon(Icons.archive_outlined), title: Text('下载为压缩包'), contentPadding: EdgeInsets.zero)),
    const PopupMenuItem(value: 'manage', child: ListTile(leading: Icon(Icons.settings_outlined), title: Text('管理文件夹'), contentPadding: EdgeInsets.zero)),
    const PopupMenuItem(value: 'moveFolder', child: ListTile(leading: Icon(Icons.drive_file_move_outline), title: Text('移动到其他文件夹'), contentPadding: EdgeInsets.zero)),
    const PopupMenuItem(value: 'deleteFolder', child: ListTile(leading: Icon(Icons.delete_outline_rounded, color: Color(0xFF8C2F1B)), title: Text('删除文件夹', style: TextStyle(color: Color(0xFF8C2F1B))), contentPadding: EdgeInsets.zero)),
  ];

  Future<void> _handleFileContextAction(ManagedFile file, String action) async {
    switch (action) {
      case 'shareLink': await _showShareLinkDialog(file: file);
      case 'download': await _downloadFile(file);
      case 'move': await _showMoveItemsToFolderDialog(files: [file]);
      case 'rename': await _showRenameDialog(file);
      case 'storage': await _showMoveDialog([file]);
      case 'delete': await _confirmDeleteItems(files: [file]);
    }
  }

  Future<void> _handleFolderContextAction(IndexedFolder folder, String action) async {
    switch (action) {
      case 'open': await _openFolder(folder.id);
      case 'downloadArchive': await _downloadFolderArchive(folder);
      case 'manage': await _showFolderManagementDialog(folder);
      case 'moveFolder': await _showMoveItemsToFolderDialog(folders: [folder]);
      case 'deleteFolder': await _confirmDeleteItems(folders: [folder]);
    }
  }

  List<PopupMenuEntry<String>> _batchFileContextMenuItems(
      List<ManagedFile> files) => [
    PopupMenuItem(value: 'batchMove', child: ListTile(leading: const Icon(Icons.folder_open_rounded), title: Text('批量移动 (${files.length})'), contentPadding: EdgeInsets.zero)),
    PopupMenuItem(value: 'batchStorage', child: ListTile(leading: const Icon(Icons.drive_file_move_outline), title: const Text('批量设置存储方式'), contentPadding: EdgeInsets.zero)),
    PopupMenuItem(value: 'batchDelete', child: ListTile(leading: const Icon(Icons.delete_outline_rounded, color: Color(0xFF8C2F1B)), title: Text('批量删除 (${files.length})', style: const TextStyle(color: Color(0xFF8C2F1B))), contentPadding: EdgeInsets.zero)),
  ];

  List<PopupMenuEntry<String>> _batchFolderContextMenuItems(
      List<IndexedFolder> folders) => [
    PopupMenuItem(value: 'batchMoveFolder', child: ListTile(leading: const Icon(Icons.drive_file_move_outline), title: Text('批量移动 (${folders.length})'), contentPadding: EdgeInsets.zero)),
    PopupMenuItem(value: 'batchDeleteFolder', child: ListTile(leading: const Icon(Icons.delete_outline_rounded, color: Color(0xFF8C2F1B)), title: Text('批量删除 (${folders.length})', style: const TextStyle(color: Color(0xFF8C2F1B))), contentPadding: EdgeInsets.zero)),
  ];

  Future<void> _handleBatchFileContextAction(
      List<ManagedFile> files, String action) async {
    switch (action) {
      case 'batchMove':
        await _showMoveItemsToFolderDialog(files: files);
      case 'batchStorage':
        await _showMoveDialog(files);
      case 'batchDelete':
        await _confirmDeleteItems(files: files);
    }
  }

  Future<void> _handleBatchFolderContextAction(
      List<IndexedFolder> folders, String action) async {
    switch (action) {
      case 'batchMoveFolder':
        await _showMoveItemsToFolderDialog(folders: folders);
      case 'batchDeleteFolder':
        await _confirmDeleteItems(folders: folders);
    }
  }

  // ---- 列映射辅助 ----
  static DetailColumn? _sortColumnFromName(String? name) => switch (name) {
    'name' => DetailColumn.name,
    'type' => DetailColumn.type,
    'size' => DetailColumn.size,
    'uploadedAt' => DetailColumn.uploadedAt,
    _ => null,
  };

  static String _columnName(DetailColumn col) => switch (col) {
    DetailColumn.name => 'name',
    DetailColumn.type => 'type',
    DetailColumn.size => 'size',
    DetailColumn.uploadedAt => 'uploadedAt',
  };

  Map<DetailColumn, double> _columnWidthsForTable() {
    final persisted = _controller.columnWidths;
    return <DetailColumn, double>{
      for (final col in DetailColumn.values)
        col: persisted[_columnName(col)] ?? 0,
    };
  }

  Widget _buildHomePage() {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _buildPathBar(),
        ),
        Expanded(child: _buildFilesPanel()),
      ],
    );
  }

  Widget _buildPathBar() {
    final breadcrumbs = _controller.folderBreadcrumbs;
    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: <Widget>[
          _PathButton(
            label: '/',
            icon: Icons.home_outlined,
            active: breadcrumbs.isEmpty,
            onTap: () => _openFolder(null),
          ),
          for (var index = 0; index < breadcrumbs.length; index++) ...<Widget>[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              child: Text('/'),
            ),
            _PathButton(
              label: breadcrumbs[index].name,
              icon: _folderIcon(breadcrumbs[index]),
              active: index == breadcrumbs.length - 1,
              onTap: () => _openFolder(breadcrumbs[index].id),
              onLongPress: () => _showFolderActions(breadcrumbs[index]),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return PopScope(
          canPop: true,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            // 文件页且在子文件夹中 → 返回上一级
            if (_currentIndex == 0 && _controller.currentFolderId != null) {
              _openFolder(_controller.folderById(_controller.currentFolderId)?.parentId);
              return;
            }
            // 否则允许退出
            Navigator.of(context).pop();
          },
          child: Scaffold(
          extendBody: true,
          appBar: AppBar(
            titleSpacing: 20,
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            title: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _showServerPresetBottomSheet,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '勇气大存储',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.expand_more_rounded, size: 18),
                  ],
                ),
              ),
            ),
            actions: <Widget>[
              if (_currentIndex == 0)
                IconButton(
                  tooltip: _batchMode ? '退出批量模式' : '进入批量模式',
                  onPressed: _toggleBatchMode,
                  icon: Icon(
                    _batchMode
                        ? Icons.checklist_rtl_rounded
                        : Icons.checklist_rounded,
                  ),
                ),
              if (_currentIndex == 0)
                PopupMenuButton<_HomeActionMenuItem>(
                  tooltip: '新建或上传',
                  onSelected: (value) {
                    switch (value) {
                      case _HomeActionMenuItem.uploadFile:
                        _showUploadDialog();
                      case _HomeActionMenuItem.uploadFolder:
                        _showUploadDialog(pickDirectory: true);
                      case _HomeActionMenuItem.createFolder:
                        _showCreateFolderDialog();
                    }
                  },
                  itemBuilder: (context) =>
                      const <PopupMenuEntry<_HomeActionMenuItem>>[
                        PopupMenuItem<_HomeActionMenuItem>(
                          value: _HomeActionMenuItem.uploadFile,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.upload_file_rounded),
                            title: Text('上传文件'),
                          ),
                        ),
                        PopupMenuItem<_HomeActionMenuItem>(
                          value: _HomeActionMenuItem.uploadFolder,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.drive_folder_upload_outlined),
                            title: Text('上传文件夹'),
                          ),
                        ),
                        PopupMenuItem<_HomeActionMenuItem>(
                          value: _HomeActionMenuItem.createFolder,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.create_new_folder_outlined),
                            title: Text('新建文件夹'),
                          ),
                        ),
                      ],
                  icon: const Icon(Icons.add_rounded),
                ),
              IconButton(
                tooltip: '操作日志',
                onPressed: _showLogsDialog,
                icon: const Icon(Icons.terminal_rounded),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Container(
            color: Colors.white,
            child: SafeArea(
              child: _currentIndex == 0
                  ? _buildHomePage()
                  : _buildSettingsPage(),
            ),
          ),
          bottomNavigationBar: NavigationBar(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            height: 74,
            destinations: const <NavigationDestination>[
              NavigationDestination(
                icon: Icon(Icons.folder_copy_outlined),
                selectedIcon: Icon(Icons.folder_copy_rounded),
                label: '文件',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings_rounded),
                label: '设置',
              ),
            ],
          ),
          ),
        );
      },
    );
  }
}

class _UploadDialogResult {
  const _UploadDialogResult({
    required this.entries,
    required this.permanent,
    this.folderId,
  });

  final List<FileSystemEntity> entries;
  final bool permanent;
  final String? folderId;
}

class _MoveToFolderDialogResult {
  const _MoveToFolderDialogResult({
    required this.folderId,
    required this.password,
  });

  final String? folderId;
  final String password;
}

class _BaseUrlPresetDialogResult {
  const _BaseUrlPresetDialogResult({required this.name, required this.baseUrl});

  final String name;
  final String baseUrl;
}

enum _ServerPresetSheetActionType { add, edit, delete, select }

class _ServerPresetSheetAction {
  const _ServerPresetSheetAction._({required this.type, this.preset});

  const _ServerPresetSheetAction.add()
    : this._(type: _ServerPresetSheetActionType.add);

  const _ServerPresetSheetAction.edit(BaseUrlPreset preset)
    : this._(type: _ServerPresetSheetActionType.edit, preset: preset);

  const _ServerPresetSheetAction.delete(BaseUrlPreset preset)
    : this._(type: _ServerPresetSheetActionType.delete, preset: preset);

  const _ServerPresetSheetAction.select(BaseUrlPreset preset)
    : this._(type: _ServerPresetSheetActionType.select, preset: preset);

  final _ServerPresetSheetActionType type;
  final BaseUrlPreset? preset;
}

class _CreateFolderDialogResult {
  const _CreateFolderDialogResult({
    required this.name,
    required this.visibility,
    required this.password,
    required this.encrypted,
    required this.allowDirectDownload,
  });

  final String name;
  final String visibility;
  final String password;
  final bool encrypted;
  final bool allowDirectDownload;
}

enum _FolderManagementAction { save, delete }

class _FolderManagementDialogResult {
  const _FolderManagementDialogResult({
    required this.action,
    this.name,
    this.parentId,
    this.encrypted,
    this.allowDirectDownload,
    this.currentPassword,
    this.newPassword,
  });

  final _FolderManagementAction action;
  final String? name;
  final String? parentId;
  final bool? encrypted;
  final bool? allowDirectDownload;
  final String? currentPassword;
  final String? newPassword;
}

enum _HomeActionMenuItem { uploadFile, uploadFolder, createFolder }

class _BrowserEntry {
  const _BrowserEntry.folder(this.folder) : file = null;

  const _BrowserEntry.file(this.file) : folder = null;

  final IndexedFolder? folder;
  final ManagedFile? file;
}

class _PresetTag extends StatelessWidget {
  const _PresetTag({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: TextStyle(
            color: foregroundColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _PathButton extends StatelessWidget {
  const _PathButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final child = active
        ? FilledButton.tonalIcon(
            onPressed: onTap,
            icon: Icon(icon, size: 16),
            label: Text(label),
          )
        : OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 16),
            label: Text(label),
          );
    if (onLongPress == null) {
      return child;
    }
    return GestureDetector(onLongPress: onLongPress, child: child);
  }
}

class _FolderListTile extends StatelessWidget {
  const _FolderListTile({
    required this.folder,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    this.subtitle,
    this.highlightDrop = false,
  });

  final IndexedFolder folder;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final String? subtitle;
  final bool highlightDrop;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(
      context,
    ).textTheme.titleSmall?.copyWith(fontSize: 14, height: 1.15);
    final metaStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: const Color(0xFF5F5F5F),
      fontSize: 11,
      height: 1.2,
    );

    final bgColor = highlightDrop
        ? Theme.of(context).colorScheme.primaryContainer
        : selected
        ? const Color(0xFFF3F3F3)
        : Colors.white;

    return Material(
      color: bgColor,
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
                child: Icon(icon, size: 20, color: const Color(0xFF6A625A)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle ?? (folder.encrypted ? '${folder.path}  ·  加密' : folder.path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: metaStyle,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              selected
                  ? Container(
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
                      ),
                    )
                  : const Icon(
                      Icons.chevron_right_rounded,
                      color: Color(0xFF8A8A8A),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateFolderDialog extends StatefulWidget {
  const _CreateFolderDialog({required this.parentPathLabel});

  final String parentPathLabel;

  @override
  State<_CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<_CreateFolderDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _passwordController;
  String _visibility = 'public';
  String? _validationMessage;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    final normalizedName = _nameController.text.trim();
    final normalizedPassword = _passwordController.text.trim();
    if (normalizedName.isEmpty) {
      setState(() { _validationMessage = '请输入文件夹名称'; });
      return;
    }
    if (_visibility == 'encrypted' && normalizedPassword.isEmpty) {
      setState(() { _validationMessage = '加密文件夹必须设置密码'; });
      return;
    }
    Navigator.of(context).pop(_CreateFolderDialogResult(
      name: normalizedName,
      visibility: _visibility,
      encrypted: _visibility == 'encrypted',
      allowDirectDownload: false,
      password: normalizedPassword,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建索引文件夹'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '父级: ${widget.parentPathLabel}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '文件夹名称'),
            ),
            if (_validationMessage != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _validationMessage!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _visibility,
              decoration: const InputDecoration(labelText: '可见性'),
              items: const [
                DropdownMenuItem(value: 'public', child: Text('公开（永久公开链接）')),
                DropdownMenuItem(value: 'private', child: Text('非公开（客户端访问）')),
                DropdownMenuItem(value: 'encrypted', child: Text('加密（需要密码）')),
              ],
              onChanged: (value) {
                setState(() {
                  _visibility = value ?? 'public';
                  _validationMessage = null;
                  if (_visibility != 'encrypted') {
                    _passwordController.clear();
                  }
                });
              },
            ),
            if (_visibility == 'encrypted') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: '设置密码'),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建')),
      ],
    );
  }
}

class _BaseUrlPresetDialog extends StatefulWidget {
  const _BaseUrlPresetDialog({this.preset});

  final BaseUrlPreset? preset;

  @override
  State<_BaseUrlPresetDialog> createState() => _BaseUrlPresetDialogState();
}

class _BaseUrlPresetDialogState extends State<_BaseUrlPresetDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  String? _validationMessage;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.preset?.name ?? '');
    _baseUrlController = TextEditingController(
      text: widget.preset?.baseUrl ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  void _submit() {
    final normalizedName = _nameController.text.trim();
    final normalizedBaseUrl = _baseUrlController.text.trim();
    if (normalizedName.isEmpty) {
      setState(() {
        _validationMessage = '请输入预设名称';
      });
      return;
    }

    final validationMessage = FileManagerController.validateBaseUrl(
      normalizedBaseUrl,
    );
    if (validationMessage != null) {
      setState(() {
        _validationMessage = validationMessage;
      });
      return;
    }

    Navigator.of(context).pop(
      _BaseUrlPresetDialogResult(
        name: normalizedName,
        baseUrl: normalizedBaseUrl,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.preset == null ? '新增服务端预设' : '编辑服务端预设'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '预设名称'),
              onChanged: (_) {
                if (_validationMessage == null) {
                  return;
                }
                setState(() {
                  _validationMessage = null;
                });
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _baseUrlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://example.com',
              ),
              onChanged: (_) {
                if (_validationMessage == null) {
                  return;
                }
                setState(() {
                  _validationMessage = null;
                });
              },
            ),
            if (_validationMessage != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _validationMessage!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.preset == null ? '保存' : '更新'),
        ),
      ],
    );
  }
}

class _ServerLatencyDialog extends StatefulWidget {
  const _ServerLatencyDialog({required this.controller});

  final FileManagerController controller;

  @override
  State<_ServerLatencyDialog> createState() => _ServerLatencyDialogState();
}

class _ServerLatencyDialogState extends State<_ServerLatencyDialog> {
  late final Future<List<BaseUrlLatencyResult>?> _future;

  IconData _latencyIconFor(BaseUrlLatencyResult result) {
    if (!result.success) {
      return Icons.error_outline_rounded;
    }

    final latency = result.latencyMilliseconds ?? 0;
    if (latency <= 100) {
      return Icons.signal_wifi_4_bar_rounded;
    }
    if (latency <= 250) {
      return Icons.network_wifi_3_bar_rounded;
    }
    if (latency <= 500) {
      return Icons.network_wifi_2_bar_rounded;
    }
    return Icons.network_wifi_1_bar_rounded;
  }

  @override
  void initState() {
    super.initState();
    _future = Future<List<BaseUrlLatencyResult>?>.delayed(
      Duration.zero,
      widget.controller.measureBaseUrlLatencies,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('服务器测速结果'),
      content: SizedBox(
        width: 500,
        child: FutureBuilder<List<BaseUrlLatencyResult>?>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 180,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('正在测速，请稍候...'),
                    ],
                  ),
                ),
              );
            }

            final results = snapshot.data;
            if (results == null || results.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('测速未完成，请稍后重试。'),
              );
            }

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: results
                    .map((result) {
                      final latencyLabel = result.success
                          ? '${result.latencyMilliseconds} ms'
                          : '测速失败';
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(_latencyIconFor(result)),
                        title: Text(result.preset.name),
                        subtitle: Text(
                          '${result.preset.baseUrl}\n$latencyLabel',
                        ),
                        isThreeLine: true,
                      );
                    })
                    .toList(growable: false),
              ),
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _ImageFullscreenViewer extends StatefulWidget {
  const _ImageFullscreenViewer({
    required this.file,
    required this.imageBytes,
    this.pdfPages,
    required this.onFileAction,
  });

  final ManagedFile file;
  final Uint8List imageBytes;
  final List<Uint8List>? pdfPages;
  final void Function(String action) onFileAction;

  @override
  State<_ImageFullscreenViewer> createState() => _ImageFullscreenViewerState();
}

class _ImageFullscreenViewerState extends State<_ImageFullscreenViewer>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  Size _viewportSize = Size.zero;
  late final AnimationController _snapController;
  late final CurvedAnimation _snapCurve;
  Matrix4Tween? _snapTween;
  Timer? _settleTimer;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _snapCurve = CurvedAnimation(
      parent: _snapController,
      curve: Curves.easeOutCubic,
    );
    _snapCurve.addListener(_onSnapTick);
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _snapCurve.removeListener(_onSnapTick);
    _snapCurve.dispose();
    _snapController.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _onSnapTick() {
    if (_snapTween == null) return;
    _transform.value = _snapTween!.transform(_snapCurve.value);
  }

  double get _currentScale {
    final m = _transform.value;
    return m.getMaxScaleOnAxis();
  }

  void _zoom(double delta) {
    _cancelSnap();
    final newScale = (_currentScale + delta).clamp(0.5, 8.0);
    final size = _viewportSize;
    if (size != Size.zero) {
      final cx = size.width / 2;
      final cy = size.height / 2;
      final t = Matrix4.identity();
      t.setEntry(0, 3, cx * (1 - newScale));
      t.setEntry(1, 3, cy * (1 - newScale));
      t.setEntry(0, 0, newScale);
      t.setEntry(1, 1, newScale);
      _transform.value = t;
    }
    // 缩放后自动居中回弹
    _snapToCenter(animate: false);
  }

  /// 终止所有待执行/进行中的回弹动画
  void _cancelSnap() {
    _settleTimer?.cancel();
    _snapController.stop();
  }

  /// 延迟触发回弹，等待 InteractiveViewer 惯性移动结束
  void _scheduleSnap() {
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      _snapToCenter();
    });
  }

  void _snapToCenter({bool animate = true}) {
    final matrix = _transform.value;
    final scale = matrix.getMaxScaleOnAxis();
    final screenW = _viewportSize.width;
    final screenH = _viewportSize.height;
    if (screenW <= 0 || screenH <= 0) return;

    // 子控件实际尺寸：多页 PDF 时高度 = 屏幕高度 × 页数
    final numPages = widget.pdfPages?.length ?? 1;
    final childW = screenW;
    final childH = screenH * numPages;

    // 缩小回弹：scale < 1.0 时恢复到 1.0（宽度占满屏幕）
    final fitScale = 1.0;
    final effectiveScale = scale < fitScale - 0.01 ? fitScale : scale;

    final scaledW = childW * effectiveScale;
    final scaledH = childH * effectiveScale;
    final translateX = matrix.getTranslation().x;
    final translateY = matrix.getTranslation().y;

    double targetX = translateX;
    double targetY = translateY;

    // 水平：仅当图片左右两边同时超出屏幕时才跳过居中
    final leftEdge = translateX;
    final rightEdge = translateX + scaledW;
    final bothHEdgesExceed = leftEdge < -0.5 && rightEdge > screenW + 0.5;
    if (!bothHEdgesExceed) {
      targetX = (screenW - scaledW) / 2;
    }

    final topEdge = translateY;
    final bottomEdge = translateY + scaledH;

    if (numPages > 1) {
      // 多页 PDF：垂直仅做首页顶部 / 末页底部回弹
      final topVisible = topEdge > -0.5;
      final bottomVisible = bottomEdge < screenH + 0.5;
      if (topVisible && bottomVisible) {
        targetY = (screenH - scaledH) / 2; // 内容适配屏幕 → 居中
      } else if (topVisible) {
        targetY = 0; // 首页顶部不留白
      } else if (bottomVisible) {
        targetY = screenH - scaledH; // 末页底部不留白
      }
    } else {
      // 单图：垂直居中回弹（两边未同时超出时）
      final bothVEdgesExceed =
          topEdge < -0.5 && bottomEdge > screenH + 0.5;
      if (!bothVEdgesExceed) {
        targetY = (screenH - scaledH) / 2;
      }
    }

    if ((targetX - translateX).abs() < 0.5 &&
        (targetY - translateY).abs() < 0.5) {
      return;
    }

    final targetMatrix = Matrix4.identity()
      ..setEntry(0, 0, effectiveScale)
      ..setEntry(1, 1, effectiveScale)
      ..setEntry(0, 3, targetX)
      ..setEntry(1, 3, targetY);

    if (!animate) {
      _transform.value = targetMatrix;
      return;
    }

    _snapTween = Matrix4Tween(
      begin: matrix,
      end: targetMatrix,
    );
    _snapController
      ..reset()
      ..forward();
  }

  Widget _buildPageView(List<Uint8List> pages) {
    final screenW = _viewportSize.width;
    final screenH = _viewportSize.height;
    final children = <Widget>[];
    for (var i = 0; i < pages.length; i++) {
      children.add(
        SizedBox(
          width: screenW,
          height: screenH,
          child: Image.memory(pages[i], fit: BoxFit.contain),
        ),
      );
    }
    return Column(children: children);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LayoutBuilder(
        builder: (context, constraints) {
          _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
          final isMultiPage =
              widget.pdfPages != null && widget.pdfPages!.isNotEmpty;

          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    _zoom(-event.scrollDelta.dy / 200);
                  }
                },
                child: GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  onLongPress: () => _showImageActionMenu(),
                  onSecondaryTapDown: (details) =>
                      _showImageContextMenu(details.globalPosition),
                  child: InteractiveViewer(
                    constrained: false,
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    transformationController: _transform,
                    minScale: 0.5,
                    maxScale: 8.0,
                    onInteractionStart: (_) => _cancelSnap(),
                    onInteractionEnd: (_) => _scheduleSnap(),
                    child: isMultiPage
                        ? _buildPageView(widget.pdfPages!)
                        : SizedBox(
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                            child: Image.memory(
                              widget.imageBytes,
                              fit: BoxFit.contain,
                            ),
                          ),
                  ),
                ),
              ),
              // 关闭按钮
              Positioned(
                top: MediaQuery.of(context).padding.top + 4,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showImageActionMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('下载到目录'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onFileAction('download');
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('获取分享链接'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onFileAction('shareLink');
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('重命名'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onFileAction('rename');
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: Color(0xFF8C2F1B)),
              title: const Text('删除文件',
                  style: TextStyle(color: Color(0xFF8C2F1B))),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onFileAction('delete');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showImageContextMenu(Offset position) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx + 1, position.dy + 1),
      items: <PopupMenuEntry<String>>[
        const PopupMenuItem(
            value: 'download',
            child: ListTile(
                leading: Icon(Icons.download_rounded),
                title: Text('下载到目录'),
                contentPadding: EdgeInsets.zero)),
        const PopupMenuItem(
            value: 'shareLink',
            child: ListTile(
                leading: Icon(Icons.share_outlined),
                title: Text('获取分享链接'),
                contentPadding: EdgeInsets.zero)),
        const PopupMenuItem(
            value: 'rename',
            child: ListTile(
                leading: Icon(Icons.drive_file_rename_outline_rounded),
                title: Text('重命名'),
                contentPadding: EdgeInsets.zero)),
        const PopupMenuItem(
            value: 'delete',
            child: ListTile(
                leading: Icon(Icons.delete_outline_rounded,
                    color: Color(0xFF8C2F1B)),
                title: Text('删除文件',
                    style: TextStyle(color: Color(0xFF8C2F1B))),
                contentPadding: EdgeInsets.zero)),
      ],
    ).then((action) {
      if (action != null) widget.onFileAction(action);
    });
  }
}

class _TransferDialogState {
  const _TransferDialogState({
    required this.fileName,
    required this.summaryText,
    required this.detailText,
    required this.transferredBytes,
    required this.totalBytes,
    required this.active,
  });

  final String fileName;
  final String? summaryText;
  final String? detailText;
  final int transferredBytes;
  final int? totalBytes;
  final bool active;

  _TransferDialogState copyWith({
    String? fileName,
    String? summaryText,
    String? detailText,
    int? transferredBytes,
    int? totalBytes,
    bool? active,
  }) {
    return _TransferDialogState(
      fileName: fileName ?? this.fileName,
      summaryText: summaryText ?? this.summaryText,
      detailText: detailText ?? this.detailText,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      active: active ?? this.active,
    );
  }
}


// ===================================================================
// 分享链接管理对话框
// ===================================================================

class _ShareLinkDialog extends StatefulWidget {
  const _ShareLinkDialog({
    required this.controller,
    this.file,
    this.folder,
  });

  final FileManagerController controller;
  final ManagedFile? file;
  final IndexedFolder? folder;

  @override
  State<_ShareLinkDialog> createState() => _ShareLinkDialogState();
}

class _ShareLinkDialogState extends State<_ShareLinkDialog> {
  final TextEditingController _daysController = TextEditingController(text: '7');
  bool _creating = false;
  List<Map<String, dynamic>> _links = [];
  bool _loadingLinks = true;
  String? _error;

  FileManagerController get _c => widget.controller;
  ManagedFile? get _file => widget.file;
  IndexedFolder? get _folder => widget.folder;

  bool get _isPublic {
    if (_folder != null) return _folder!.effectiveVisibility == 'public';
    if (_file != null) return _file!.effectiveVisibility == 'public';
    return true;
  }

  String get _resourceType => _file != null ? 'file' : 'folder';
  String? get _filePath => _file?.path;
  String? get _folderId => _folder?.id;

  String? get _folderPassword {
    final fid = _folder?.id ?? _file?.folderId;
    if (fid == null) return null;
    final folder = _c.folderById(fid);
    if (folder?.effectiveVisibility == 'encrypted') {
      return _c.unlockedFolderPassword(fid);
    }
    return null;
  }

  String get _permanentUrl {
    final raw = _file?.url ?? _file?.path ?? '';
    return _resolveAbsoluteUrl(raw);
  }

  String _resolveAbsoluteUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return '';
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = _c.baseUrl.replaceAll(RegExp(r'/+$'), '');
    if (!url.startsWith('/')) url = '/$url';
    return '$base$url';
  }

  @override
  void initState() {
    super.initState();
    if (!_isPublic) _loadShareLinks();
    else _loadingLinks = false;
  }

  @override
  void dispose() {
    _daysController.dispose();
    super.dispose();
  }

  Future<void> _loadShareLinks() async {
    setState(() { _loadingLinks = true; _error = null; });
    try {
      final client = ImageBedClient(baseUrl: _c.baseUrl);
      final result = await client.listShareLinks(
        publicKeyPem: Global.publicKeyPem,
        resourceType: _resourceType,
        filePath: _filePath,
        folderId: _folderId,
      );
      final data = result['data'] as Map<String, dynamic>? ?? {};
      final links = (data['links'] as List<dynamic>? ?? [])
          .map((l) => Map<String, dynamic>.from(l as Map))
          .toList();
      setState(() { _links = links; _loadingLinks = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loadingLinks = false; });
    }
  }

  Future<void> _createLink() async {
    final daysText = _daysController.text.trim();
    final days = int.tryParse(daysText) ?? 7;
    if (days < 1 || days > 365) {
      setState(() => _error = '有效天数必须在 1-365 之间');
      return;
    }
    setState(() { _creating = true; _error = null; });
    try {
      final client = ImageBedClient(baseUrl: _c.baseUrl);
      await client.createShareLink(
        publicKeyPem: Global.publicKeyPem,
        resourceType: _resourceType,
        filePath: _filePath,
        folderId: _folderId,
        folderPassword: _folderPassword,
        expiresInDays: days,
      );
      await _loadShareLinks();
      setState(() => _creating = false);
    } catch (e) {
      setState(() { _error = e.toString(); _creating = false; });
    }
  }

  Future<void> _revokeLink(String linkId) async {
    try {
      final client = ImageBedClient(baseUrl: _c.baseUrl);
      await client.revokeShareLink(publicKeyPem: Global.publicKeyPem, linkId: linkId);
      await _loadShareLinks();
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('链接已复制到剪切板')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('访问链接'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_file != null) ...[
              Text(_file!.indexedName,
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
            ],
            if (_folder != null) ...[
              Text(_folder!.name,
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
            ],

            // 公开：仅显示永久链接
            if (_isPublic) ...[
              const SizedBox(height: 8),
              const Text('此资源为公开可见，访问链接永久有效',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: SelectableText(_permanentUrl,
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () => _copyText(_permanentUrl),
                  tooltip: '复制链接',
                ),
              ]),
            ] else ...[
              // 非公开/加密：创建 + 列表
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _daysController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '有效天数 (1-365)',
                      border: OutlineInputBorder(), isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonal(
                  onPressed: _creating ? null : _createLink,
                  child: _creating
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('创建新链接'),
                ),
              ]),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(
                    color: Theme.of(context).colorScheme.error, fontSize: 12)),
              ],
              const SizedBox(height: 16),
              Text('当前有效链接', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              if (_loadingLinks)
                const Center(child: CircularProgressIndicator())
              else if (_links.isEmpty)
                const Text('暂无有效分享链接', style: TextStyle(fontSize: 12, color: Colors.grey))
              else
                ..._links.map((link) {
                  final token = link['token'] ?? '';
                  final absUrl = _resolveAbsoluteUrl('/s/$token');
                  final expiresAt = link['expiresAt'] ?? '';
                  final accessCount = link['accessCount'] ?? 0;
                  final expiryText = ManagedFileTile.formatUploadedAt(
                      expiresAt.toString());
                  return Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                              child: SelectableText(absUrl,
                                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                            ),
                            IconButton(icon: const Icon(Icons.copy, size: 18),
                                onPressed: () => _copyText(absUrl), tooltip: '复制'),
                            IconButton(icon: const Icon(Icons.close, size: 18, color: Colors.red),
                                onPressed: () => _revokeLink(link['id']?.toString() ?? ''),
                                tooltip: '撤销'),
                          ]),
                          Text('有效期至 $expiryText  ·  访问 $accessCount 次',
                              style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                    ),
                  );
                }),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
      ],
    );
  }
}
