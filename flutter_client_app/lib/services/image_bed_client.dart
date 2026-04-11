import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:courage_storage/data/global.dart';
import 'package:courage_storage/models/file_list_response.dart';
import 'package:courage_storage/models/indexed_folder.dart';
import 'package:courage_storage/models/managed_file.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

typedef TransferProgressCallback =
    void Function(int transferredBytes, int? totalBytes);

class TransferCancelledException implements Exception {
  const TransferCancelledException(this.operation);

  final String operation;

  @override
  String toString() => '$operation已取消';
}

class TransferCancellationToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
  }

  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

class ImageBedClient {
  ImageBedClient({required this.baseUrl, http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _httpClient;

  static const String permanentTokenHeader = 'Courage-Token';
  static const String appChannelHeader = 'APP_CHANNEL';
  static const String userHeader = 'USER';
  static const String uploadTokenHeader = 'Upload-Token';
  static const String uploadOffsetHeader = 'Upload-Offset';
  static const String folderPasswordTokenHeader = 'Folder-Password-Token';
  static const String targetFolderPasswordTokenHeader =
      'Target-Folder-Password-Token';
  static const int _defaultResumableChunkSize = 4 * 1024 * 1024;
  static const int _minimumResumableChunkSize = 256 * 1024;
  static const String _resumableUploadStateDirectory = 'resumable_uploads';

  Future<Map<String, dynamic>> healthCheck() async {
    final response = await _httpClient.get(
      _buildUri('/api/health'),
      headers: _buildRequestHeaders(),
    );
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> uploadTemporary(
    File file, {
    String? publicKeyPem,
    String? folderId,
    String? folderPassword,
    TransferProgressCallback? onProgress,
    TransferCancellationToken? cancelToken,
  }) async {
    final folderHeaders = _requireFolderHeaders(
      publicKeyPem: publicKeyPem,
      folderId: folderId,
      folderPassword: folderPassword,
    );
    return _uploadFileResumable(
      file: file,
      folderId: folderId,
      extraHeaders: folderHeaders,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  Future<Map<String, dynamic>> uploadPermanent({
    required File file,
    required String publicKeyPem,
    String? folderId,
    String? folderPassword,
    String? nonce,
    int? timestamp,
    TransferProgressCallback? onProgress,
    TransferCancellationToken? cancelToken,
  }) async {
    final token = buildPermanentToken(
      publicKeyPem: publicKeyPem,
      nonce: nonce,
      timestamp: timestamp,
    );
    return _uploadFileResumable(
      file: file,
      folderId: folderId,
      extraHeaders: _mergeHeaders(
        <String, String>{permanentTokenHeader: token},
        _requireFolderHeaders(
          publicKeyPem: publicKeyPem,
          folderId: folderId,
          folderPassword: folderPassword,
        ),
      ),
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  Future<FileListResponse> listFiles({
    required String publicKeyPem,
    String? storage,
    String? keyword,
    String? mimeType,
    String? extension,
    String? folderId,
    String? folderPassword,
    int page = 1,
    int pageSize = 50,
    String? nonce,
    int? timestamp,
  }) async {
    final headers = _buildManagementHeaders(
      publicKeyPem: publicKeyPem,
      nonce: nonce,
      timestamp: timestamp,
    );
    final queryParameters = <String, String>{
      'page': page.toString(),
      'pageSize': pageSize.toString(),
    };
    if (storage != null && storage.isNotEmpty) {
      queryParameters['storage'] = storage;
    }
    if (keyword != null && keyword.isNotEmpty) {
      queryParameters['keyword'] = keyword;
    }
    if (mimeType != null && mimeType.isNotEmpty) {
      queryParameters['mimeType'] = mimeType;
    }
    if (extension != null && extension.isNotEmpty) {
      queryParameters['extension'] = extension;
    }
    if (folderId != null) {
      queryParameters['folderId'] = folderId;
    }

    final response = await _httpClient.get(
      _buildUri('/api/files').replace(queryParameters: queryParameters),
      headers: _buildRequestHeaders(
        _mergeHeaders(
          headers,
          _buildFolderPasswordHeaders(
            publicKeyPem: publicKeyPem,
            folderId: folderId,
            password: folderPassword,
          ),
        ),
      ),
    );
    return FileListResponse.fromApi(_decodeJsonResponse(response));
  }

  Future<List<IndexedFolder>> listFolders({
    required String publicKeyPem,
    String? nonce,
    int? timestamp,
  }) async {
    final response = await _httpClient.get(
      _buildUri('/api/folders'),
      headers: _buildRequestHeaders(
        _buildManagementHeaders(
          publicKeyPem: publicKeyPem,
          nonce: nonce,
          timestamp: timestamp,
        ),
      ),
    );
    final payload = _decodeJsonResponse(response);
    final data = _responseDataMap(payload);
    final folders = (data['folders'] as List<dynamic>? ?? <dynamic>[])
        .map((item) => IndexedFolder.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList(growable: false);
    return folders;
  }

  Future<Map<String, dynamic>> createFolder({
    required String publicKeyPem,
    required String name,
    String? parentId,
    bool encrypted = false,
    bool allowDirectDownload = false,
    String? password,
    String? parentFolderPassword,
  }) async {
    final request = http.Request('POST', _buildUri('/api/folders'));
    request.headers.addAll(
      _buildRequestHeaders(
        _mergeHeaders(
          _buildManagementHeaders(publicKeyPem: publicKeyPem),
          _buildTargetFolderPasswordHeaders(
            publicKeyPem: publicKeyPem,
            folderId: parentId,
            password: parentFolderPassword,
          ),
        ),
      ),
    );
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    request.bodyBytes = utf8.encode(
      jsonEncode(<String, dynamic>{
        'name': name,
        'parentId': parentId,
        'encrypted': encrypted,
        'allowDirectDownload': allowDirectDownload,
        if (password != null && password.isNotEmpty) 'password': password,
      }),
    );
    final response = await http.Response.fromStream(await _httpClient.send(request));
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> updateFolder({
    required String publicKeyPem,
    required String folderId,
    String? name,
    String? parentId,
    bool includeParentId = false,
    bool? encrypted,
    bool? allowDirectDownload,
    String? currentPassword,
    String? targetParentPassword,
    String? newPassword,
  }) async {
    final request = http.Request('PATCH', _buildUri('/api/folders'));
    request.headers.addAll(
      _buildRequestHeaders(
        _mergeHeaders(
          _buildManagementHeaders(publicKeyPem: publicKeyPem),
          _mergeHeaders(
            _buildFolderPasswordHeaders(
              publicKeyPem: publicKeyPem,
              folderId: folderId,
              password: currentPassword,
            ),
            _buildTargetFolderPasswordHeaders(
              publicKeyPem: publicKeyPem,
              folderId: parentId,
              password: targetParentPassword,
            ),
          ),
        ),
      ),
    );
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    final payload = <String, dynamic>{'folderId': folderId};
    if (name != null) {
      payload['name'] = name;
    }
    if (includeParentId || parentId != null) {
      payload['parentId'] = parentId;
    }
    if (encrypted != null) {
      payload['encrypted'] = encrypted;
    }
    if (allowDirectDownload != null) {
      payload['allowDirectDownload'] = allowDirectDownload;
    }
    if (newPassword != null && newPassword.isNotEmpty) {
      payload['newPassword'] = newPassword;
    }
    request.bodyBytes = utf8.encode(
      jsonEncode(payload),
    );
    final response = await http.Response.fromStream(await _httpClient.send(request));
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> deleteFolder({
    required String publicKeyPem,
    required String folderId,
    String? currentPassword,
  }) async {
    final request = http.Request('DELETE', _buildUri('/api/folders'));
    request.headers.addAll(
      _buildRequestHeaders(
        _mergeHeaders(
          _buildManagementHeaders(publicKeyPem: publicKeyPem),
          _buildFolderPasswordHeaders(
            publicKeyPem: publicKeyPem,
            folderId: folderId,
            password: currentPassword,
          ),
        ),
      ),
    );
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    request.bodyBytes = utf8.encode(jsonEncode(<String, dynamic>{'folderId': folderId}));
    final response = await http.Response.fromStream(await _httpClient.send(request));
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> assignFilesToFolder({
    required String publicKeyPem,
    required List<String> relativePaths,
    String? folderId,
    String? targetFolderPassword,
  }) async {
    final request = http.Request('POST', _buildUri('/api/files/folder'));
    request.headers.addAll(
      _buildRequestHeaders(
        _mergeHeaders(
          _buildManagementHeaders(publicKeyPem: publicKeyPem),
          _buildTargetFolderPasswordHeaders(
            publicKeyPem: publicKeyPem,
            folderId: folderId,
            password: targetFolderPassword,
          ),
        ),
      ),
    );
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    request.bodyBytes = utf8.encode(
      jsonEncode(<String, dynamic>{
        'paths': relativePaths,
        'folderId': folderId,
      }),
    );
    final response = await http.Response.fromStream(await _httpClient.send(request));
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> createDownloadLink({
    required String publicKeyPem,
    required String relativePath,
    required int expiresInDays,
    String? folderId,
    String? folderPassword,
  }) async {
    final request = http.Request('POST', _buildUri('/api/folders/download-link'));
    request.headers.addAll(
      _buildRequestHeaders(
        _mergeHeaders(
          _buildManagementHeaders(publicKeyPem: publicKeyPem),
          _buildFolderPasswordHeaders(
            publicKeyPem: publicKeyPem,
            folderId: folderId,
            password: folderPassword,
          ),
        ),
      ),
    );
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    request.bodyBytes = utf8.encode(
      jsonEncode(<String, dynamic>{
        'path': relativePath,
        'expiresInDays': expiresInDays,
      }),
    );
    final response = await http.Response.fromStream(await _httpClient.send(request));
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> renameIndexedName({
    required String relativePath,
    required String indexedName,
    required String publicKeyPem,
    String? nonce,
    int? timestamp,
  }) async {
    final request = http.Request('PATCH', _buildUri('/api/files'));
    request.headers.addAll(
      _buildRequestHeaders(
        _buildManagementHeaders(
          publicKeyPem: publicKeyPem,
          nonce: nonce,
          timestamp: timestamp,
        ),
      ),
    );
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    request.bodyBytes = utf8.encode(
      jsonEncode(<String, dynamic>{
        'path': relativePath,
        'indexedName': indexedName,
      }),
    );

    final response = await http.Response.fromStream(
      await _httpClient.send(request),
    );
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> moveFile({
    required String relativePath,
    required String targetStorage,
    required String publicKeyPem,
    String? nonce,
    int? timestamp,
  }) async {
    final request = http.Request('POST', _buildUri('/api/files/move'));
    request.headers.addAll(
      _buildRequestHeaders(
        _buildManagementHeaders(
          publicKeyPem: publicKeyPem,
          nonce: nonce,
          timestamp: timestamp,
        ),
      ),
    );
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    request.bodyBytes = utf8.encode(
      jsonEncode(<String, dynamic>{
        'path': relativePath,
        'targetStorage': targetStorage,
      }),
    );

    final response = await http.Response.fromStream(
      await _httpClient.send(request),
    );
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> deleteFile({
    required String relativePath,
    required String publicKeyPem,
    String? nonce,
    int? timestamp,
  }) async {
    final uri = _buildUri(
      '/api/files?path=${Uri.encodeQueryComponent(relativePath)}',
    );
    final response = await _httpClient.delete(
      uri,
      headers: _buildRequestHeaders(
        _buildManagementHeaders(
          publicKeyPem: publicKeyPem,
          nonce: nonce,
          timestamp: timestamp,
        ),
      ),
    );
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> batchDeleteFiles({
    required List<String> relativePaths,
    required String publicKeyPem,
    String? nonce,
    int? timestamp,
  }) async {
    final request = http.Request('DELETE', _buildUri('/api/files'));
    request.headers.addAll(
      _buildRequestHeaders(
        _buildManagementHeaders(
          publicKeyPem: publicKeyPem,
          nonce: nonce,
          timestamp: timestamp,
        ),
      ),
    );
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    request.bodyBytes = utf8.encode(
      jsonEncode(<String, dynamic>{'paths': relativePaths}),
    );

    final response = await http.Response.fromStream(
      await _httpClient.send(request),
    );
    return _decodeJsonResponse(response);
  }

  Future<File> downloadListedFile({
    required ManagedFile file,
    required String saveDirectory,
    TransferProgressCallback? onProgress,
    TransferCancellationToken? cancelToken,
  }) async {
    final safeName = file.indexedName.split(RegExp(r'[\\/]')).last;
    return downloadToFile(
      relativePath: file.path,
      savePath: '$saveDirectory/$safeName',
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  Future<File> downloadToFile({
    required String relativePath,
    required String savePath,
    TransferProgressCallback? onProgress,
    TransferCancellationToken? cancelToken,
    bool allowResume = true,
  }) async {
    final targetFile = File(savePath);
    await targetFile.parent.create(recursive: true);

    final partialFile = File('$savePath.part');
    var resumedBytes = 0;
    if (allowResume && await partialFile.exists()) {
      resumedBytes = await partialFile.length();
    }

    final httpClient = HttpClient();
    void abortRequest() {
      httpClient.close(force: true);
    }

    cancelToken?.addListener(abortRequest);
    try {
      final request = await httpClient.getUrl(_buildUri(relativePath));
      _applyHeaders(request.headers, _buildRequestHeaders());
      if (resumedBytes > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumedBytes-');
      }

      final response = await request.close();
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          resumedBytes > 0) {
        await partialFile.delete();
        return downloadToFile(
          relativePath: relativePath,
          savePath: savePath,
          onProgress: onProgress,
          cancelToken: cancelToken,
          allowResume: false,
        );
      }

      if (response.statusCode >= 400) {
        final bytes = await _collectResponseBytes(response);
        final errorBody = _tryDecodeJson(bytes);
        throw HttpException(
          '下载失败: ${response.statusCode}, ${jsonEncode(errorBody ?? utf8.decode(bytes, allowMalformed: true))}',
        );
      }

      final useResume =
          resumedBytes > 0 && response.statusCode == HttpStatus.partialContent;
      if (!useResume && resumedBytes > 0 && await partialFile.exists()) {
        await partialFile.delete();
        resumedBytes = 0;
      }

      final totalBytes = response.contentLength >= 0
          ? resumedBytes + response.contentLength
          : null;
      onProgress?.call(resumedBytes, totalBytes);

      final sink = partialFile.openWrite(
        mode: useResume ? FileMode.append : FileMode.writeOnly,
      );
      var transferredBytes = resumedBytes;
      try {
        await for (final chunk in response) {
          if (cancelToken?.isCancelled ?? false) {
            throw const TransferCancelledException('下载');
          }
          sink.add(chunk);
          transferredBytes += chunk.length;
          onProgress?.call(transferredBytes, totalBytes);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      if (cancelToken?.isCancelled ?? false) {
        throw const TransferCancelledException('下载');
      }

      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await partialFile.rename(targetFile.path);
    } on TransferCancelledException {
      rethrow;
    } on HttpException {
      rethrow;
    } on SocketException {
      if (cancelToken?.isCancelled ?? false) {
        throw const TransferCancelledException('下载');
      }
      rethrow;
    } finally {
      cancelToken?.removeListener(abortRequest);
      httpClient.close(force: true);
    }
    return targetFile;
  }

  Future<Uint8List> downloadBytes(String relativePath) async {
    final response = await _httpClient.get(
      _buildUri(relativePath),
      headers: _buildRequestHeaders(),
    );
    if (response.statusCode >= 400) {
      final errorBody = _tryDecodeJson(response.bodyBytes);
      throw HttpException(
        '下载失败: ${response.statusCode}, ${jsonEncode(errorBody ?? response.body)}',
      );
    }
    return response.bodyBytes;
  }

  String buildPermanentToken({
    required String publicKeyPem,
    String? nonce,
    int? timestamp,
  }) {
    return buildEncryptedPayloadToken(
      publicKeyPem: publicKeyPem,
      payload: <String, dynamic>{
        'ts': timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'nonce': nonce ?? _generateNonce(),
      },
    );
  }

  String buildFolderPasswordToken({
    required String publicKeyPem,
    required String folderId,
    required String password,
    String? nonce,
    int? timestamp,
  }) {
    return buildEncryptedPayloadToken(
      publicKeyPem: publicKeyPem,
      payload: <String, dynamic>{
        'ts': timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'nonce': nonce ?? _generateNonce(),
        'folderId': folderId,
        'password': password,
      },
    );
  }

  String buildEncryptedPayloadToken({
    required String publicKeyPem,
    required Map<String, dynamic> payload,
  }) {
    final publicKey = _parsePublicKeyFromPem(publicKeyPem);
    final plaintext = jsonEncode(payload);
    final encryptedBytes = _rsaEncryptPkcs1(
      plainBytes: Uint8List.fromList(utf8.encode(plaintext)),
      publicKey: publicKey,
    );
    return base64Encode(encryptedBytes);
  }

  void close() {
    _httpClient.close();
  }

  Map<String, String> _buildManagementHeaders({
    required String publicKeyPem,
    String? nonce,
    int? timestamp,
  }) {
    return <String, String>{
      permanentTokenHeader: buildPermanentToken(
        publicKeyPem: publicKeyPem,
        nonce: nonce,
        timestamp: timestamp,
      ),
    };
  }

  Map<String, String> _buildFolderPasswordHeaders({
    required String publicKeyPem,
    String? folderId,
    String? password,
  }) {
    final normalizedFolderId = folderId?.trim() ?? '';
    final normalizedPassword = password?.trim() ?? '';
    if (normalizedFolderId.isEmpty || normalizedPassword.isEmpty) {
      return const <String, String>{};
    }
    return <String, String>{
      folderPasswordTokenHeader: buildFolderPasswordToken(
        publicKeyPem: publicKeyPem,
        folderId: normalizedFolderId,
        password: normalizedPassword,
      ),
    };
  }

  Map<String, String> _buildTargetFolderPasswordHeaders({
    required String publicKeyPem,
    String? folderId,
    String? password,
  }) {
    final normalizedFolderId = folderId?.trim() ?? '';
    final normalizedPassword = password?.trim() ?? '';
    if (normalizedFolderId.isEmpty || normalizedPassword.isEmpty) {
      return const <String, String>{};
    }
    return <String, String>{
      targetFolderPasswordTokenHeader: buildFolderPasswordToken(
        publicKeyPem: publicKeyPem,
        folderId: normalizedFolderId,
        password: normalizedPassword,
      ),
    };
  }

  Map<String, String> _mergeHeaders(
    Map<String, String>? left,
    Map<String, String>? right,
  ) {
    final result = <String, String>{};
    if (left != null && left.isNotEmpty) {
      result.addAll(left);
    }
    if (right != null && right.isNotEmpty) {
      result.addAll(right);
    }
    return result;
  }

  Map<String, String> _buildRequestHeaders([
    Map<String, String>? extraHeaders,
  ]) {
    final headers = <String, String>{};
    final appChannel = Global.appChannel.trim();
    final user = Global.user.trim();

    if (appChannel.isNotEmpty) {
      headers[appChannelHeader] = _sanitizeHeaderValue(appChannel);
    }
    if (user.isNotEmpty) {
      headers[userHeader] = _sanitizeHeaderValue(user);
    }
    if (extraHeaders != null && extraHeaders.isNotEmpty) {
      headers.addAll(extraHeaders);
    }
    return headers;
  }

  Future<Map<String, dynamic>> _uploadFile({
    required File file,
    String? folderId,
    Map<String, String>? extraHeaders,
    TransferProgressCallback? onProgress,
    TransferCancellationToken? cancelToken,
  }) async {
    final uri = _buildUri('/api/upload');
    final fileLength = await file.length();
    final boundary =
        '----courage-storage-${DateTime.now().microsecondsSinceEpoch}';
    final fileName = file.path.split(RegExp(r'[\\/]')).last;
    final safeFileName = _buildAsciiFileName(fileName);
    final encodedFileName = Uri.encodeComponent(fileName);
    final folderFieldBytes = folderId == null || folderId.trim().isEmpty
        ? const <int>[]
        : utf8.encode(
            '--$boundary\r\n'
            'Content-Disposition: form-data; name="folderId"\r\n\r\n'
            '${folderId.trim()}\r\n',
          );
    final prefixBytes = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="$safeFileName"; filename*=UTF-8\'\'$encodedFileName\r\n'
      'Content-Type: application/octet-stream\r\n\r\n',
    );
    final suffixBytes = utf8.encode('\r\n--$boundary--\r\n');

    final httpClient = HttpClient();
    void abortRequest() {
      httpClient.close(force: true);
    }

    cancelToken?.addListener(abortRequest);
    try {
      final request = await httpClient.postUrl(uri);
      _applyHeaders(request.headers, _buildRequestHeaders(extraHeaders));
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      request.contentLength =
          folderFieldBytes.length + prefixBytes.length + fileLength + suffixBytes.length;

      if (folderFieldBytes.isNotEmpty) {
        request.add(folderFieldBytes);
      }
      request.add(prefixBytes);
      onProgress?.call(0, fileLength);

      var transferredBytes = 0;
      await for (final chunk in file.openRead()) {
        if (cancelToken?.isCancelled ?? false) {
          throw const TransferCancelledException('上传');
        }
        request.add(chunk);
        transferredBytes += chunk.length;
        onProgress?.call(transferredBytes, fileLength);
      }
      request.add(suffixBytes);

      final response = await request.close();
      final responseBytes = await _collectResponseBytes(response);
      return _decodeJsonBytes(response.statusCode, responseBytes);
    } on TransferCancelledException {
      rethrow;
    } on SocketException {
      if (cancelToken?.isCancelled ?? false) {
        throw const TransferCancelledException('上传');
      }
      rethrow;
    } finally {
      cancelToken?.removeListener(abortRequest);
      httpClient.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _uploadFileResumable({
    required File file,
    String? folderId,
    Map<String, String>? extraHeaders,
    TransferProgressCallback? onProgress,
    TransferCancellationToken? cancelToken,
  }) async {
    final fileLength = await file.length();
    if (fileLength <= 0) {
      return _uploadFile(
        file: file,
        folderId: folderId,
        extraHeaders: extraHeaders,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }

    final fileModifiedAt = await file.lastModified();
    final fileName = file.path.split(RegExp(r'[\\/]')).last.trim();
    final isPermanentUpload =
        extraHeaders?[permanentTokenHeader]?.trim().isNotEmpty ?? false;
    final localKey = _buildResumableUploadLocalKey(
      filePath: file.path,
      fileSize: fileLength,
      fileModifiedAtMs: fileModifiedAt.millisecondsSinceEpoch,
      permanent: isPermanentUpload,
      folderId: folderId,
    );

    var localRecord = await _loadResumableUploadLocalRecord(localKey);
    if (localRecord != null &&
        !_matchesResumableUploadFile(
          localRecord,
          file: file,
          fileSize: fileLength,
          fileModifiedAtMs: fileModifiedAt.millisecondsSinceEpoch,
          permanent: isPermanentUpload,
          folderId: folderId,
        )) {
      await _deleteResumableUploadLocalRecord(localKey);
      localRecord = null;
    }

    try {
      final restoredRecord = await _restoreOrCreateResumableUploadRecord(
        file: file,
        fileLength: fileLength,
        fileName: fileName,
        permanent: isPermanentUpload,
        folderId: folderId,
        localKey: localKey,
        existingRecord: localRecord,
        extraHeaders: extraHeaders,
      );
      localRecord = restoredRecord ?? localRecord;
    } on _ResumableUploadUnsupportedException {
      return _uploadFile(
        file: file,
        extraHeaders: extraHeaders,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }

    if (localRecord == null) {
      throw HttpException('初始化续传上传会话失败');
    }

    var activeRecord = localRecord;
    var uploadedBytes = activeRecord.uploadedBytes.clamp(0, fileLength);
    var chunkSize = activeRecord.chunkSizeHint > 0
      ? activeRecord.chunkSizeHint
        : _defaultResumableChunkSize;
    onProgress?.call(uploadedBytes, fileLength);

    var recoveryAttempts = 0;
    while (uploadedBytes < fileLength) {
      if (cancelToken?.isCancelled ?? false) {
        throw const TransferCancelledException('上传');
      }

      final nextEnd = min(uploadedBytes + chunkSize, fileLength);
      try {
        final remoteUploadedBytes = await _uploadResumableChunk(
          file: file,
          record: activeRecord,
          start: uploadedBytes,
          end: nextEnd,
          cancelToken: cancelToken,
        );
        uploadedBytes = remoteUploadedBytes.clamp(0, fileLength);
        recoveryAttempts = 0;
        activeRecord = activeRecord.copyWith(uploadedBytes: uploadedBytes);
        await _saveResumableUploadLocalRecord(activeRecord);
        onProgress?.call(uploadedBytes, fileLength);
      } on _ResumableUploadOffsetMismatchException catch (error) {
        uploadedBytes = error.uploadedBytes.clamp(0, fileLength);
        activeRecord = activeRecord.copyWith(uploadedBytes: uploadedBytes);
        await _saveResumableUploadLocalRecord(activeRecord);
        onProgress?.call(uploadedBytes, fileLength);
      } on _ResumableUploadSessionUnavailableException {
        await _deleteResumableUploadLocalRecord(localKey);
        if (recoveryAttempts >= 1) {
          throw HttpException('续传会话失效，请重新上传');
        }
        recoveryAttempts += 1;
        activeRecord = await _createResumableUploadRecord(
          file: file,
          fileLength: fileLength,
          fileName: fileName,
          permanent: isPermanentUpload,
          folderId: folderId,
          localKey: localKey,
          extraHeaders: extraHeaders,
        );
        uploadedBytes = activeRecord.uploadedBytes;
        chunkSize = activeRecord.chunkSizeHint > 0
          ? activeRecord.chunkSizeHint
            : _defaultResumableChunkSize;
        onProgress?.call(uploadedBytes, fileLength);
      } on _ResumableUploadChunkTooLargeException {
        final reducedChunkSize = _reduceResumableChunkSize(chunkSize);
        if (reducedChunkSize >= chunkSize) {
          throw HttpException(
            '上传分片过大，服务器或网关返回 HTTP 413。请调大服务端上传限制，或继续使用不超过 ${_minimumResumableChunkSize ~/ 1024} KB 的分片。',
          );
        }
        chunkSize = reducedChunkSize;
        activeRecord = activeRecord.copyWith(chunkSizeHint: chunkSize);
        await _saveResumableUploadLocalRecord(activeRecord);
      } on SocketException {
        if (cancelToken?.isCancelled ?? false) {
          throw const TransferCancelledException('上传');
        }
        if (recoveryAttempts >= 3) {
          rethrow;
        }
        final refreshedRecord = await _refreshResumableUploadRecord(activeRecord);
        if (refreshedRecord == null) {
          rethrow;
        }
        recoveryAttempts += 1;
        activeRecord = refreshedRecord;
        uploadedBytes = activeRecord.uploadedBytes.clamp(0, fileLength);
        chunkSize = activeRecord.chunkSizeHint > 0
            ? activeRecord.chunkSizeHint
            : _defaultResumableChunkSize;
        onProgress?.call(uploadedBytes, fileLength);
      } on HttpException {
        final refreshedRecord = await _refreshResumableUploadRecord(activeRecord);
        if (refreshedRecord == null || refreshedRecord.uploadedBytes == uploadedBytes) {
          rethrow;
        }
        activeRecord = refreshedRecord;
        uploadedBytes = activeRecord.uploadedBytes.clamp(0, fileLength);
        chunkSize = activeRecord.chunkSizeHint > 0
            ? activeRecord.chunkSizeHint
            : _defaultResumableChunkSize;
        onProgress?.call(uploadedBytes, fileLength);
      }
    }

    final result = await _completeResumableUpload(activeRecord);
    await _deleteResumableUploadLocalRecord(localKey);
    return result;
  }

  Future<_ResumableUploadLocalRecord?> _restoreOrCreateResumableUploadRecord({
    required File file,
    required int fileLength,
    required String fileName,
    required bool permanent,
    required String? folderId,
    required String localKey,
    required _ResumableUploadLocalRecord? existingRecord,
    Map<String, String>? extraHeaders,
  }) async {
    if (existingRecord == null) {
      return _createResumableUploadRecord(
        file: file,
        fileLength: fileLength,
        fileName: fileName,
        permanent: permanent,
        folderId: folderId,
        localKey: localKey,
        extraHeaders: extraHeaders,
      );
    }

    final refreshedRecord = await _refreshResumableUploadRecord(existingRecord);
    if (refreshedRecord != null) {
      return refreshedRecord;
    }

    await _deleteResumableUploadLocalRecord(localKey);
    return _createResumableUploadRecord(
      file: file,
      fileLength: fileLength,
      fileName: fileName,
      permanent: permanent,
      folderId: folderId,
      localKey: localKey,
      extraHeaders: extraHeaders,
    );
  }

  Future<_ResumableUploadLocalRecord> _createResumableUploadRecord({
    required File file,
    required int fileLength,
    required String fileName,
    required bool permanent,
    required String? folderId,
    required String localKey,
    Map<String, String>? extraHeaders,
  }) async {
    final initResponse = await _initResumableUpload(
      fileName: fileName,
      fileSize: fileLength,
      folderId: folderId,
      extraHeaders: extraHeaders,
    );
    final data = _responseDataMap(initResponse);
    final localRecord = _ResumableUploadLocalRecord(
      localKey: localKey,
      uploadId: _requireStringField(data, 'uploadId'),
      uploadToken: _requireStringField(data, 'uploadToken'),
      filePath: file.path,
      fileName: fileName,
      fileSize: fileLength,
      fileModifiedAtMs: (await file.lastModified()).millisecondsSinceEpoch,
      permanent: permanent,
        folderId: folderId,
      storage: (_optionalStringField(data, 'storage') ??
              (permanent ? 'permanent' : 'temporary'))
          .trim(),
      relativePath: _optionalStringField(data, 'path') ?? '',
      systemName: _optionalStringField(data, 'name') ?? '',
      indexedName: _optionalStringField(data, 'indexedName') ?? fileName,
      mimeType: _optionalStringField(data, 'mimeType') ?? 'application/octet-stream',
      totalSize: _intField(data, 'totalSize', fallback: fileLength),
      uploadedBytes: _intField(data, 'uploadedBytes', fallback: 0),
      chunkSizeHint: _intField(
        data,
        'chunkSizeHint',
        fallback: _defaultResumableChunkSize,
      ),
    );
    await _saveResumableUploadLocalRecord(localRecord);
    return localRecord;
  }

  Future<_ResumableUploadLocalRecord?> _refreshResumableUploadRecord(
    _ResumableUploadLocalRecord record,
  ) async {
    final response = await _getResumableUploadStatus(
      uploadId: record.uploadId,
      uploadToken: record.uploadToken,
    );
    if (response == null) {
      return null;
    }
    final data = _responseDataMap(response);
    final refreshedRecord = record.copyWith(
      storage: _optionalStringField(data, 'storage') ?? record.storage,
      relativePath: _optionalStringField(data, 'path') ?? record.relativePath,
      systemName: _optionalStringField(data, 'name') ?? record.systemName,
      indexedName: _optionalStringField(data, 'indexedName') ?? record.indexedName,
      mimeType: _optionalStringField(data, 'mimeType') ?? record.mimeType,
      totalSize: _intField(data, 'totalSize', fallback: record.totalSize),
      uploadedBytes: _intField(
        data,
        'uploadedBytes',
        fallback: record.uploadedBytes,
      ),
    );
    await _saveResumableUploadLocalRecord(refreshedRecord);
    return refreshedRecord;
  }

  Future<Map<String, dynamic>> _initResumableUpload({
    required String fileName,
    required int fileSize,
    String? folderId,
    Map<String, String>? extraHeaders,
  }) async {
    final request = http.Request('POST', _buildUri('/api/upload/resumable/init'));
    request.headers.addAll(_buildRequestHeaders(extraHeaders));
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    request.bodyBytes = utf8.encode(
      jsonEncode(<String, dynamic>{
        'filename': fileName,
        'size': fileSize,
        'mimeType': 'application/octet-stream',
        if (folderId != null && folderId.trim().isNotEmpty) 'folderId': folderId,
      }),
    );

    final response = await http.Response.fromStream(await _httpClient.send(request));
    final payload = _decodeJsonBytes(
      response.statusCode,
      response.bodyBytes,
      allowErrorStatus: true,
    );

    if (response.statusCode == HttpStatus.notFound) {
      throw const _ResumableUploadUnsupportedException();
    }
    if (response.statusCode >= 400) {
      throw HttpException(
        '初始化续传上传失败: HTTP ${response.statusCode}, body=${jsonEncode(payload)}',
      );
    }
    return payload;
  }

  Future<Map<String, dynamic>?> _getResumableUploadStatus({
    required String uploadId,
    required String uploadToken,
  }) async {
    final response = await _httpClient.get(
      _buildUri('/api/upload/resumable/$uploadId'),
      headers: _buildRequestHeaders(<String, String>{
        uploadTokenHeader: uploadToken,
      }),
    );
    final payload = _decodeJsonBytes(
      response.statusCode,
      response.bodyBytes,
      allowErrorStatus: true,
    );
    if (response.statusCode == HttpStatus.notFound ||
        response.statusCode == HttpStatus.unauthorized) {
      return null;
    }
    if (response.statusCode >= 400) {
      throw HttpException(
        '查询续传上传状态失败: HTTP ${response.statusCode}, body=${jsonEncode(payload)}',
      );
    }
    return payload;
  }

  Future<int> _uploadResumableChunk({
    required File file,
    required _ResumableUploadLocalRecord record,
    required int start,
    required int end,
    TransferCancellationToken? cancelToken,
  }) async {
    final httpClient = HttpClient();
    void abortRequest() {
      httpClient.close(force: true);
    }

    cancelToken?.addListener(abortRequest);
    try {
      final request = await httpClient.patchUrl(
        _buildUri('/api/upload/resumable/${record.uploadId}'),
      );
      request.persistentConnection = false;
      _applyHeaders(
        request.headers,
        _buildRequestHeaders(<String, String>{
          uploadTokenHeader: record.uploadToken,
          uploadOffsetHeader: start.toString(),
        }),
      );
      request.contentLength = end - start;
      await for (final chunk in file.openRead(start, end)) {
        if (cancelToken?.isCancelled ?? false) {
          throw const TransferCancelledException('上传');
        }
        request.add(chunk);
      }

      final response = await request.close();
      final responseBytes = await _collectResponseBytes(response);
      final payload = _decodeJsonBytes(
        response.statusCode,
        responseBytes,
        allowErrorStatus: true,
      );
      if (response.statusCode == HttpStatus.conflict) {
        final data = _responseDataMap(payload);
        throw _ResumableUploadOffsetMismatchException(
          uploadedBytes: _intField(data, 'uploadedBytes', fallback: start),
          totalSize: _intField(data, 'totalSize', fallback: record.totalSize),
        );
      }
      if (response.statusCode == HttpStatus.notFound ||
          response.statusCode == HttpStatus.unauthorized) {
        throw const _ResumableUploadSessionUnavailableException();
      }
      if (response.statusCode == HttpStatus.requestEntityTooLarge) {
        throw const _ResumableUploadChunkTooLargeException();
      }
      if (response.statusCode >= 400) {
        throw HttpException(
          '上传分片失败: HTTP ${response.statusCode}, body=${jsonEncode(payload)}',
        );
      }

      final data = _responseDataMap(payload);
      return _intField(data, 'uploadedBytes', fallback: end);
    } on HttpException catch (error) {
      if (_isUnexpectedUploadResponse(error)) {
        throw const _ResumableUploadChunkTooLargeException();
      }
      rethrow;
    } on TransferCancelledException {
      rethrow;
    } on SocketException {
      if (cancelToken?.isCancelled ?? false) {
        throw const TransferCancelledException('上传');
      }
      rethrow;
    } finally {
      cancelToken?.removeListener(abortRequest);
      httpClient.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _completeResumableUpload(
    _ResumableUploadLocalRecord record,
  ) async {
    final request = http.Request(
      'POST',
      _buildUri('/api/upload/resumable/${record.uploadId}/complete'),
    );
    request.headers.addAll(
      _buildRequestHeaders(<String, String>{uploadTokenHeader: record.uploadToken}),
    );

    final response = await http.Response.fromStream(await _httpClient.send(request));
    final payload = _decodeJsonBytes(
      response.statusCode,
      response.bodyBytes,
      allowErrorStatus: true,
    );
    if (response.statusCode == HttpStatus.notFound ||
        response.statusCode == HttpStatus.unauthorized) {
      throw const _ResumableUploadSessionUnavailableException();
    }
    if (response.statusCode >= 400) {
      throw HttpException(
        '完成续传上传失败: HTTP ${response.statusCode}, body=${jsonEncode(payload)}',
      );
    }
    return payload;
  }

  Future<Directory> _resumableUploadStateRoot() async {
    final rootDirectory = await getApplicationSupportDirectory();
    final stateDirectory = Directory(
      '${rootDirectory.path}${Platform.pathSeparator}$_resumableUploadStateDirectory',
    );
    await stateDirectory.create(recursive: true);
    return stateDirectory;
  }

  Future<File> _resumableUploadStateFile(String localKey) async {
    final rootDirectory = await _resumableUploadStateRoot();
    return File('${rootDirectory.path}${Platform.pathSeparator}$localKey.json');
  }

  Future<_ResumableUploadLocalRecord?> _loadResumableUploadLocalRecord(
    String localKey,
  ) async {
    final stateFile = await _resumableUploadStateFile(localKey);
    if (!await stateFile.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await stateFile.readAsString());
      if (decoded is! Map<String, dynamic>) {
        await stateFile.delete();
        return null;
      }
      return _ResumableUploadLocalRecord.fromJson(decoded);
    } catch (_) {
      await stateFile.delete();
      return null;
    }
  }

  Future<void> _saveResumableUploadLocalRecord(
    _ResumableUploadLocalRecord record,
  ) async {
    final stateFile = await _resumableUploadStateFile(record.localKey);
    await stateFile.writeAsString(jsonEncode(record.toJson()), flush: true);
  }

  Future<void> _deleteResumableUploadLocalRecord(String localKey) async {
    final stateFile = await _resumableUploadStateFile(localKey);
    if (await stateFile.exists()) {
      await stateFile.delete();
    }
  }

  bool _matchesResumableUploadFile(
    _ResumableUploadLocalRecord record, {
    required File file,
    required int fileSize,
    required int fileModifiedAtMs,
    required bool permanent,
    required String? folderId,
  }) {
    return record.filePath == file.path &&
        record.fileSize == fileSize &&
        record.fileModifiedAtMs == fileModifiedAtMs &&
        record.permanent == permanent &&
        record.folderId == folderId;
  }

  String _buildResumableUploadLocalKey({
    required String filePath,
    required int fileSize,
    required int fileModifiedAtMs,
    required bool permanent,
    required String? folderId,
  }) {
    final source = [
      baseUrl.trim(),
      filePath,
      fileSize.toString(),
      fileModifiedAtMs.toString(),
      permanent ? '1' : '0',
      folderId?.trim() ?? '',
    ].join('|');

    var hash = BigInt.parse('14695981039346656037');
    final prime = BigInt.parse('1099511628211');
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final byte in utf8.encode(source)) {
      hash = (hash ^ BigInt.from(byte)) * prime;
      hash &= mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  Uri _buildUri(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }

    final normalizedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$normalizedBase$normalizedPath');
  }

  Map<String, dynamic> _decodeJsonResponse(http.Response response) {
    return _decodeJsonBytes(response.statusCode, response.bodyBytes);
  }

  Map<String, dynamic> _decodeJsonBytes(
    int statusCode,
    Uint8List bodyBytes, {
    bool allowErrorStatus = false,
  }) {
    final decoded = _tryDecodeJson(bodyBytes);
    if (decoded == null || decoded is! Map<String, dynamic>) {
      if (allowErrorStatus && statusCode >= 400) {
        return _buildNonJsonErrorPayload(statusCode, bodyBytes);
      }
      throw HttpException('服务端未返回合法 JSON，HTTP 状态码: $statusCode');
    }

    if (statusCode >= 400 && !allowErrorStatus) {
      throw HttpException(
        '请求失败: HTTP $statusCode, body=${jsonEncode(decoded)}',
      );
    }

    return decoded;
  }

  Map<String, dynamic> _buildNonJsonErrorPayload(
    int statusCode,
    Uint8List bodyBytes,
  ) {
    var rawBody = utf8.decode(bodyBytes, allowMalformed: true).trim();
    if (rawBody.length > 200) {
      rawBody = '${rawBody.substring(0, 200)}...';
    }
    if (rawBody.isEmpty) {
      rawBody = '<empty>';
    }
    return <String, dynamic>{
      'code': statusCode,
      'message': statusCode == HttpStatus.requestEntityTooLarge
          ? 'request entity too large'
          : 'non-json error response',
      'data': <String, dynamic>{'rawBody': rawBody},
    };
  }

  int _reduceResumableChunkSize(int currentChunkSize) {
    if (currentChunkSize <= _minimumResumableChunkSize) {
      return currentChunkSize;
    }
    final halved = currentChunkSize ~/ 2;
    if (halved <= _minimumResumableChunkSize) {
      return _minimumResumableChunkSize;
    }
    return halved;
  }

  bool _isUnexpectedUploadResponse(HttpException error) {
    final message = error.message.toLowerCase();
    return message.contains('unexpected response') ||
        message.contains('unsolicited response without request');
  }

  Future<Uint8List> _collectResponseBytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  dynamic _tryDecodeJson(Uint8List bodyBytes) {
    try {
      return jsonDecode(utf8.decode(bodyBytes));
    } catch (_) {
      return null;
    }
  }

  String _sanitizeHeaderValue(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }

    final isAsciiOnly = trimmed.runes.every(
      (codePoint) => codePoint >= 0x20 && codePoint <= 0x7E,
    );
    if (isAsciiOnly) {
      return trimmed;
    }

    return Uri.encodeComponent(trimmed);
  }

  void _applyHeaders(HttpHeaders headers, Map<String, String> values) {
    values.forEach(headers.set);
  }

  String _buildAsciiFileName(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty) {
      return 'upload.bin';
    }

    final buffer = StringBuffer();
    for (final rune in trimmed.runes) {
      if (rune >= 0x20 && rune <= 0x7E && rune != 0x22 && rune != 0x5C) {
        buffer.writeCharCode(rune);
      } else {
        buffer.write('_');
      }
    }
    final normalized = buffer.toString();
    return normalized.isEmpty ? 'upload.bin' : normalized;
  }

  RSAPublicKey _parsePublicKeyFromPem(String pem) {
    final rows = pem
        .split('\n')
        .where(
          (line) =>
              line.isNotEmpty &&
              !line.startsWith('-----BEGIN') &&
              !line.startsWith('-----END'),
        )
        .toList();

    final derBytes = base64Decode(rows.join());
    final topLevelParser = ASN1Parser(Uint8List.fromList(derBytes));
    final topLevelSeq = topLevelParser.nextObject() as ASN1Sequence;
    final publicKeyBitString = topLevelSeq.elements[1] as ASN1BitString;

    final publicKeyAsn = ASN1Parser(publicKeyBitString.contentBytes());
    final publicKeySeq = publicKeyAsn.nextObject() as ASN1Sequence;
    final modulus = (publicKeySeq.elements[0] as ASN1Integer).valueAsBigInteger;
    final exponent =
        (publicKeySeq.elements[1] as ASN1Integer).valueAsBigInteger;

    return RSAPublicKey(modulus, exponent);
  }

  Uint8List _rsaEncryptPkcs1({
    required Uint8List plainBytes,
    required RSAPublicKey publicKey,
  }) {
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
    final output = <int>[];
    final inputBlockSize = cipher.inputBlockSize;
    for (var offset = 0; offset < plainBytes.length; offset += inputBlockSize) {
      final chunkSize = min(inputBlockSize, plainBytes.length - offset);
      final chunk = Uint8List.sublistView(
        plainBytes,
        offset,
        offset + chunkSize,
      );
      output.addAll(cipher.process(chunk));
    }
    return Uint8List.fromList(output);
  }

  String _generateNonce([int length = 16]) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var index = 0; index < length; index++) {
      buffer.write(chars[random.nextInt(chars.length)]);
    }
    return buffer.toString();
  }

  Map<String, dynamic> _responseDataMap(Map<String, dynamic> payload) {
    final data = payload['data'];
    if (data is Map<String, dynamic>) {
      return data;
    }
    throw HttpException('服务端响应缺少 data 对象: ${jsonEncode(payload)}');
  }

  String _requireStringField(Map<String, dynamic> data, String fieldName) {
    final value = _optionalStringField(data, fieldName);
    if (value == null || value.isEmpty) {
      throw HttpException('服务端响应缺少字段 $fieldName: ${jsonEncode(data)}');
    }
    return value;
  }

  String? _optionalStringField(Map<String, dynamic> data, String fieldName) {
    final value = data[fieldName];
    if (value is String) {
      return value;
    }
    return value?.toString();
  }

  int _intField(
    Map<String, dynamic> data,
    String fieldName, {
    required int fallback,
  }) {
    final value = data[fieldName];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  Map<String, String> _requireFolderHeaders({
    required String? publicKeyPem,
    required String? folderId,
    required String? folderPassword,
  }) {
    final normalizedFolderId = folderId?.trim() ?? '';
    final normalizedPassword = folderPassword?.trim() ?? '';
    if (normalizedFolderId.isEmpty) {
      return const <String, String>{};
    }
    if (normalizedPassword.isEmpty) {
      return const <String, String>{};
    }
    final normalizedPublicKeyPem = publicKeyPem?.trim() ?? '';
    if (normalizedPublicKeyPem.isEmpty) {
      throw StateError('加密文件夹操作需要服务端公钥');
    }
    return _buildFolderPasswordHeaders(
      publicKeyPem: normalizedPublicKeyPem,
      folderId: normalizedFolderId,
      password: normalizedPassword,
    );
  }
}

class _ResumableUploadLocalRecord {
  const _ResumableUploadLocalRecord({
    required this.localKey,
    required this.uploadId,
    required this.uploadToken,
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.fileModifiedAtMs,
    required this.permanent,
    required this.folderId,
    required this.storage,
    required this.relativePath,
    required this.systemName,
    required this.indexedName,
    required this.mimeType,
    required this.totalSize,
    required this.uploadedBytes,
    required this.chunkSizeHint,
  });

  final String localKey;
  final String uploadId;
  final String uploadToken;
  final String filePath;
  final String fileName;
  final int fileSize;
  final int fileModifiedAtMs;
  final bool permanent;
  final String? folderId;
  final String storage;
  final String relativePath;
  final String systemName;
  final String indexedName;
  final String mimeType;
  final int totalSize;
  final int uploadedBytes;
  final int chunkSizeHint;

  factory _ResumableUploadLocalRecord.fromJson(Map<String, dynamic> json) {
    return _ResumableUploadLocalRecord(
      localKey: json['localKey']?.toString() ?? '',
      uploadId: json['uploadId']?.toString() ?? '',
      uploadToken: json['uploadToken']?.toString() ?? '',
      filePath: json['filePath']?.toString() ?? '',
      fileName: json['fileName']?.toString() ?? '',
      fileSize: json['fileSize'] is int
          ? json['fileSize'] as int
          : int.tryParse(json['fileSize']?.toString() ?? '') ?? 0,
      fileModifiedAtMs: json['fileModifiedAtMs'] is int
          ? json['fileModifiedAtMs'] as int
          : int.tryParse(json['fileModifiedAtMs']?.toString() ?? '') ?? 0,
      permanent: json['permanent'] == true,
        folderId: json['folderId']?.toString(),
      storage: json['storage']?.toString() ?? '',
      relativePath: json['relativePath']?.toString() ?? '',
      systemName: json['systemName']?.toString() ?? '',
      indexedName: json['indexedName']?.toString() ?? '',
      mimeType: json['mimeType']?.toString() ?? 'application/octet-stream',
      totalSize: json['totalSize'] is int
          ? json['totalSize'] as int
          : int.tryParse(json['totalSize']?.toString() ?? '') ?? 0,
      uploadedBytes: json['uploadedBytes'] is int
          ? json['uploadedBytes'] as int
          : int.tryParse(json['uploadedBytes']?.toString() ?? '') ?? 0,
      chunkSizeHint: json['chunkSizeHint'] is int
          ? json['chunkSizeHint'] as int
          : int.tryParse(json['chunkSizeHint']?.toString() ?? '') ??
                ImageBedClient._defaultResumableChunkSize,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'localKey': localKey,
      'uploadId': uploadId,
      'uploadToken': uploadToken,
      'filePath': filePath,
      'fileName': fileName,
      'fileSize': fileSize,
      'fileModifiedAtMs': fileModifiedAtMs,
      'permanent': permanent,
      'folderId': folderId,
      'storage': storage,
      'relativePath': relativePath,
      'systemName': systemName,
      'indexedName': indexedName,
      'mimeType': mimeType,
      'totalSize': totalSize,
      'uploadedBytes': uploadedBytes,
      'chunkSizeHint': chunkSizeHint,
    };
  }

  _ResumableUploadLocalRecord copyWith({
    String? storage,
    String? relativePath,
    String? systemName,
    String? indexedName,
    String? mimeType,
    int? totalSize,
    int? uploadedBytes,
    int? chunkSizeHint,
  }) {
    return _ResumableUploadLocalRecord(
      localKey: localKey,
      uploadId: uploadId,
      uploadToken: uploadToken,
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      fileModifiedAtMs: fileModifiedAtMs,
      permanent: permanent,
      folderId: folderId,
      storage: storage ?? this.storage,
      relativePath: relativePath ?? this.relativePath,
      systemName: systemName ?? this.systemName,
      indexedName: indexedName ?? this.indexedName,
      mimeType: mimeType ?? this.mimeType,
      totalSize: totalSize ?? this.totalSize,
      uploadedBytes: uploadedBytes ?? this.uploadedBytes,
      chunkSizeHint: chunkSizeHint ?? this.chunkSizeHint,
    );
  }
}

class _ResumableUploadUnsupportedException implements Exception {
  const _ResumableUploadUnsupportedException();
}

class _ResumableUploadSessionUnavailableException implements Exception {
  const _ResumableUploadSessionUnavailableException();
}

class _ResumableUploadChunkTooLargeException implements Exception {
  const _ResumableUploadChunkTooLargeException();
}

class _ResumableUploadOffsetMismatchException implements Exception {
  const _ResumableUploadOffsetMismatchException({
    required this.uploadedBytes,
    required this.totalSize,
  });

  final int uploadedBytes;
  final int totalSize;
}
