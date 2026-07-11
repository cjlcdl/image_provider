class IndexedFolder {
  const IndexedFolder({
    required this.id,
    required this.name,
    required this.parentId,
    required this.encrypted,
    required this.allowDirectDownload,
    required this.visibility,
    required this.effectiveVisibility,
    required this.path,
    required this.depth,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? parentId;
  final bool encrypted;
  final bool allowDirectDownload;
  final String visibility;
  final String effectiveVisibility;
  final String path;
  final int depth;
  final String? createdAt;
  final String? updatedAt;

  bool get isRootChild => parentId == null || parentId!.isEmpty;

  factory IndexedFolder.fromJson(Map<String, dynamic> json) {
    return IndexedFolder(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      parentId: json['parentId']?.toString(),
      encrypted: json['encrypted'] == true,
      allowDirectDownload: json['allowDirectDownload'] == true,
      visibility: (json['visibility'] ?? 'public').toString(),
      effectiveVisibility: (json['effectiveVisibility'] ?? 'public').toString(),
      path: (json['path'] ?? '/').toString(),
      depth: (json['depth'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
    );
  }
}