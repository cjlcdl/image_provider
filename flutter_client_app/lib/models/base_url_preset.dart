class BaseUrlPreset {
  const BaseUrlPreset({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.isBuiltIn = false,
  });

  final String id;
  final String name;
  final String baseUrl;
  final bool isBuiltIn;

  factory BaseUrlPreset.fromJson(Map<String, dynamic> json) {
    return BaseUrlPreset(
      id: (json['id'] ?? '').toString().trim(),
      name: (json['name'] ?? '').toString().trim(),
      baseUrl: (json['baseUrl'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'id': id, 'name': name, 'baseUrl': baseUrl};
  }
}
