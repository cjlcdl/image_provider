/// 文件模型 v3.0
/// 对应服务端 StoredFile 元数据结构
/// 新增 fileId 字段（12位短字符串自增ID），替代以 path 作为主标识的方式
class ManagedFile {
  const ManagedFile({
    required this.fileId,
    required this.indexedName,
    required this.systemName,
    required this.storage,
    required this.size,
    required this.mimeType,
    required this.path,
    required this.url,
    required this.folderId,
    required this.uploadedAt,
    this.sha256,
    this.extension,
    this.accessCount,
    this.lastAccessedAt,
    this.deletedAt,
    this.isDeleted = false,
    this.effectiveVisibility = 'public',
  });

  /// 12位短字符串文件ID（主标识）
  final String fileId;

  /// 用户可见文件名
  final String indexedName;

  /// 系统文件名（SHA256哈希.扩展名）
  final String systemName;

  /// 存储类型：temporary / permanent
  final String storage;

  /// 文件大小（字节）
  final int size;

  /// MIME类型
  final String mimeType;

  /// 文件访问路径（/p/{base64url} 格式）
  final String path;

  /// 文件访问URL（与 path 相同）
  final String url;

  /// 所属文件夹ID
  final String? folderId;

  /// 上传时间（ISO格式字符串）
  final String? uploadedAt;

  /// SHA-256 哈希值（v3.0 新增）
  final String? sha256;

  /// 文件扩展名（v3.0 新增）
  final String? extension;

  /// 访问次数（v3.0 新增）
  final int? accessCount;

  /// 最后访问时间（v3.0 新增）
  final String? lastAccessedAt;

  /// 删除时间（软删除标记）
  final String? deletedAt;

  /// 是否已删除
  final bool isDeleted;

  /// 有效可见性（由父文件夹链中最严格的级别决定）
  final String effectiveVisibility;

  /// 是否为临时文件
  bool get isTemporary => storage == 'temporary';

  /// 是否为永久文件
  bool get isPermanent => storage == 'permanent';

  /// 存储类型中文标签
  String get storageLabel => isTemporary ? '临时' : '永久';

  /// 从 API JSON 构造
  factory ManagedFile.fromJson(Map<String, dynamic> json) {
    return ManagedFile(
      fileId: (json['fileId'] ?? '').toString(),
      indexedName: (json['indexedName'] ?? '').toString(),
      systemName: (json['systemName'] ?? '').toString(),
      storage: (json['storage'] ?? '').toString(),
      size: (json['size'] as num?)?.toInt() ?? 0,
      mimeType: (json['mimeType'] ?? 'application/octet-stream').toString(),
      path: (json['path'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      folderId: json['folderId']?.toString(),
      uploadedAt: json['uploadedAt']?.toString(),
      sha256: json['sha256']?.toString(),
      extension: json['extension']?.toString(),
      accessCount: (json['accessCount'] as num?)?.toInt(),
      lastAccessedAt: json['lastAccessedAt']?.toString(),
      deletedAt: json['deletedAt']?.toString(),
      isDeleted: json['isDeleted'] == true,
      effectiveVisibility: (json['effectiveVisibility'] ?? 'public').toString(),
    );
  }

  /// 构建下载 URL（拼接 baseUrl）
  String downloadUrl(String baseUrl) {
    final trimmedBase = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$trimmedBase$url';
  }

  @override
  String toString() => 'ManagedFile(fileId: $fileId, name: $indexedName, storage: $storage)';
}
