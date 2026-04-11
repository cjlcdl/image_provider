class ManagedFile {
  const ManagedFile({
    required this.indexedName,
    required this.systemName,
    required this.storage,
    required this.size,
    required this.mimeType,
    required this.path,
    required this.url,
    required this.folderId,
    required this.uploadedAt,
  });

  final String indexedName;
  final String systemName;
  final String storage;
  final int size;
  final String mimeType;
  final String path;
  final String url;
  final String? folderId;
  final String? uploadedAt;

  bool get isTemporary => storage == 'temporary';
  bool get isPermanent => storage == 'permanent';
  String get storageLabel => isTemporary ? '临时' : '永久';

  factory ManagedFile.fromJson(Map<String, dynamic> json) {
    return ManagedFile(
      indexedName: (json['indexedName'] ?? '').toString(),
      systemName: (json['systemName'] ?? '').toString(),
      storage: (json['storage'] ?? '').toString(),
      size: (json['size'] as num?)?.toInt() ?? 0,
      mimeType: (json['mimeType'] ?? 'application/octet-stream').toString(),
      path: (json['path'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      folderId: json['folderId']?.toString(),
      uploadedAt: json['uploadedAt']?.toString(),
    );
  }
}
