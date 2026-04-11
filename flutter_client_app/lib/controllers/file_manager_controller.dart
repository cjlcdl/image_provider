import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:courage_storage/models/base_url_preset.dart';
import 'package:courage_storage/models/file_list_response.dart';
import 'package:courage_storage/models/indexed_folder.dart';
import 'package:courage_storage/models/managed_file.dart';
import 'package:courage_storage/services/image_bed_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String? _previewError;

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
  String get downloadDirectory => _downloadDirectory;
  bool get hasDownloadDirectory => _downloadDirectory.trim().isNotEmpty;
  List<ManagedFile> get files => List<ManagedFile>.unmodifiable(_files);
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
  String? get previewError => _previewError;

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
    _previewError = null;
    _previewLoading = false;
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
    final effectiveFolderId = folderId ?? _currentFolderId;
    final effectiveFolderPassword =
        folderPassword ?? unlockedFolderPassword(effectiveFolderId);
    final result = await _runAction<Map<String, dynamic>>(
      '上传',
      () => permanent
          ? _client.uploadPermanent(
              file: file,
              publicKeyPem: _requirePublicKey(_publicKeyPem),
              folderId: effectiveFolderId,
              folderPassword: effectiveFolderPassword,
            )
          : _client.uploadTemporary(
              file,
              publicKeyPem: _publicKeyPem,
              folderId: effectiveFolderId,
              folderPassword: effectiveFolderPassword,
            ),
    );
    if (result == null) {
      return false;
    }

    await refreshFiles();
    return true;
  }

  Future<bool> uploadFileWithProgress({
    required File file,
    required bool permanent,
    String? folderId,
    String? folderPassword,
    TransferProgressCallback? onProgress,
    TransferCancellationToken? cancelToken,
  }) async {
    final effectiveFolderId = folderId ?? _currentFolderId;
    final effectiveFolderPassword =
        folderPassword ?? unlockedFolderPassword(effectiveFolderId);
    final result = await _runTransferAction<Map<String, dynamic>>(
      permanent ? '上传' : '临时上传',
      () => permanent
          ? _client.uploadPermanent(
              file: file,
              publicKeyPem: _requirePublicKey(_publicKeyPem),
              folderId: effectiveFolderId,
              folderPassword: effectiveFolderPassword,
              onProgress: onProgress,
              cancelToken: cancelToken,
            )
          : _client.uploadTemporary(
              file,
              publicKeyPem: _publicKeyPem,
              folderId: effectiveFolderId,
              folderPassword: effectiveFolderPassword,
              onProgress: onProgress,
              cancelToken: cancelToken,
            ),
    );
    if (result == null) {
      return false;
    }

    await refreshFiles();
    return true;
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
      _cacheBytes = await _calculateDirectorySize(cacheDirectory);
      _appendLog('已清除缓存: ${_formatBytes(beforeSize)}');
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

    if (!file.mimeType.startsWith('image/')) {
      _previewLoading = false;
      notifyListeners();
      return;
    }

    _previewLoading = true;
    notifyListeners();

    try {
      final bytes = await _client.downloadBytes(file.path);
      if (_previewFile?.path != file.path) {
        return;
      }
      _previewImageBytes = bytes;
      _appendLog(
        '已加载预览: ${file.indexedName.isEmpty ? file.systemName : file.indexedName}',
      );
    } catch (error) {
      if (_previewFile?.path != file.path) {
        return;
      }
      _previewError = '预览加载失败: $error';
      _appendLog(_previewError!);
    } finally {
      if (_previewFile?.path == file.path) {
        _previewLoading = false;
        notifyListeners();
      }
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
      return null;
    }

    _busy = true;
    _appendLog('开始: $label');
    notifyListeners();

    try {
      final result = await action();
      _appendLog('$label完成');
      _appendLog(_safeStringifyResult(result));
      return result;
    } catch (error) {
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
      return null;
    }

    _busy = true;
    _appendLog('开始: $label');
    notifyListeners();

    try {
      final result = await action();
      _appendLog('$label完成');
      _appendLog(_safeStringifyResult(result));
      return result;
    } on TransferCancelledException {
      _appendLog('$label已取消');
      rethrow;
    } catch (error) {
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
      return;
    }

    _previewFile = updatedPreview;
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
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
