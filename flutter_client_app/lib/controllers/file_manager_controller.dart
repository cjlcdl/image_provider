import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pdfx/pdfx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:courage_storage/models/base_url_preset.dart';
import 'package:courage_storage/models/file_list_response.dart';
import 'package:courage_storage/models/indexed_folder.dart';
import 'package:courage_storage/models/managed_file.dart';
import 'package:courage_storage/services/image_bed_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef FolderPasswordResolver = Future<String?> Function(
  IndexedFolder folder,
  String purpose,
);

typedef BatchTransferProgressCallback = void Function(
  BatchTransferProgress progress,
);

class BatchTransferProgress {
  const BatchTransferProgress({
    required this.currentItemLabel,
    required this.completedItems,
    required this.succeededItems,
    required this.failedItems,
    required this.totalItems,
    required this.transferredBytes,
    required this.totalBytes,
    required this.statusText,
  });

  final String currentItemLabel;
  final int completedItems;
  final int succeededItems;
  final int failedItems;
  final int totalItems;
  final int transferredBytes;
  final int totalBytes;
  final String statusText;
}

class BatchTransferFailure {
  const BatchTransferFailure({
    required this.type,
    required this.label,
    required this.error,
  });

  final BatchTransferFailureType type;
  final String label;
  final String error;
}

enum BatchTransferFailureType {
  network,
  password,
  serverRejected,
}

extension BatchTransferFailureTypeLabel on BatchTransferFailureType {
  String get label {
    switch (this) {
      case BatchTransferFailureType.network:
        return '网络失败';
      case BatchTransferFailureType.password:
        return '密码失败';
      case BatchTransferFailureType.serverRejected:
        return '服务端拒绝';
    }
  }
}

class BatchUploadResult {
  const BatchUploadResult({
    required this.totalItems,
    required this.succeededItems,
    required this.failedItems,
    required this.failures,
  });

  final int totalItems;
  final int succeededItems;
  final int failedItems;
  final List<BatchTransferFailure> failures;

  bool get success => failedItems == 0;
}

class BaseUrlLatencyResult {
  const BaseUrlLatencyResult({
    required this.preset,
    this.latencyMilliseconds,
    this.error,
  });

  final BaseUrlPreset preset;
  final int? latencyMilliseconds;
  final String? error;

  bool get success => latencyMilliseconds != null && error == null;
}

class FileManagerController extends ChangeNotifier {
  static const String _downloadDirectoryPreferenceKey =
      'download_directory_path';
  static const String _baseUrlPresetsPreferenceKey = 'base_url_presets';
  static const String _selectedBaseUrlPresetIdPreferenceKey =
      'selected_base_url_preset_id';
  static const String _defaultBaseUrlPresetId = '__default_base_url__';
  static const String _columnWidthsPreferenceKey = 'detail_column_widths';
  static const String _previewThresholdPreferenceKey = 'preview_threshold_level';
  static const int _defaultPreviewThresholdLevel = 12; // 2 MB

  /// 指数级预览阈值（字节），索引 0=总是加载，21=无上限
  static const List<int> _previewThresholdLevels = <int>[
    0,           // 不加载
    1024,        // 1 KB
    2048,        // 2 KB
    4096,        // 4 KB
    8192,        // 8 KB
    16384,       // 16 KB
    32768,       // 32 KB
    65536,       // 64 KB
    131072,      // 128 KB
    262144,      // 256 KB
    524288,      // 512 KB
    1048576,     // 1 MB
    2097152,     // 2 MB
    4194304,     // 4 MB
    8388608,     // 8 MB
    16777216,    // 16 MB
    33554432,    // 32 MB
    67108864,    // 64 MB
    134217728,   // 128 MB
    268435456,   // 256 MB
    536870912,   // 512 MB
    9223372036854775807, // 总是加载
  ];
  static const int _previewThresholdMaxLevel = 21;

  FileManagerController({
    required String initialBaseUrl,
    required String publicKeyPem,
  }) : _baseUrl = _normalizeBaseUrl(initialBaseUrl),
       _publicKeyPem = publicKeyPem.trim(),
       _defaultBaseUrlPreset = BaseUrlPreset(
         id: _defaultBaseUrlPresetId,
         name: '默认服务器',
         baseUrl: _normalizeBaseUrl(initialBaseUrl),
         isBuiltIn: true,
       ),
       _selectedBaseUrlPresetId = _defaultBaseUrlPresetId {
    _client = ImageBedClient(baseUrl: _baseUrl);
  }

  late ImageBedClient _client;
  String _baseUrl;
  final String _publicKeyPem;
  final BaseUrlPreset _defaultBaseUrlPreset;
  List<BaseUrlPreset> _customBaseUrlPresets = <BaseUrlPreset>[];
  String _selectedBaseUrlPresetId;
  bool _busy = false;
  bool _previewLoading = false;
  bool _cacheBusy = false;
  final List<String> _logs = <String>['等待操作'];
  int _total = 0;
  int _totalPages = 0;
  int _cacheBytes = 0;
  int _diskTotalBytes = 0;
  int _diskFreeBytes = 0;
  String _downloadDirectory = '';
  List<ManagedFile> _files = const <ManagedFile>[];
  List<IndexedFolder> _folders = const <IndexedFolder>[];
  final Map<String, String> _unlockedFolderPasswords = <String, String>{};
  final Map<String, List<ManagedFile>> _folderContentCache =
      <String, List<ManagedFile>>{};
  final Set<String> _selectedPaths = <String>{};
  final Set<String> _selectedFolderIds = <String>{};
  String _storageFilter = '';
  String _keyword = '';
  int _page = 1;
  int _pageSize = 20;
  String? _currentFolderId;
  bool _currentFolderLoading = false;
  bool _showingCachedFolderContent = false;
  ManagedFile? _previewFile;
  Uint8List? _previewImageBytes;
  List<Uint8List>? _previewPdfPages;
  String? _previewTextContent;
  String? _previewError;
  int _previewTransferredBytes = 0;
  int? _previewTotalBytes;
  String? _lastActionError;
  bool _lastActionWasBusy = false;
  int _previewThresholdLevel = _defaultPreviewThresholdLevel;
  String? _sortColumnName;
  bool _sortAscending = true;
  final Map<String, double> _columnWidths =
      <String, double>{}; // key: DetailColumn.name

  /// 当前排序列名（'name'/'type'/'size'/'uploadedAt'），null=不排序。
  String? get sortColumnName => _sortColumnName;
  bool get sortAscending => _sortAscending;
  Map<String, double> get columnWidths =>
      Map<String, double>.unmodifiable(_columnWidths);

  bool get busy => _busy;
  bool get previewLoading => _previewLoading;
  bool get cacheBusy => _cacheBusy;
  String get logText => _logs.join('\n');
  List<String> get logs => List<String>.unmodifiable(_logs);
  int get total => _total;
  int get totalPages => _totalPages;
  int get cacheBytes => _cacheBytes;
  String get cacheSizeLabel => _formatBytes(_cacheBytes);
  int get diskTotalBytes => _diskTotalBytes;
  int get diskFreeBytes => _diskFreeBytes;
  String get diskTotalSizeLabel => _formatBytes(_diskTotalBytes);
  String get diskFreeSizeLabel => _formatBytes(_diskFreeBytes);
  int get previewThresholdLevel => _previewThresholdLevel;
  int get previewThresholdBytes =>
      _previewThresholdLevels[_previewThresholdLevel.clamp(0, _previewThresholdMaxLevel)];
  String get downloadDirectory => _downloadDirectory;
  bool get hasDownloadDirectory => _downloadDirectory.trim().isNotEmpty;
  List<ManagedFile> get files => List<ManagedFile>.unmodifiable(_files);

  /// 排序后的文件列表（用于详情表视图）。
  List<ManagedFile> get sortedFiles {
    if (_sortColumnName == null) return files;
    final sorted = List<ManagedFile>.from(_files);
    sorted.sort(_fileComparator);
    return List<ManagedFile>.unmodifiable(
      _sortAscending ? sorted : sorted.reversed.toList(),
    );
  }

  /// 排序后的文件夹列表。
  List<IndexedFolder> get sortedFolders {
    if (_sortColumnName == null) return folders;
    final sorted = List<IndexedFolder>.from(_folders);
    sorted.sort(_folderComparator);
    return List<IndexedFolder>.unmodifiable(
      _sortAscending ? sorted : sorted.reversed.toList(),
    );
  }

  int _fileComparator(ManagedFile a, ManagedFile b) {
    switch (_sortColumnName) {
      case 'name':
        final labelA = a.indexedName.isEmpty ? a.systemName : a.indexedName;
        final labelB = b.indexedName.isEmpty ? b.systemName : b.indexedName;
        return labelA.toLowerCase().compareTo(labelB.toLowerCase());
      case 'type':
        return a.mimeType.toLowerCase().compareTo(b.mimeType.toLowerCase());
      case 'size':
        return a.size.compareTo(b.size);
      case 'uploadedAt':
        return (a.uploadedAt ?? '').compareTo(b.uploadedAt ?? '');
      default:
        return 0;
    }
  }

  int _folderComparator(IndexedFolder a, IndexedFolder b) {
    switch (_sortColumnName) {
      case 'name':
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case 'uploadedAt':
        return (a.createdAt ?? '').compareTo(b.createdAt ?? '');
      default:
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
  }
  List<IndexedFolder> get folders => List<IndexedFolder>.unmodifiable(_folders);
  List<ManagedFile> get selectedFiles => _files
      .where((item) => _selectedPaths.contains(item.path))
      .toList(growable: false);
  List<IndexedFolder> get selectedFolders => _folders
      .where((item) => _selectedFolderIds.contains(item.id))
      .toList(growable: false);
  Set<String> get selectedPaths => Set<String>.unmodifiable(_selectedPaths);
  Set<String> get selectedFolderIds =>
      Set<String>.unmodifiable(_selectedFolderIds);
  bool get hasSelection =>
      _selectedPaths.isNotEmpty || _selectedFolderIds.isNotEmpty;
  int get selectedItemCount =>
      _selectedPaths.length + _selectedFolderIds.length;
  String get baseUrl => _baseUrl;
  List<BaseUrlPreset> get baseUrlPresets => List<BaseUrlPreset>.unmodifiable(
    <BaseUrlPreset>[_defaultBaseUrlPreset, ..._customBaseUrlPresets],
  );
  String get selectedBaseUrlPresetId => _selectedBaseUrlPresetId;
  BaseUrlPreset get currentBaseUrlPreset =>
      _resolvePresetById(_selectedBaseUrlPresetId) ?? _defaultBaseUrlPreset;
  String get storageFilter => _storageFilter;
  String get keyword => _keyword;
  int get page => _page;
  int get pageSize => _pageSize;
  String? get currentFolderId => _currentFolderId;
  bool get currentFolderLoading => _currentFolderLoading;
  bool get showingCachedFolderContent => _showingCachedFolderContent;
  ManagedFile? get previewFile => _previewFile;
  Uint8List? get previewImageBytes => _previewImageBytes;
  List<Uint8List>? get previewPdfPages => _previewPdfPages;
  String? get previewTextContent => _previewTextContent;
  String? get previewError => _previewError;
  int get previewTransferredBytes => _previewTransferredBytes;
  int? get previewTotalBytes => _previewTotalBytes;
  String? get lastActionError => _lastActionError;
  bool get lastActionWasBusy => _lastActionWasBusy;

  IndexedFolder? get currentFolder {
    final folderId = _currentFolderId;
    if (folderId == null) {
      return null;
    }
    for (final folder in _folders) {
      if (folder.id == folderId) {
        return folder;
      }
    }
    return null;
  }

  IndexedFolder? folderById(String? folderId) {
    final normalizedFolderId = folderId?.trim() ?? '';
    if (normalizedFolderId.isEmpty) {
      return null;
    }
    for (final folder in _folders) {
      if (folder.id == normalizedFolderId) {
        return folder;
      }
    }
    return null;
  }

  List<IndexedFolder> descendantFoldersOf(String folderId) {
    final normalizedFolderId = folderId.trim();
    if (normalizedFolderId.isEmpty) {
      return const <IndexedFolder>[];
    }

    final childrenByParent = <String?, List<IndexedFolder>>{};
    for (final folder in _folders) {
      childrenByParent.putIfAbsent(folder.parentId, () => <IndexedFolder>[]).add(folder);
    }

    final descendants = <IndexedFolder>[];
    final pending = <String>[normalizedFolderId];
    while (pending.isNotEmpty) {
      final currentId = pending.removeLast();
      final children = childrenByParent[currentId] ?? const <IndexedFolder>[];
      for (final child in children) {
        descendants.add(child);
        pending.add(child.id);
      }
    }

    descendants.sort((left, right) => _compareFolderPath(left, right));
    return descendants;
  }

  List<IndexedFolder> encryptedFoldersForArchive(String folderId) {
    final rootFolder = folderById(folderId);
    if (rootFolder == null) {
      return const <IndexedFolder>[];
    }

    final result = <IndexedFolder>[
      if (rootFolder.encrypted) rootFolder,
      ...descendantFoldersOf(folderId).where((folder) => folder.encrypted),
    ];
    result.sort((left, right) => _compareFolderPath(left, right));
    return result;
  }

  List<IndexedFolder> get currentChildFolders {
    final folderId = _currentFolderId;
    return _folders
        .where((item) => (item.parentId ?? '') == (folderId ?? ''))
        .toList(growable: false)
      ..sort((left, right) => left.name.compareTo(right.name));
  }

  List<IndexedFolder> get folderBreadcrumbs {
    final current = currentFolder;
    if (current == null) {
      return const <IndexedFolder>[];
    }

    final byId = <String, IndexedFolder>{
      for (final folder in _folders) folder.id: folder,
    };
    final chain = <IndexedFolder>[];
    IndexedFolder? cursor = current;
    final seen = <String>{};
    while (cursor != null && seen.add(cursor.id)) {
      chain.add(cursor);
      cursor = byId[cursor.parentId ?? ''];
    }
    return chain.reversed.toList(growable: false);
  }

  String get currentFolderPathLabel => currentFolder?.path ?? '/';

  String _normalizeFolderId(String? folderId) {
    final normalized = folderId?.trim() ?? '';
    return normalized.isEmpty ? 'root' : normalized;
  }

  String _buildFolderViewCacheKey(String? folderId) {
    return '${_normalizeFolderId(folderId)}|$_storageFilter|$_keyword|$_page|$_pageSize';
  }

  ManagedFile? get singleSelectedFile {
    if (_selectedPaths.length != 1) {
      return null;
    }
    final selectedPath = _selectedPaths.first;
    for (final item in _files) {
      if (item.path == selectedPath) {
        return item;
      }
    }
    return null;
  }

  void updateQuery({
    required String storageFilter,
    required String keyword,
    required int page,
    required int pageSize,
  }) {
    _storageFilter = storageFilter;
    _keyword = keyword.trim();
    _page = page;
    _pageSize = pageSize;
    notifyListeners();
  }

  void toggleSelection(ManagedFile file, bool selected) {
    if (selected) {
      _selectedPaths.add(file.path);
    } else {
      _selectedPaths.remove(file.path);
    }
    notifyListeners();
  }

  void toggleFolderSelection(IndexedFolder folder, bool selected) {
    if (selected) {
      _selectedFolderIds.add(folder.id);
    } else {
      _selectedFolderIds.remove(folder.id);
    }
    notifyListeners();
  }

  void clearSelection() {
    _selectedPaths.clear();
    _selectedFolderIds.clear();
   notifyListeners();
  }

  void setCurrentFolder(String? folderId) {
    _currentFolderId = folderId?.trim().isEmpty ?? true
        ? null
        : folderId?.trim();
    _selectedPaths.clear();
    _selectedFolderIds.clear();
    notifyListeners();
  }

  void unlockFolder(String folderId, String password) {
    final normalizedFolderId = folderId.trim();
    final normalizedPassword = password.trim();
    if (normalizedFolderId.isEmpty || normalizedPassword.isEmpty) {
      return;
    }
    _unlockedFolderPasswords[normalizedFolderId] = normalizedPassword;
    notifyListeners();
  }

  String? unlockedFolderPassword(String? folderId) {
    final normalizedFolderId = folderId?.trim() ?? '';
    if (normalizedFolderId.isEmpty) {
      return null;
    }
    return _unlockedFolderPasswords[normalizedFolderId];
  }

  bool isFolderUnlocked(String? folderId) {
    final folder = folderById(folderId);
    if (folder == null || !folder.encrypted) {
      return true;
    }
    return unlockedFolderPassword(folderId) != null;
  }

  Future<bool> openFolder(String? folderId, {String? folderPassword}) async {
    final normalizedFolderId = folderId?.trim().isEmpty ?? true
        ? null
        : folderId?.trim();
    final previousFolderId = _currentFolderId;
    final previousFiles = List<ManagedFile>.from(_files);
    final previousTotal = _total;
    final previousTotalPages = _totalPages;
    final cacheKey = _buildFolderViewCacheKey(normalizedFolderId);
    final cachedFiles = _folderContentCache[cacheKey];
    final effectivePassword = folderPassword?.trim().isNotEmpty == true
        ? folderPassword!.trim()
        : unlockedFolderPassword(normalizedFolderId);

    _currentFolderId = normalizedFolderId;
    _selectedPaths.clear();
    _selectedFolderIds.clear();
    _files = cachedFiles == null
        ? const <ManagedFile>[]
        : List<ManagedFile>.unmodifiable(cachedFiles);
    _total = cachedFiles?.length ?? 0;
    _totalPages = cachedFiles == null ? 0 : 1;
    _currentFolderLoading = true;
    _showingCachedFolderContent = cachedFiles != null;
    notifyListeners();

    final success = await _refreshFilesForFolder(
      normalizedFolderId,
      folderPasswordOverride: effectivePassword,
    );

    _currentFolderLoading = false;
    _showingCachedFolderContent = false;

    if (!success && cachedFiles == null) {
      _currentFolderId = previousFolderId;
      _files = List<ManagedFile>.unmodifiable(previousFiles);
      _total = previousTotal;
      _totalPages = previousTotalPages;
    }

    if (success &&
        normalizedFolderId != null &&
        folderPassword?.trim().isNotEmpty == true) {
      unlockFolder(normalizedFolderId, folderPassword!.trim());
    }

    notifyListeners();
    return success;
  }

  void clearPreview() {
    _previewFile = null;
    _previewImageBytes = null;
    _previewPdfPages = null;
    _previewTextContent = null;
    _previewError = null;
    _previewLoading = false;
    _previewTransferredBytes = 0;
    _previewTotalBytes = null;
    notifyListeners();
  }

  Future<void> loadPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    _downloadDirectory =
        preferences.getString(_downloadDirectoryPreferenceKey)?.trim() ?? '';
    _customBaseUrlPresets = _decodeBaseUrlPresets(
      preferences.getString(_baseUrlPresetsPreferenceKey),
    );
    final preferredPresetId = preferences
        .getString(_selectedBaseUrlPresetIdPreferenceKey)
        ?.trim();
    final preferredPreset = _resolvePresetById(preferredPresetId);
    if (preferredPreset != null) {
      _applyBaseUrlPreset(preferredPreset, notify: false, appendLog: false);
    }
    _loadColumnWidths(preferences);
    final savedLevel =
        preferences.getInt(_previewThresholdPreferenceKey);
    if (savedLevel != null && savedLevel >= 0 && savedLevel <= _previewThresholdMaxLevel) {
      _previewThresholdLevel = savedLevel;
    }
    notifyListeners();
  }

  Future<void> setDownloadDirectory(String directoryPath) async {
    final normalized = directoryPath.trim();
    final preferences = await SharedPreferences.getInstance();
    _downloadDirectory = normalized;
    await preferences.setString(_downloadDirectoryPreferenceKey, normalized);
    notifyListeners();
  }

  Future<BaseUrlPreset> addBaseUrlPreset({
    required String name,
    required String baseUrl,
  }) async {
    final normalizedName = name.trim();
    final normalizedBaseUrl = _normalizeBaseUrl(baseUrl);
    if (normalizedName.isEmpty) {
      throw ArgumentError('请输入预设名称');
    }
    final validationMessage = validateBaseUrl(normalizedBaseUrl);
    if (validationMessage != null) {
      throw ArgumentError(validationMessage);
    }
    if (_hasBaseUrlPreset(normalizedBaseUrl)) {
      throw ArgumentError('该服务器地址已存在');
    }

    final preset = BaseUrlPreset(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: normalizedName,
      baseUrl: normalizedBaseUrl,
    );
    _customBaseUrlPresets = <BaseUrlPreset>[..._customBaseUrlPresets, preset];
    final preferences = await SharedPreferences.getInstance();
    await _persistBaseUrlPreferences(preferences);
    _appendLog('已新增服务端预设: ${preset.name} (${preset.baseUrl})');
    notifyListeners();
    return preset;
  }

  Future<BaseUrlPreset> updateBaseUrlPreset({
    required String presetId,
    required String name,
    required String baseUrl,
  }) async {
    final existingPreset = _resolvePresetById(presetId);
    if (existingPreset == null || existingPreset.isBuiltIn) {
      throw ArgumentError('该预设不支持编辑');
    }

    final normalizedName = name.trim();
    final normalizedBaseUrl = _normalizeBaseUrl(baseUrl);
    if (normalizedName.isEmpty) {
      throw ArgumentError('请输入预设名称');
    }
    final validationMessage = validateBaseUrl(normalizedBaseUrl);
    if (validationMessage != null) {
      throw ArgumentError(validationMessage);
    }
    if (_hasBaseUrlPreset(normalizedBaseUrl, excludingId: presetId)) {
      throw ArgumentError('该服务器地址已存在');
    }

    final updatedPreset = BaseUrlPreset(
      id: existingPreset.id,
      name: normalizedName,
      baseUrl: normalizedBaseUrl,
    );
    _customBaseUrlPresets = _customBaseUrlPresets
        .map((preset) {
          if (preset.id != presetId) {
            return preset;
          }
          return updatedPreset;
        })
        .toList(growable: false);

    final isSelected = presetId == _selectedBaseUrlPresetId;
    if (isSelected && normalizedBaseUrl != _baseUrl) {
      _applyBaseUrlPreset(updatedPreset, appendLog: false, notify: false);
    }

    final preferences = await SharedPreferences.getInstance();
    await _persistBaseUrlPreferences(preferences);
    _appendLog('已更新服务端预设: ${updatedPreset.name} (${updatedPreset.baseUrl})');
    notifyListeners();
    return updatedPreset;
  }

  Future<bool> selectBaseUrlPreset(String presetId) async {
    final preset = _resolvePresetById(presetId);
    if (preset == null) {
      return false;
    }
    final changed =
        preset.id != _selectedBaseUrlPresetId || preset.baseUrl != _baseUrl;
    if (!changed) {
      return false;
    }
    _applyBaseUrlPreset(preset);
    final preferences = await SharedPreferences.getInstance();
    await _persistBaseUrlPreferences(preferences);
    return true;
  }

  Future<List<BaseUrlLatencyResult>?> measureBaseUrlLatencies() async {
    return _runAction<List<BaseUrlLatencyResult>>('服务器测速', () async {
      final futures = baseUrlPresets
          .map(_measureSingleBaseUrlLatency)
          .toList(growable: false);
      return Future.wait(futures);
    });
  }

  Future<bool> removeBaseUrlPreset(String presetId) async {
    final preset = _resolvePresetById(presetId);
    if (preset == null || preset.isBuiltIn) {
      return false;
    }

    final wasSelected = preset.id == _selectedBaseUrlPresetId;
    _customBaseUrlPresets = _customBaseUrlPresets
        .where((item) => item.id != presetId)
        .toList(growable: false);

    if (wasSelected) {
      _applyBaseUrlPreset(_defaultBaseUrlPreset);
      _appendLog('已删除服务端预设: ${preset.name} (${preset.baseUrl})');
    } else {
      _appendLog('已删除服务端预设: ${preset.name} (${preset.baseUrl})');
      notifyListeners();
    }

    final preferences = await SharedPreferences.getInstance();
    await _persistBaseUrlPreferences(preferences);
    return true;
  }

  static String? validateBaseUrl(String value) {
    final normalized = _normalizeBaseUrl(value);
    if (normalized.isEmpty) {
      return '请输入服务器地址';
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return '请输入合法的 http 或 https 地址';
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return '服务器地址仅支持 http 或 https';
    }
    return null;
  }

  Future<bool> healthCheck() async {
    final result = await _runAction<Map<String, dynamic>>(
      '健康检查',
      () => _client.healthCheck(),
    );
    if (result != null) {
      final data = Map<String, dynamic>.from(
        result['data'] as Map<String, dynamic>? ?? <String, dynamic>{},
      );
      _diskTotalBytes = (data['diskTotalBytes'] as num?)?.toInt() ?? 0;
      _diskFreeBytes = (data['diskFreeBytes'] as num?)?.toInt() ?? 0;
      notifyListeners();
    }
    return result != null;
  }

  Future<bool> refreshFolders() async {
    final result = await _runAction<List<IndexedFolder>>(
      '刷新文件夹索引',
      () => _client.listFolders(publicKeyPem: _requirePublicKey(_publicKeyPem)),
    );
    if (result == null) {
      return false;
    }
    _folders = result;
    if (_currentFolderId != null &&
        !_folders.any((folder) => folder.id == _currentFolderId)) {
      _currentFolderId = null;
    }
    final visibleChildFolderIds = currentChildFolders
        .map((folder) => folder.id)
        .toSet();
    _selectedFolderIds.removeWhere(
      (folderId) => !visibleChildFolderIds.contains(folderId),
    );
    notifyListeners();
    return true;
  }

  Future<bool> refreshWorkspace() async {
    await healthCheck();
    final foldersOk = await refreshFolders();
    final filesOk = await refreshFiles();
    return foldersOk && filesOk;
  }

  Future<bool> refreshFiles() async {
    return _refreshFilesForFolder(
      _currentFolderId,
      folderPasswordOverride: unlockedFolderPassword(_currentFolderId),
    );
  }

  Future<bool> _refreshFilesForFolder(
    String? folderId, {
    String? folderPasswordOverride,
  }) async {
    final requestFolderId = folderId ?? 'root';
    final result = await _runAction<FileListResponse>(
      '刷新文件列表',
      () => _client.listFiles(
        publicKeyPem: _requirePublicKey(_publicKeyPem),
        storage: _storageFilter.isEmpty ? null : _storageFilter,
        keyword: _keyword.isEmpty ? null : _keyword,
        folderId: requestFolderId,
        folderPassword: folderPasswordOverride,
        page: _page,
        pageSize: _pageSize,
      ),
    );

    if (result == null) {
      return false;
    }

    _files = List<ManagedFile>.unmodifiable(result.files);
    _total = result.total;
    _totalPages = result.totalPages;
    _folderContentCache[_buildFolderViewCacheKey(folderId)] =
        List<ManagedFile>.unmodifiable(result.files);
    _selectedPaths.removeWhere(
      (path) => !_files.any((item) => item.path == path),
    );
    _syncPreviewFile();
    notifyListeners();
    return true;
  }

  Future<bool> uploadFile({
    required File file,
    required bool permanent,
    String? folderId,
    String? folderPassword,
  }) async {
    return uploadFilesWithProgress(
      files: <File>[file],
      permanent: permanent,
      folderId: folderId,
      folderPassword: folderPassword,
    );
  }

  Future<bool> uploadFileWithProgress({
    required File file,
    required bool permanent,
    String? folderId,
    String? folderPassword,
    TransferProgressCallback? onProgress,
    TransferCancellationToken? cancelToken,
  }) async {
    return uploadFilesWithProgress(
      files: <File>[file],
      permanent: permanent,
      folderId: folderId,
      folderPassword: folderPassword,
      cancelToken: cancelToken,
      onBatchProgress: (progress) {
        onProgress?.call(progress.transferredBytes, progress.totalBytes);
      },
    );
  }

  Future<bool> uploadFilesWithProgress({
    required List<File> files,
    required bool permanent,
    String? folderId,
    String? folderPassword,
    TransferCancellationToken? cancelToken,
    BatchTransferProgressCallback? onBatchProgress,
  }) async {
    final result = await uploadFileSystemEntitiesWithProgress(
      entities: files,
      permanent: permanent,
      folderId: folderId,
      folderPassword: folderPassword,
      cancelToken: cancelToken,
      onBatchProgress: onBatchProgress,
    );
    return result.success;
  }

  Future<BatchUploadResult> uploadFileSystemEntitiesWithProgress({
    required List<FileSystemEntity> entities,
    required bool permanent,
    String? folderId,
    String? folderPassword,
    FolderPasswordResolver? resolveFolderPassword,
    TransferCancellationToken? cancelToken,
    BatchTransferProgressCallback? onBatchProgress,
  }) async {
    final normalizedEntries = await _normalizeUploadEntities(entities);
    if (normalizedEntries.isEmpty) {
      _appendLog('上传失败: 未选择有效的文件或文件夹');
      notifyListeners();
      return const BatchUploadResult(
        totalItems: 0,
        succeededItems: 0,
        failedItems: 0,
        failures: <BatchTransferFailure>[],
      );
    }

    final effectiveFolderId = folderId ?? _currentFolderId;
    final effectiveFolderPassword =
        folderPassword ?? unlockedFolderPassword(effectiveFolderId);
    late final _PreparedUploadSelection prepared;
    try {
      prepared = await _prepareUploadSelection(
        entities: normalizedEntries,
        baseFolderId: effectiveFolderId,
        baseFolderPassword: effectiveFolderPassword,
        resolveFolderPassword: resolveFolderPassword,
      );
    } on StateError catch (error) {
      _appendLog('上传失败: ${error.message}');
      notifyListeners();
      return BatchUploadResult(
        totalItems: normalizedEntries.length,
        succeededItems: 0,
        failedItems: normalizedEntries.length,
        failures: <BatchTransferFailure>[
          BatchTransferFailure(
            type: BatchTransferFailureType.serverRejected,
            label: '准备上传内容',
            error: error.message.toString(),
          ),
        ],
      );
    }

    for (final entry in prepared.resolvedFolderPasswords.entries) {
      unlockFolder(entry.key, entry.value);
    }

    if (prepared.files.isEmpty) {
      _appendLog('上传完成: 已同步空文件夹结构');
      await refreshWorkspace();
      return const BatchUploadResult(
        totalItems: 0,
        succeededItems: 0,
        failedItems: 0,
        failures: <BatchTransferFailure>[],
      );
    }

    onBatchProgress?.call(
      BatchTransferProgress(
        currentItemLabel: prepared.files.first.displayLabel,
        completedItems: 0,
        succeededItems: 0,
        failedItems: 0,
        totalItems: prepared.files.length,
        transferredBytes: 0,
        totalBytes: prepared.totalBytes,
        statusText: '准备上传，共 ${prepared.files.length} 项',
      ),
    );

    final result = await _runTransferAction<BatchUploadResult>(
      permanent ? '批量上传' : '批量临时上传',
      () async {
        var completedItems = 0;
        var completedBytes = 0;
        var succeededItems = 0;
        final failures = <BatchTransferFailure>[];
        for (final file in prepared.files) {
          if (cancelToken?.isCancelled ?? false) {
            throw const TransferCancelledException('上传');
          }
          try {
            await _uploadPreparedFile(
              file,
              permanent: permanent,
              cancelToken: cancelToken,
              onProgress: (transferredBytes, totalBytesIgnored) {
                onBatchProgress?.call(
                  BatchTransferProgress(
                    currentItemLabel: file.displayLabel,
                    completedItems: completedItems,
                    succeededItems: succeededItems,
                    failedItems: failures.length,
                    totalItems: prepared.files.length,
                    transferredBytes: completedBytes + transferredBytes,
                    totalBytes: prepared.totalBytes,
                    statusText:
                        '正在上传第 ${completedItems + 1} / ${prepared.files.length} 项，已成功 $succeededItems 项，失败 ${failures.length} 项',
                  ),
                );
                if (totalBytesIgnored == null) {
                  return;
                }
              },
            );
            succeededItems += 1;
          } catch (error) {
            final message = error is StateError
                ? error.message.toString()
                : error.toString();
            failures.add(
              BatchTransferFailure(
                type: _classifyBatchUploadFailure(error),
                label: file.displayLabel,
                error: _normalizeBatchUploadFailureMessage(error),
              ),
            );
            _appendLog('上传失败: ${file.displayLabel} -> $message');
          }
          completedItems += 1;
          completedBytes += file.size;
          onBatchProgress?.call(
            BatchTransferProgress(
              currentItemLabel: file.displayLabel,
              completedItems: completedItems,
              succeededItems: succeededItems,
              failedItems: failures.length,
              totalItems: prepared.files.length,
              transferredBytes: completedBytes,
              totalBytes: prepared.totalBytes,
              statusText:
                  '已处理 $completedItems / ${prepared.files.length} 项，成功 $succeededItems 项，失败 ${failures.length} 项',
            ),
          );
        }
        return BatchUploadResult(
          totalItems: prepared.files.length,
          succeededItems: succeededItems,
          failedItems: failures.length,
          failures: List<BatchTransferFailure>.unmodifiable(failures),
        );
      },
    );
    if (result == null) {
      return BatchUploadResult(
        totalItems: prepared.files.length,
        succeededItems: 0,
        failedItems: prepared.files.length,
        failures: const <BatchTransferFailure>[],
      );
    }

    await refreshWorkspace();
    return result;
  }

  Future<bool> renameFile({
    required ManagedFile file,
    required String indexedName,
  }) async {
    final trimmedName = indexedName.trim();
    if (trimmedName.isEmpty) {
      _appendLog('重命名失败: 新索引文件名不能为空');
      notifyListeners();
      return false;
    }

    final result = await _runAction<Map<String, dynamic>>(
      '重命名索引文件名',
      () => _client.renameIndexedName(
        relativePath: file.path,
        indexedName: trimmedName,
        publicKeyPem: _requirePublicKey(_publicKeyPem),
      ),
    );
    if (result == null) {
      return false;
    }

    await refreshFiles();
    return true;
  }

  Future<bool> moveFiles({
    required List<ManagedFile> files,
    required String targetStorage,
  }) async {
    final uniqueFiles = _uniqueFilesByPath(files);
    if (uniqueFiles.isEmpty) {
      _appendLog('移动失败: 请至少选择一个文件');
      notifyListeners();
      return false;
    }

    final result = await _runAction<int>(
      uniqueFiles.length == 1 ? '设置存储方式' : '批量设置文件存储方式',
      () async {
        var movedCount = 0;
        for (final file in uniqueFiles) {
          await _client.moveFile(
            relativePath: file.path,
            targetStorage: targetStorage,
            publicKeyPem: _requirePublicKey(_publicKeyPem),
          );
          movedCount += 1;
        }
        return movedCount;
      },
    );
    if (result == null) {
      return false;
    }

    _selectedPaths.removeWhere(
      (path) => uniqueFiles.any((item) => item.path == path),
    );
    await refreshFiles();
    return true;
  }

  Future<File?> downloadFileToDirectory({
    required ManagedFile file,
    required String directoryPath,
  }) async {
    final savedFile = await _runAction<File>('下载文件', () async {
      return _client.downloadListedFile(
        file: file,
        saveDirectory: directoryPath,
      );
    });

    if (savedFile != null) {
      _appendLog('文件已保存到: ${savedFile.path}');
      notifyListeners();
    }
    return savedFile;
  }

  Future<File?> downloadFileToConfiguredDirectory(ManagedFile file) async {
    if (!hasDownloadDirectory) {
      _appendLog('下载失败: 未设置固定下载目录');
      notifyListeners();
      return null;
    }

    final saveFile = await _resolveUniqueDownloadFile(
      directoryPath: _downloadDirectory,
      file: file,
    );

    final savedFile = await _runAction<File>('下载文件', () async {
      return _client.downloadToFile(
        relativePath: file.path,
        savePath: saveFile.path,
      );
    });

    if (savedFile != null) {
      _appendLog('文件已保存到: ${savedFile.path}');
      notifyListeners();
    }
    return savedFile;
  }

  Future<File?> downloadFileToConfiguredDirectoryWithProgress(
    ManagedFile file, {
    TransferProgressCallback? onProgress,
    TransferCancellationToken? cancelToken,
    void Function(int resumedBytes)? onResume,
  }) async {
    if (!hasDownloadDirectory) {
      _appendLog('下载失败: 未设置固定下载目录');
      notifyListeners();
      return null;
    }

    final saveFile = await _resolveUniqueDownloadFile(
      directoryPath: _downloadDirectory,
      file: file,
    );

    // 检测断点续传
    final partialFile = File('${saveFile.path}.part');
    if (await partialFile.exists()) {
      final resumedBytes = await partialFile.length();
      if (resumedBytes > 0) {
        _appendLog(
          '检测到未完成的下载（已传输 ${_formatBytes(resumedBytes)}），将尝试续传',
        );
        onResume?.call(resumedBytes);
      }
    }

    final resolvedDownloadPath = await _resolveDownloadPath(file);
    final savedFile = await _runTransferAction<File>('下载文件', () async {
      return _client.downloadToFile(
        relativePath: resolvedDownloadPath,
        savePath: saveFile.path,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    });

    if (savedFile != null) {
      _appendLog('文件已保存到: ${savedFile.path}');
      notifyListeners();
    }
    return savedFile;
  }

  Future<File?> downloadFolderArchiveToConfiguredDirectoryWithProgress(
    IndexedFolder folder, {
    Map<String, String> folderPasswords = const <String, String>{},
    TransferProgressCallback? onProgress,
    TransferCancellationToken? cancelToken,
  }) async {
    if (!hasDownloadDirectory) {
      _appendLog('下载失败: 未设置固定下载目录');
      notifyListeners();
      return null;
    }

    final saveFile = await _resolveUniqueNamedFile(
      directoryPath: _downloadDirectory,
      fileName: '${folder.name}.zip',
    );
    final mergedPasswords = <String, String>{};
    for (final entry in _unlockedFolderPasswords.entries) {
      if (entry.key.trim().isEmpty || entry.value.trim().isEmpty) {
        continue;
      }
      mergedPasswords[entry.key] = entry.value;
    }
    for (final entry in folderPasswords.entries) {
      final folderId = entry.key.trim();
      final password = entry.value.trim();
      if (folderId.isEmpty || password.isEmpty) {
        continue;
      }
      mergedPasswords[folderId] = password;
      unlockFolder(folderId, password);
    }

    final savedFile = await _runTransferAction<File>('下载文件夹压缩包', () async {
      return _client.downloadFolderArchiveToFile(
        publicKeyPem: _requirePublicKey(_publicKeyPem),
        folderId: folder.id,
        folderPasswords: mergedPasswords,
        savePath: saveFile.path,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    });

    if (savedFile != null) {
      _appendLog('文件夹压缩包已保存到: ${savedFile.path}');
      notifyListeners();
    }
    return savedFile;
  }

  Future<void> refreshCacheSize() async {
    if (_cacheBusy) {
      return;
    }

    _cacheBusy = true;
    notifyListeners();

    try {
      final cacheDirectory = await getTemporaryDirectory();
      _cacheBytes = await _calculateDirectorySize(cacheDirectory);
    } finally {
      _cacheBusy = false;
      notifyListeners();
    }
  }

  Future<bool> clearCache() async {
    if (_cacheBusy) {
      return false;
    }

    _cacheBusy = true;
    notifyListeners();

    try {
      final cacheDirectory = await getTemporaryDirectory();
      final beforeSize = await _calculateDirectorySize(cacheDirectory);
      await _clearDirectoryChildren(cacheDirectory);

      // 清理分享上传缓存目录
      final sharedUploadsDir = Directory(
        '${cacheDirectory.path}${Platform.pathSeparator}shared_uploads',
      );
      if (await sharedUploadsDir.exists()) {
        await sharedUploadsDir.delete(recursive: true);
      }

      // 清理续传上传状态文件
      await _client.clearResumableUploadStates();

      _cacheBytes = await _calculateDirectorySize(cacheDirectory);
      _appendLog(
        '已清除缓存: ${_formatBytes(beforeSize)}（含分享缓存和续传状态）',
      );
      return true;
    } catch (error) {
      _appendLog('清除缓存失败: $error');
      return false;
    } finally {
      _cacheBusy = false;
      notifyListeners();
    }
  }

  Future<Uint8List?> downloadFileBytes(ManagedFile file) async {
    final bytes = await _runAction<Uint8List>('下载字节', () async {
      final downloadPath = await _resolveDownloadPath(file);
      return _client.downloadBytes(downloadPath);
    });
    if (bytes != null) {
      _appendLog('已读取字节数: ${bytes.length}');
      notifyListeners();
    }
    return bytes;
  }

  Future<void> loadPreview(ManagedFile file) async {
    if (_previewFile?.path == file.path &&
        (_previewImageBytes != null || _previewLoading)) {
      return;
    }

    _previewFile = file;
    _previewError = null;
    _previewImageBytes = null;
    _previewPdfPages = null;
    _previewTextContent = null;
    _previewTransferredBytes = 0;
    _previewTotalBytes = null;

    // 文本文件（含 PDF / 二进制 Office）→ 加载为字符串
    if (_isPreviewableTextFile(file)) {
      _previewLoading = true;
      notifyListeners();
      try {
        final bytes = await _client.downloadBytesWithProgress(
          file.path,
          onProgress: (transferredBytes, totalBytes) {
            if (_previewFile?.path != file.path) return;
            _previewTransferredBytes = transferredBytes;
            _previewTotalBytes = totalBytes;
            notifyListeners();
          },
        );
        if (_previewFile?.path != file.path) return;
        _previewTextContent = utf8.decode(bytes, allowMalformed: true);
        _previewTransferredBytes = bytes.length;
        _previewTotalBytes ??= bytes.length;
      } catch (error) {
        if (_previewFile?.path != file.path) return;
        _previewError = '预览加载失败: $error';
        _appendLog(_previewError!);
      } finally {
        if (_previewFile?.path == file.path) {
          _previewLoading = false;
          notifyListeners();
        }
      }
      return;
    }

    // 非文本文件 → 作为图片/二进制下载
    _previewLoading = true;
    notifyListeners();

    try {
      final bytes = await _client.downloadBytesWithProgress(
        file.path,
        onProgress: (transferredBytes, totalBytes) {
          if (_previewFile?.path != file.path) {
            return;
          }
          _previewTransferredBytes = transferredBytes;
          _previewTotalBytes = totalBytes;
          notifyListeners();
        },
      );
      if (_previewFile?.path != file.path) {
        return;
      }
      if (_isPdfFile(file)) {
        final pages = await _renderPdfAllPages(bytes);
        _previewPdfPages = pages;
        if (pages != null && pages.isNotEmpty) {
          _previewImageBytes = pages.first;
          _appendLog('已渲染 PDF 预览 (${pages.length} 页)');
        } else {
          _previewError = 'PDF 渲染失败，请查看操作日志';
        }
      } else {
        _previewImageBytes = bytes;
      }
      _previewTransferredBytes = bytes.length;
      _previewTotalBytes ??= bytes.length;
      _appendLog(
        '已加载图片: ${file.indexedName.isEmpty ? file.systemName : file.indexedName}',
      );
    } catch (error) {
      if (_previewFile?.path != file.path) {
        return;
      }
      _previewError = '图片加载失败: $error';
      _appendLog(_previewError!);
    } finally {
      if (_previewFile?.path == file.path) {
        _previewLoading = false;
        notifyListeners();
      }
    }
  }

  /// 综合 indexedName / systemName / extension 字段判断文件扩展名
  static bool _fileHasExtension(ManagedFile file, Set<String> extensions) {
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

  bool _isPreviewableTextFile(ManagedFile file) {
    const textExtensions = <String>{
      '.txt', '.md', '.json', '.xml', '.csv', '.log',
      '.yaml', '.yml', '.ini', '.cfg', '.conf', '.sh',
      '.bat', '.py', '.js', '.ts', '.dart', '.html', '.css',
      '.c', '.cpp', '.h', '.java', '.kt', '.swift', '.rs',
      '.php', '.rb', '.go', '.sql', '.lua', '.pl', '.r',
    };
    if (_fileHasExtension(file, textExtensions)) return true;
    return file.mimeType.startsWith('text/');
  }

  bool _isPdfFile(ManagedFile file) {
    return _fileHasExtension(file, const {'.pdf'});
  }

  /// 使用 pdfx 渲染 PDF 每一页为独立 PNG（最多前 20 页，1200px 宽）
  Future<List<Uint8List>?> _renderPdfAllPages(Uint8List pdfBytes) async {
    PdfDocument? document;
    try {
      document = await PdfDocument.openData(pdfBytes);
      final totalPages = document.pagesCount;
      if (totalPages < 1) return null;

      final maxPages = totalPages < 20 ? totalPages : 20;
      final pageImages = <Uint8List>[];
      const previewWidth = 1200.0;

      for (var pageNum = 1; pageNum <= maxPages; pageNum++) {
        final page = await document.getPage(pageNum);
        try {
          final aspectRatio =
              page.height > 0 ? page.width / page.height : 1.0 / 1.414;
          final pageImage = await page.render(
            width: previewWidth,
            height: previewWidth / aspectRatio,
            format: PdfPageImageFormat.png,
          );
          if (pageImage?.bytes != null && pageImage!.bytes.isNotEmpty) {
            pageImages.add(Uint8List.fromList(pageImage.bytes));
          }
        } finally {
          await page.close();
        }
      }

      return pageImages.isEmpty ? null : pageImages;
    } catch (error) {
      _appendLog('PDF 页面渲染失败: $error');
      return null;
    } finally {
      await document?.close();
    }
  }

  Future<bool> deleteFiles(List<ManagedFile> files) async {
    final uniqueFiles = _uniqueFilesByPath(files);
    if (uniqueFiles.isEmpty) {
      _appendLog('删除失败: 请至少选择一个文件');
      notifyListeners();
      return false;
    }

    final paths = uniqueFiles.map((file) => file.path).toList(growable: false);
    final result = await _runAction<Map<String, dynamic>>(
      paths.length == 1 ? '删除文件' : '批量删除',
      () => paths.length == 1
          ? _client.deleteFile(
              relativePath: paths.first,
              publicKeyPem: _requirePublicKey(_publicKeyPem),
            )
          : _client.batchDeleteFiles(
              relativePaths: paths,
              publicKeyPem: _requirePublicKey(_publicKeyPem),
            ),
    );
    if (result == null) {
      return false;
    }

    _selectedPaths.removeWhere((path) => paths.contains(path));
    await refreshFiles();
    return true;
  }

  String _requirePublicKey(String pem) {
    final normalized = pem.trim();
    if (normalized.isEmpty) {
      throw StateError('请先粘贴服务端公钥');
    }
    return normalized;
  }

  Future<bool> createFolder({
    required String name,
    String? parentId,
    String visibility = 'public',
    bool encrypted = false,
    bool allowDirectDownload = false,
    String? password,
    String? parentFolderPassword,
  }) async {
    final result = await _runAction<Map<String, dynamic>>(
      '新建文件夹',
      () => _client.createFolder(
        publicKeyPem: _requirePublicKey(_publicKeyPem),
        name: name,
        parentId: parentId,
        visibility: visibility,
        encrypted: encrypted,
        allowDirectDownload: allowDirectDownload,
        password: password,
        parentFolderPassword: parentFolderPassword,
      ),
    );
    if (result == null) {
      return false;
    }
    final refreshed = await refreshFolders();
    if (!refreshed) {
      _appendLog('新建文件夹失败: 文件夹列表刷新失败，无法确认创建结果');
      return false;
    }
    return true;
  }

  Future<bool> updateFolder({
    required String folderId,
    String? name,
    String? parentId,
    bool? encrypted,
    bool? allowDirectDownload,
    String? currentPassword,
    String? targetParentPassword,
    String? newPassword,
  }) async {
    final result = await _runAction<Map<String, dynamic>>(
      '更新文件夹',
      () => _client.updateFolder(
        publicKeyPem: _requirePublicKey(_publicKeyPem),
        folderId: folderId,
        name: name,
        parentId: parentId,
        includeParentId: true,
        encrypted: encrypted,
        allowDirectDownload: allowDirectDownload,
        currentPassword: currentPassword,
        targetParentPassword: targetParentPassword,
        newPassword: newPassword,
      ),
    );
    if (result == null) {
      return false;
    }
    if (currentPassword != null && currentPassword.trim().isNotEmpty) {
      unlockFolder(folderId, currentPassword);
    }
    if (newPassword != null && newPassword.trim().isNotEmpty) {
      unlockFolder(folderId, newPassword);
    }
    await refreshWorkspace();
    return true;
  }

  Future<bool> deleteFolder({
    required String folderId,
    String? currentPassword,
  }) async {
    final result = await _runAction<Map<String, dynamic>>(
      '删除文件夹',
      () => _client.deleteFolder(
        publicKeyPem: _requirePublicKey(_publicKeyPem),
        folderId: folderId,
        currentPassword: currentPassword,
      ),
    );
    if (result == null) {
      return false;
    }
    _unlockedFolderPasswords.remove(folderId);
    if (_currentFolderId == folderId) {
      _currentFolderId = null;
    }
    await refreshWorkspace();
    return true;
  }

  Future<bool> deleteFolders({
    required List<IndexedFolder> folders,
    Map<String, String> currentPasswords = const <String, String>{},
  }) async {
    final uniqueFolders = _uniqueFoldersById(folders);
    if (uniqueFolders.isEmpty) {
      _appendLog('删除文件夹失败: 请至少选择一个文件夹');
      notifyListeners();
      return false;
    }

    final result = await _runAction<int>(
      uniqueFolders.length == 1 ? '删除文件夹' : '批量删除文件夹',
      () async {
        var deletedCount = 0;
        for (final folder in uniqueFolders) {
          await _client.deleteFolder(
            publicKeyPem: _requirePublicKey(_publicKeyPem),
            folderId: folder.id,
            currentPassword: currentPasswords[folder.id],
          );
          _unlockedFolderPasswords.remove(folder.id);
          _selectedFolderIds.remove(folder.id);
          deletedCount += 1;
        }
        return deletedCount;
      },
    );
    if (result == null) {
      return false;
    }

    await refreshWorkspace();
    return true;
  }

  Future<bool> deleteItems({
    required List<ManagedFile> files,
    required List<IndexedFolder> folders,
    Map<String, String> currentFolderPasswords = const <String, String>{},
  }) async {
    final uniqueFiles = _uniqueFilesByPath(files);
    final uniqueFolders = _uniqueFoldersById(folders);
    if (uniqueFiles.isEmpty && uniqueFolders.isEmpty) {
      _appendLog('删除失败: 请至少选择一个文件或文件夹');
      notifyListeners();
      return false;
    }

    final result = await _runAction<int>(
      uniqueFiles.isNotEmpty && uniqueFolders.isNotEmpty
          ? '批量删除文件和文件夹'
          : uniqueFolders.isNotEmpty
          ? (uniqueFolders.length == 1 ? '删除文件夹' : '批量删除文件夹')
          : (uniqueFiles.length == 1 ? '删除文件' : '批量删除'),
      () async {
        var deletedCount = 0;
        if (uniqueFiles.isNotEmpty) {
          if (uniqueFiles.length == 1) {
            await _client.deleteFile(
              relativePath: uniqueFiles.first.path,
              publicKeyPem: _requirePublicKey(_publicKeyPem),
            );
          } else {
            await _client.batchDeleteFiles(
              relativePaths: uniqueFiles
                  .map((file) => file.path)
                  .toList(growable: false),
              publicKeyPem: _requirePublicKey(_publicKeyPem),
            );
          }
          deletedCount += uniqueFiles.length;
        }
        for (final folder in uniqueFolders) {
          await _client.deleteFolder(
            publicKeyPem: _requirePublicKey(_publicKeyPem),
            folderId: folder.id,
            currentPassword: currentFolderPasswords[folder.id],
          );
          _unlockedFolderPasswords.remove(folder.id);
          deletedCount += 1;
        }
        return deletedCount;
      },
    );
    if (result == null) {
      return false;
    }

    _selectedPaths.removeWhere(
      (path) => uniqueFiles.any((file) => file.path == path),
    );
    _selectedFolderIds.removeWhere(
      (folderId) => uniqueFolders.any((folder) => folder.id == folderId),
    );
    await refreshWorkspace();
    return true;
  }

  Future<bool> moveFilesToFolder({
    required List<ManagedFile> files,
    String? folderId,
    String? targetFolderPassword,
  }) async {
    final uniqueFiles = _uniqueFilesByPath(files);
    if (uniqueFiles.isEmpty) {
      _appendLog('移动到文件夹失败: 请至少选择一个文件');
      notifyListeners();
      return false;
    }

    final result = await _runAction<Map<String, dynamic>>(
      uniqueFiles.length == 1 ? '移动到文件夹' : '批量移动到文件夹',
      () => _client.assignFilesToFolder(
        publicKeyPem: _requirePublicKey(_publicKeyPem),
        relativePaths: uniqueFiles
            .map((file) => file.path)
            .toList(growable: false),
        folderId: folderId,
        targetFolderPassword: targetFolderPassword,
      ),
    );
    if (result == null) {
      return false;
    }
    await refreshFiles();
    return true;
  }

  Future<bool> moveItemsToFolder({
    required List<ManagedFile> files,
    required List<IndexedFolder> folders,
    String? targetFolderId,
    String? targetFolderPassword,
    Map<String, String> sourceFolderPasswords = const <String, String>{},
  }) async {
    final uniqueFiles = _uniqueFilesByPath(files);
    final uniqueFolders = _uniqueFoldersById(folders);
    if (uniqueFiles.isEmpty && uniqueFolders.isEmpty) {
      _appendLog('移动到文件夹失败: 请至少选择一个文件或文件夹');
      notifyListeners();
      return false;
    }

    final result = await _runAction<int>(
      uniqueFiles.isNotEmpty && uniqueFolders.isNotEmpty
          ? '批量移动文件和文件夹'
          : uniqueFolders.isNotEmpty
          ? (uniqueFolders.length == 1 ? '移动文件夹' : '批量移动文件夹')
          : (uniqueFiles.length == 1 ? '移动到文件夹' : '批量移动到文件夹'),
      () async {
        var movedCount = 0;
        if (uniqueFiles.isNotEmpty) {
          await _client.assignFilesToFolder(
            publicKeyPem: _requirePublicKey(_publicKeyPem),
            relativePaths: uniqueFiles
                .map((file) => file.path)
                .toList(growable: false),
            folderId: targetFolderId,
            targetFolderPassword: targetFolderPassword,
          );
          movedCount += uniqueFiles.length;
        }
        for (final folder in uniqueFolders) {
          await _client.updateFolder(
            publicKeyPem: _requirePublicKey(_publicKeyPem),
            folderId: folder.id,
            parentId: targetFolderId,
            includeParentId: true,
            currentPassword: sourceFolderPasswords[folder.id],
            targetParentPassword: targetFolderPassword,
          );
          movedCount += 1;
        }
        return movedCount;
      },
    );
    if (result == null) {
      return false;
    }

    _selectedPaths.removeWhere(
      (path) => uniqueFiles.any((file) => file.path == path),
    );
    _selectedFolderIds.removeWhere(
      (folderId) => uniqueFolders.any((folder) => folder.id == folderId),
    );
    await refreshWorkspace();
    return true;
  }

  Future<String?> createShareLink(
    ManagedFile file, {
    required int expiresInDays,
  }) async {
    final folder = folderById(file.folderId);
    final folderPassword = unlockedFolderPassword(file.folderId);
    final result = await _runAction<Map<String, dynamic>>(
      '生成下载链接',
      () => _client.createDownloadLink(
        publicKeyPem: _requirePublicKey(_publicKeyPem),
        relativePath: file.path,
        expiresInDays: expiresInDays,
        folderId: file.folderId,
        folderPassword: folder?.encrypted == true ? folderPassword : null,
      ),
    );
    if (result == null) {
      return null;
    }
    final data = Map<String, dynamic>.from(
      result['data'] as Map<String, dynamic>? ?? <String, dynamic>{},
    );
    final url = (data['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      return null;
    }
    return url;
  }

  Future<T?> _runAction<T>(String label, Future<T> Function() action) async {
    if (_busy) {
      _lastActionWasBusy = true;
      _lastActionError = '另一项操作正在进行中，请稍后重试';
      return null;
    }

    _busy = true;
    _lastActionWasBusy = false;
    _lastActionError = null;
    _appendLog('开始: $label');
    notifyListeners();

    try {
      final result = await action();
      _appendLog('$label完成');
      _appendLog(_safeStringifyResult(result));
      return result;
    } catch (error) {
      _lastActionError = error.toString();
      _appendLog('$label失败: $error');
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<String> _resolveDownloadPath(ManagedFile file) async {
    if (file.folderId == null || file.folderId!.isEmpty) {
      return file.path;
    }
    final folderPassword = unlockedFolderPassword(file.folderId);
    if (folderPassword == null || folderPassword.isEmpty) {
      return file.path;
    }
    final response = await _client.createDownloadLink(
      publicKeyPem: _requirePublicKey(_publicKeyPem),
      relativePath: file.path,
      expiresInDays: 7,
      folderId: file.folderId,
      folderPassword: folderPassword,
    );
    final data = Map<String, dynamic>.from(
      response['data'] as Map<String, dynamic>? ?? <String, dynamic>{},
    );
    final url = (data['url'] ?? '').toString().trim();
    return url.isEmpty ? file.path : url;
  }

  Future<T?> _runTransferAction<T>(
    String label,
    Future<T> Function() action,
  ) async {
    if (_busy) {
      _lastActionWasBusy = true;
      _lastActionError = '另一项传输正在进行中，请稍后重试';
      return null;
    }

    _busy = true;
    _lastActionWasBusy = false;
    _lastActionError = null;
    _appendLog('开始: $label');
    notifyListeners();

    try {
      final result = await action();
      _appendLog('$label完成');
      _appendLog(_safeStringifyResult(result));
      return result;
    } on TransferCancelledException {
      _appendLog('$label已取消');
      _lastActionError = '传输已取消';
      rethrow;
    } catch (error) {
      _lastActionError = error.toString();
      _appendLog('$label失败: $error');
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _appendLog(String message) {
    final timestamp = DateTime.now().toIso8601String();
    _logs.add('[$timestamp] $message');
    if (_logs.length > 200) {
      _logs.removeAt(0);
    }
  }

  String _stringifyResult(Object? result) {
    if (result is FileListResponse) {
      return '列表共 ${result.total} 项，当前第 ${result.page}/${result.totalPages == 0 ? 1 : result.totalPages} 页，本次返回 ${result.returned} 项';
    }
    if (result is IndexedFolder) {
      return '文件夹: ${result.path} (${result.encrypted ? '加密' : '普通'})';
    }
    if (result is ManagedFile) {
      return '文件: ${result.path} (${result.storageLabel}, ${_formatBytes(result.size)})';
    }
    if (result is List<IndexedFolder>) {
      return '文件夹索引共 ${result.length} 项';
    }
    if (result is List<ManagedFile>) {
      return '文件列表共 ${result.length} 项';
    }
    if (result is List<BaseUrlLatencyResult>) {
      final succeeded = result.where((item) => item.success).length;
      return '测速完成，共 ${result.length} 个服务器，成功 $succeeded 个';
    }
    if (result is int) {
      return '成功处理 $result 个文件';
    }
    if (result is Uint8List) {
      return '字节长度: ${result.length}';
    }
    if (result is File) {
      return '文件路径: ${result.path}';
    }
    return const JsonEncoder.withIndent('  ').convert(result);
  }

  String _safeStringifyResult(Object? result) {
    try {
      return _stringifyResult(result);
    } catch (_) {
      return result?.toString() ?? 'null';
    }
  }

  List<ManagedFile> _uniqueFilesByPath(List<ManagedFile> files) {
    final mapped = <String, ManagedFile>{};
    for (final file in files) {
      mapped[file.path] = file;
    }
    return mapped.values.toList(growable: false);
  }

  List<IndexedFolder> _uniqueFoldersById(List<IndexedFolder> folders) {
    final mapped = <String, IndexedFolder>{};
    for (final folder in folders) {
      mapped[folder.id] = folder;
    }
    return mapped.values.toList(growable: false);
  }

  int _compareFolderPath(IndexedFolder left, IndexedFolder right) {
    return left.path.toLowerCase().compareTo(right.path.toLowerCase());
  }

  Future<List<FileSystemEntity>> _normalizeUploadEntities(
    List<FileSystemEntity> entities,
  ) async {
    final deduplicated = <String, FileSystemEntity>{};
    for (final entity in entities) {
      final normalizedPath = entity.path.trim();
      if (normalizedPath.isEmpty) {
        continue;
      }
      final entityType = await FileSystemEntity.type(normalizedPath);
      if (entityType == FileSystemEntityType.notFound) {
        continue;
      }
      if (entityType == FileSystemEntityType.file) {
        deduplicated[normalizedPath] = File(normalizedPath);
      } else if (entityType == FileSystemEntityType.directory) {
        deduplicated[normalizedPath] = Directory(normalizedPath);
      }
    }

    final result = deduplicated.values.toList(growable: false)
      ..sort(
        (left, right) =>
            left.path.toLowerCase().compareTo(right.path.toLowerCase()),
      );
    return result;
  }

  Future<_PreparedUploadSelection> _prepareUploadSelection({
    required List<FileSystemEntity> entities,
    required String? baseFolderId,
    required String? baseFolderPassword,
    required FolderPasswordResolver? resolveFolderPassword,
  }) async {
    final foldersByParentAndName = <String, IndexedFolder>{};
    for (final folder in _folders) {
      foldersByParentAndName[_folderLookupKey(folder.parentId, folder.name)] =
          folder;
    }

    final resolvedPasswords = <String, String>{
      for (final entry in _unlockedFolderPasswords.entries)
        if (entry.key.trim().isNotEmpty && entry.value.trim().isNotEmpty)
          entry.key.trim(): entry.value.trim(),
    };
    final normalizedBasePassword = baseFolderPassword?.trim() ?? '';
    if ((baseFolderId?.trim().isNotEmpty ?? false) &&
        normalizedBasePassword.isNotEmpty) {
      resolvedPasswords[baseFolderId!.trim()] = normalizedBasePassword;
    }

    final preparedFiles = <_PreparedUploadFile>[];
    for (final entity in entities) {
      if (entity is File) {
        preparedFiles.add(
          _PreparedUploadFile(
            file: entity,
            targetFolderId: baseFolderId,
            targetFolderPassword: normalizedBasePassword.isEmpty
                ? resolvedPasswords[baseFolderId?.trim() ?? '']
                : normalizedBasePassword,
            displayLabel: p.basename(entity.path),
            size: await entity.length(),
          ),
        );
        continue;
      }

      if (entity is! Directory) {
        continue;
      }

      await _collectDirectoryUploadFiles(
        directory: entity,
        relativePrefix: p.basename(entity.path),
        targetParentId: baseFolderId,
        targetParentPassword: normalizedBasePassword.isEmpty
            ? resolvedPasswords[baseFolderId?.trim() ?? '']
            : normalizedBasePassword,
        foldersByParentAndName: foldersByParentAndName,
        resolvedPasswords: resolvedPasswords,
        resolveFolderPassword: resolveFolderPassword,
        preparedFiles: preparedFiles,
      );
    }

    return _PreparedUploadSelection(
      files: preparedFiles,
      resolvedFolderPasswords: resolvedPasswords,
      totalBytes: preparedFiles.fold<int>(
        0,
        (int sum, _PreparedUploadFile item) => sum + item.size,
      ),
    );
  }

  Future<void> _collectDirectoryUploadFiles({
    required Directory directory,
    required String relativePrefix,
    required String? targetParentId,
    required String? targetParentPassword,
    required Map<String, IndexedFolder> foldersByParentAndName,
    required Map<String, String> resolvedPasswords,
    required FolderPasswordResolver? resolveFolderPassword,
    required List<_PreparedUploadFile> preparedFiles,
  }) async {
    final resolvedTargetFolder = await _resolveUploadTargetFolder(
      name: p.basename(directory.path),
      parentId: targetParentId,
      parentPassword: targetParentPassword,
      foldersByParentAndName: foldersByParentAndName,
      resolvedPasswords: resolvedPasswords,
      resolveFolderPassword: resolveFolderPassword,
    );

    final children = await directory
        .list(recursive: false, followLinks: false)
        .toList();
    children.sort(
      (left, right) =>
          left.path.toLowerCase().compareTo(right.path.toLowerCase()),
    );

    for (final child in children) {
      if (child is File) {
        preparedFiles.add(
          _PreparedUploadFile(
            file: child,
            targetFolderId: resolvedTargetFolder.folder.id,
            targetFolderPassword: resolvedTargetFolder.folderPassword,
            displayLabel: p.join(relativePrefix, p.basename(child.path)),
            size: await child.length(),
          ),
        );
        continue;
      }

      if (child is! Directory) {
        continue;
      }

      await _collectDirectoryUploadFiles(
        directory: child,
        relativePrefix: p.join(relativePrefix, p.basename(child.path)),
        targetParentId: resolvedTargetFolder.folder.id,
        targetParentPassword: resolvedTargetFolder.folderPassword,
        foldersByParentAndName: foldersByParentAndName,
        resolvedPasswords: resolvedPasswords,
        resolveFolderPassword: resolveFolderPassword,
        preparedFiles: preparedFiles,
      );
    }
  }

  Future<_ResolvedUploadFolder> _resolveUploadTargetFolder({
    required String name,
    required String? parentId,
    required String? parentPassword,
    required Map<String, IndexedFolder> foldersByParentAndName,
    required Map<String, String> resolvedPasswords,
    required FolderPasswordResolver? resolveFolderPassword,
  }) async {
    final lookupKey = _folderLookupKey(parentId, name);
    final existingFolder = foldersByParentAndName[lookupKey];
    if (existingFolder != null) {
      final folderPassword = await _resolveEncryptedFolderPassword(
        folder: existingFolder,
        resolvedPasswords: resolvedPasswords,
        resolveFolderPassword: resolveFolderPassword,
      );
      return _ResolvedUploadFolder(
        folder: existingFolder,
        folderPassword: folderPassword,
      );
    }

    final response = await _client.createFolder(
      publicKeyPem: _requirePublicKey(_publicKeyPem),
      name: name,
      parentId: parentId,
      encrypted: false,
      allowDirectDownload: false,
      parentFolderPassword: parentPassword,
    );
    final data = Map<String, dynamic>.from(
      response['data'] as Map<String, dynamic>? ?? <String, dynamic>{},
    );
    final createdFolder = IndexedFolder.fromJson(data);
    foldersByParentAndName[
          _folderLookupKey(createdFolder.parentId, createdFolder.name)
        ] = createdFolder;
    return _ResolvedUploadFolder(folder: createdFolder, folderPassword: null);
  }

  Future<String?> _resolveEncryptedFolderPassword({
    required IndexedFolder folder,
    required Map<String, String> resolvedPasswords,
    required FolderPasswordResolver? resolveFolderPassword,
  }) async {
    if (!folder.encrypted) {
      return null;
    }

    final cachedPassword = resolvedPasswords[folder.id]?.trim() ?? '';
    if (cachedPassword.isNotEmpty) {
      return cachedPassword;
    }
    if (resolveFolderPassword == null) {
      throw StateError('缺少加密文件夹密码: ${folder.path}');
    }

    final password = await resolveFolderPassword(folder, '合并上传到该目录');
    final normalizedPassword = password?.trim() ?? '';
    if (normalizedPassword.isEmpty) {
      throw StateError('缺少加密文件夹密码: ${folder.path}');
    }
    resolvedPasswords[folder.id] = normalizedPassword;
    return normalizedPassword;
  }

  Future<void> _uploadPreparedFile(
    _PreparedUploadFile file, {
    required bool permanent,
    required TransferCancellationToken? cancelToken,
    required TransferProgressCallback onProgress,
  }) async {
    if (permanent) {
      await _client.uploadPermanent(
        file: file.file,
        publicKeyPem: _requirePublicKey(_publicKeyPem),
        folderId: file.targetFolderId,
        folderPassword: file.targetFolderPassword,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      return;
    }

    await _client.uploadTemporary(
      file.file,
      publicKeyPem: _publicKeyPem,
      folderId: file.targetFolderId,
      folderPassword: file.targetFolderPassword,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  String _folderLookupKey(String? parentId, String name) {
    final normalizedParentId = parentId?.trim() ?? '';
    return '${normalizedParentId.toLowerCase()}::${name.trim().toLowerCase()}';
  }

  BatchTransferFailureType _classifyBatchUploadFailure(Object error) {
    if (error is SocketException) {
      return BatchTransferFailureType.network;
    }
    final rawMessage = error is StateError
        ? error.message.toString()
        : error.toString();
    final message = rawMessage.toLowerCase();

    if (message.contains('40302') ||
        message.contains('40105') ||
        message.contains('40107') ||
        message.contains('folder password') ||
        message.contains('密码')) {
      return BatchTransferFailureType.password;
    }

    if (message.contains('socketexception') ||
        message.contains('connection reset') ||
        message.contains('connection closed') ||
        message.contains('connection aborted') ||
        message.contains('unexpected response') ||
        message.contains('timed out') ||
        message.contains('failed host lookup') ||
        message.contains('network is unreachable')) {
      return BatchTransferFailureType.network;
    }

    return BatchTransferFailureType.serverRejected;
  }

  String _normalizeBatchUploadFailureMessage(Object error) {
    if (error is SocketException) {
      return '上传过程中网络连接中断，请检查网络或稍后重试。';
    }

    final rawMessage = error is StateError
        ? error.message.toString()
        : error.toString();
    final message = rawMessage.toLowerCase();

    if (message.contains('40302') ||
        message.contains('invalid folder password')) {
      return '目标加密文件夹密码错误，请重新验证后再试。';
    }
    if (message.contains('40105') ||
        message.contains('40107') ||
        message.contains('missing folder password') ||
        message.contains('missing folder passwords token')) {
      return '缺少加密文件夹密码验证，请补全相关密码后重试。';
    }
    if (message.contains('续传会话失效')) {
      return '上传会话已失效，需要重新开始该项上传。';
    }
    if (message.contains('41301') ||
        message.contains('file too large') ||
        message.contains('上传分片过大')) {
      return '文件体积或分片大小超出服务端限制，请调整后重试。';
    }
    if (message.contains('42900') || message.contains('too many upload requests')) {
      return '上传请求过于频繁，已被服务端限流，请稍后重试。';
    }
    if (message.contains('40403') || message.contains('folder not found')) {
      return '目标文件夹不存在，目录结构可能已发生变化，请刷新后重试。';
    }
    if (message.contains('40103') ||
        message.contains('40100') ||
        message.contains('40101') ||
        message.contains('40102') ||
        message.contains('missing management token') ||
        message.contains('invalid token') ||
        message.contains('expired permanent token') ||
        message.contains('replayed permanent token')) {
      return '鉴权令牌无效或已过期，服务端拒绝了此次上传请求。';
    }
    if (message.contains('500') ||
        message.contains('internal server error') ||
        message.contains('verification is unavailable') ||
        message.contains('服务端未返回合法 json')) {
      return '服务端处理上传请求时发生异常，请稍后重试或检查服务端日志。';
    }
    if (_classifyBatchUploadFailure(error) == BatchTransferFailureType.network) {
      return '上传过程中网络连接异常，请检查网络后重试。';
    }
    return '服务端拒绝了该项上传，请查看操作日志中的原始错误信息。';
  }

  void _syncPreviewFile() {
    final preview = _previewFile;
    if (preview == null) {
      return;
    }

    ManagedFile? updatedPreview;
    for (final file in _files) {
      if (file.path == preview.path) {
        updatedPreview = file;
        break;
      }
    }

    if (updatedPreview == null) {
      _previewFile = null;
      _previewImageBytes = null;
      _previewError = null;
      _previewLoading = false;
      _previewTransferredBytes = 0;
      _previewTotalBytes = null;
      return;
    }

    _previewFile = updatedPreview;
  }

  /// 设置排序列。同一列再次点击切换升降序。
  void setSortColumn(String columnName) {
    if (_sortColumnName == columnName) {
      _sortAscending = !_sortAscending;
    } else {
      _sortColumnName = columnName;
      _sortAscending = true;
    }
    notifyListeners();
  }

  /// 清除排序，恢复默认顺序。
  void clearSort() {
    _sortColumnName = null;
    _sortAscending = true;
    notifyListeners();
  }

  /// 保存列宽到 SharedPreferences。
  Future<void> saveColumnWidths(Map<String, double> widths) async {
    _columnWidths
      ..clear()
      ..addAll(widths);
    final preferences = await SharedPreferences.getInstance();
    await _persistColumnWidths(preferences);
    notifyListeners();
  }

  /// 设置图片预览自动加载阈值级别（0~21，指数级）。
  Future<void> setPreviewThresholdLevel(int level) async {
    final clamped = level.clamp(0, _previewThresholdMaxLevel);
    if (_previewThresholdLevel == clamped) return;
    _previewThresholdLevel = clamped;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_previewThresholdPreferenceKey, clamped);
    notifyListeners();
  }

  void _loadColumnWidths(SharedPreferences preferences) {
    final raw = preferences.getString(_columnWidthsPreferenceKey);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      _columnWidths.clear();
      for (final entry in decoded.entries) {
        final value = (entry.value as num?)?.toDouble();
        if (value != null && value > 0) {
          _columnWidths[entry.key] = value;
        }
      }
    } catch (_) {}
  }

  Future<void> _persistColumnWidths(SharedPreferences preferences) async {
    if (_columnWidths.isEmpty) return;
    await preferences.setString(
      _columnWidthsPreferenceKey,
      jsonEncode(_columnWidths),
    );
  }

  Future<int> _calculateDirectorySize(Directory directory) async {
    if (!await directory.exists()) {
      return 0;
    }

    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  Future<void> _clearDirectoryChildren(Directory directory) async {
    if (!await directory.exists()) {
      return;
    }

    await for (final entity in directory.list(
      recursive: false,
      followLinks: false,
    )) {
      await entity.delete(recursive: true);
    }
  }

  Future<File> _resolveUniqueDownloadFile({
    required String directoryPath,
    required ManagedFile file,
  }) async {
    final rawName =
        (file.indexedName.isEmpty ? file.systemName : file.indexedName)
            .split(RegExp(r'[\\/]'))
            .last
            .trim();
    final safeName = rawName.isEmpty ? 'downloaded_file' : rawName;
    final dotIndex = safeName.lastIndexOf('.');
    final hasExtension = dotIndex > 0 && dotIndex < safeName.length - 1;
    final baseName = hasExtension ? safeName.substring(0, dotIndex) : safeName;
    final extension = hasExtension ? safeName.substring(dotIndex) : '';

    var candidate = File('$directoryPath/$safeName');
    var index = 1;
    while (await candidate.exists()) {
      candidate = File('$directoryPath/$baseName ($index)$extension');
      index += 1;
    }
    return candidate;
  }

  Future<File> _resolveUniqueNamedFile({
    required String directoryPath,
    required String fileName,
  }) async {
    final rawName = fileName.split(RegExp(r'[\\/]')).last.trim();
    final safeName = rawName.isEmpty ? 'downloaded_file' : rawName;
    final dotIndex = safeName.lastIndexOf('.');
    final hasExtension = dotIndex > 0 && dotIndex < safeName.length - 1;
    final baseName = hasExtension ? safeName.substring(0, dotIndex) : safeName;
    final extension = hasExtension ? safeName.substring(dotIndex) : '';

    var candidate = File('$directoryPath/$safeName');
    var index = 1;
    while (await candidate.exists()) {
      candidate = File('$directoryPath/$baseName ($index)$extension');
      index += 1;
    }
    return candidate;
  }

  String _formatBytes(int bytes) {
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

  static String _normalizeBaseUrl(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  bool _hasBaseUrlPreset(String baseUrl, {String? excludingId}) {
    for (final preset in baseUrlPresets) {
      if (preset.id == excludingId) {
        continue;
      }
      if (_normalizeBaseUrl(preset.baseUrl) == _normalizeBaseUrl(baseUrl)) {
        return true;
      }
    }
    return false;
  }

  BaseUrlPreset? _resolvePresetById(String? presetId) {
    final normalizedPresetId = presetId?.trim() ?? '';
    if (normalizedPresetId.isEmpty) {
      return _defaultBaseUrlPreset;
    }
    for (final preset in baseUrlPresets) {
      if (preset.id == normalizedPresetId) {
        return preset;
      }
    }
    return null;
  }
  List<BaseUrlPreset> _decodeBaseUrlPresets(String? rawJson) {
    if (rawJson == null || rawJson.trim().isEmpty) {
      return const <BaseUrlPreset>[];
    }
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! List<dynamic>) {
        return const <BaseUrlPreset>[];
      }

      final seenIds = <String>{};
      final seenBaseUrls = <String>{
        _normalizeBaseUrl(_defaultBaseUrlPreset.baseUrl),
      };
      final presets = <BaseUrlPreset>[];
      for (final item in decoded) {
        if (item is! Map) {
          continue;
        }
        final preset = BaseUrlPreset.fromJson(Map<String, dynamic>.from(item));
        final normalizedBaseUrl = _normalizeBaseUrl(preset.baseUrl);
        final validationMessage = validateBaseUrl(normalizedBaseUrl);
        if (preset.id.isEmpty ||
            preset.name.isEmpty ||
            validationMessage != null) {
          continue;
        }
        if (!seenIds.add(preset.id) || !seenBaseUrls.add(normalizedBaseUrl)) {
          continue;
        }
        presets.add(
          BaseUrlPreset(
            id: preset.id,
            name: preset.name,
            baseUrl: normalizedBaseUrl,
          ),
        );
      }
      return presets;
    } catch (_) {
      return const <BaseUrlPreset>[];
    }
  }

  Future<void> _persistBaseUrlPreferences(SharedPreferences preferences) async {
    final encoded = jsonEncode(
      _customBaseUrlPresets
          .map((preset) => preset.toJson())
          .toList(growable: false),
    );
    await preferences.setString(_baseUrlPresetsPreferenceKey, encoded);
    await preferences.setString(
      _selectedBaseUrlPresetIdPreferenceKey,
      _selectedBaseUrlPresetId,
    );
  }

  Future<BaseUrlLatencyResult> _measureSingleBaseUrlLatency(
    BaseUrlPreset preset,
  ) async {
    final stopwatch = Stopwatch()..start();
    final client = ImageBedClient(baseUrl: preset.baseUrl);
    try {
      await client.healthCheck();
      stopwatch.stop();
      return BaseUrlLatencyResult(
        preset: preset,
        latencyMilliseconds: stopwatch.elapsedMilliseconds,
      );
    } catch (error) {
      stopwatch.stop();
      return BaseUrlLatencyResult(preset: preset, error: error.toString());
    } finally {
      client.close();
    }
  }

  void _applyBaseUrlPreset(
    BaseUrlPreset preset, {
    bool notify = true,
    bool appendLog = true,
  }) {
    final normalizedBaseUrl = _normalizeBaseUrl(preset.baseUrl);
    final needsClientRebuild = normalizedBaseUrl != _baseUrl;
    _selectedBaseUrlPresetId = preset.id;
    _baseUrl = normalizedBaseUrl;
    if (needsClientRebuild) {
      _client.close();
      _client = ImageBedClient(baseUrl: normalizedBaseUrl);
    }
    _resetRemoteWorkspaceState();
    if (appendLog) {
      _appendLog('已切换服务端: ${preset.name} ($normalizedBaseUrl)');
    }
    if (notify) {
      notifyListeners();
    }
  }

  void _resetRemoteWorkspaceState() {
    _files = const <ManagedFile>[];
    _folders = const <IndexedFolder>[];
    _unlockedFolderPasswords.clear();
    _folderContentCache.clear();
    _selectedPaths.clear();
    _selectedFolderIds.clear();
    _currentFolderId = null;
    _currentFolderLoading = false;
    _showingCachedFolderContent = false;
    _total = 0;
    _totalPages = 0;
    _diskTotalBytes = 0;
    _diskFreeBytes = 0;
    _previewFile = null;
    _previewImageBytes = null;
    _previewError = null;
    _previewLoading = false;
    _previewTransferredBytes = 0;
    _previewTotalBytes = null;
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}

class _ResolvedUploadFolder {
  const _ResolvedUploadFolder({
    required this.folder,
    required this.folderPassword,
  });

  final IndexedFolder folder;
  final String? folderPassword;
}

class _PreparedUploadFile {
  const _PreparedUploadFile({
    required this.file,
    required this.targetFolderId,
    required this.targetFolderPassword,
    required this.displayLabel,
    required this.size,
  });

  final File file;
  final String? targetFolderId;
  final String? targetFolderPassword;
  final String displayLabel;
  final int size;
}

class _PreparedUploadSelection {
  const _PreparedUploadSelection({
    required this.files,
    required this.resolvedFolderPasswords,
    required this.totalBytes,
  });

  final List<_PreparedUploadFile> files;
  final Map<String, String> resolvedFolderPasswords;
  final int totalBytes;
}
