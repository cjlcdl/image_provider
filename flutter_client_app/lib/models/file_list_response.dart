import 'package:courage_storage/models/managed_file.dart';

class FileListResponse {
  const FileListResponse({
    required this.total,
    required this.page,
    required this.pageSize,
    required this.returned,
    required this.totalPages,
    required this.filters,
    required this.files,
  });

  final int total;
  final int page;
  final int pageSize;
  final int returned;
  final int totalPages;
  final Map<String, dynamic> filters;
  final List<ManagedFile> files;

  factory FileListResponse.fromApi(Map<String, dynamic> payload) {
    final data = Map<String, dynamic>.from(payload['data'] as Map<String, dynamic>? ?? <String, dynamic>{});
    final files = (data['files'] as List<dynamic>? ?? <dynamic>[])
        .map((item) => ManagedFile.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();

    return FileListResponse(
      total: (data['total'] as num?)?.toInt() ?? files.length,
      page: (data['page'] as num?)?.toInt() ?? 1,
      pageSize: (data['pageSize'] as num?)?.toInt() ?? files.length,
      returned: (data['returned'] as num?)?.toInt() ?? files.length,
      totalPages: (data['totalPages'] as num?)?.toInt() ?? 0,
      filters: Map<String, dynamic>.from(data['filters'] as Map<String, dynamic>? ?? <String, dynamic>{}),
      files: files,
    );
  }
}
