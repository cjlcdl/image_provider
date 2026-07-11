import 'package:flutter/material.dart';
import 'package:courage_storage/data/global.dart';
import 'package:courage_storage/models/managed_file.dart';
import 'package:courage_storage/services/image_bed_client.dart';
import 'package:courage_storage/widgets/managed_file_tile.dart';

/// 回收站页面 — 显示已软删除的文件，支持恢复和永久删除
class TrashPage extends StatefulWidget {
  const TrashPage({super.key, required this.baseUrl});

  final String baseUrl;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  late final ImageBedClient _client = ImageBedClient(baseUrl: widget.baseUrl);

  bool _loading = false;
  String? _error;
  List<ManagedFile> _files = [];
  int _page = 1;
  int _totalPages = 1;
  int _total = 0;
  final Set<String> _selectedFileIds = {};

  @override
  void initState() {
    super.initState();
    _loadDeletedFiles();
  }

  Future<void> _loadDeletedFiles() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await _client.listDeletedFiles(
        publicKeyPem: Global.publicKeyPem,
        page: _page,
        pageSize: 50,
      );
      if (!mounted) return;
      setState(() {
        _files = response.files;
        _total = response.total;
        _totalPages = response.totalPages;
        _loading = false;
        _selectedFileIds.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _restoreSelected() async {
    if (_selectedFileIds.isEmpty) return;

    setState(() => _loading = true);
    try {
      await _client.restoreFiles(
        publicKeyPem: Global.publicKeyPem,
        fileIds: _selectedFileIds.toList(),
      );
      if (!mounted) return;
      _selectedFileIds.clear();
      await _loadDeletedFiles();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已恢复')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复失败: $e')),
      );
    }
  }

  Future<void> _permanentDeleteSelected() async {
    if (_selectedFileIds.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认永久删除'),
        content: Text('将永久删除 ${_selectedFileIds.length} 个文件，此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _loading = true);
    try {
      await _client.permanentDeleteFiles(
        publicKeyPem: Global.publicKeyPem,
        fileIds: _selectedFileIds.toList(),
      );
      if (!mounted) return;
      _selectedFileIds.clear();
      await _loadDeletedFiles();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已永久删除')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: $e')),
      );
    }
  }

  String _formatTime(String? isoTimestamp) {
    if (isoTimestamp == null) return '未知';
    try {
      final dt = DateTime.parse(isoTimestamp);
      return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
          '${_pad(dt.hour)}:${_pad(dt.minute)}:${_pad(dt.second)}';
    } catch (_) {
      return isoTimestamp;
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  void _toggleSelection(String fileId) {
    setState(() {
      if (_selectedFileIds.contains(fileId)) {
        _selectedFileIds.remove(fileId);
      } else {
        _selectedFileIds.add(fileId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        actions: [
          if (_selectedFileIds.isNotEmpty) ...[
            IconButton(
              onPressed: _loading ? null : _restoreSelected,
              icon: const Icon(Icons.restore_from_trash_outlined),
              tooltip: '恢复选中',
            ),
            IconButton(
              onPressed: _loading ? null : _permanentDeleteSelected,
              icon: Icon(Icons.delete_forever_outlined,
                  color: Theme.of(context).colorScheme.error),
              tooltip: '永久删除选中',
            ),
          ],
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _files.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败: $_error'),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _loadDeletedFiles,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, size: 64,
                color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text('回收站为空',
                style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadDeletedFiles,
      child: Column(
        children: [
          // 统计栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text('共 $_total 项',
                    style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                if (_selectedFileIds.isNotEmpty)
                  Text('已选 ${_selectedFileIds.length} 项',
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          // 文件列表
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _files.length + (_page < _totalPages ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _files.length) {
                  // 加载更多
                  if (!_loading) {
                    _page++;
                    _loadDeletedFiles();
                  }
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ),
                  );
                }

                final file = _files[index];
                final isSelected = _selectedFileIds.contains(file.fileId);
                final deletionTime = _formatTime(file.deletedAt);

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: Checkbox(
                      value: isSelected,
                      onChanged: (_) => _toggleSelection(file.fileId),
                    ),
                    title: Text(file.indexedName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${ManagedFileTile.formatSize(file.size)}  ·  删除于 $deletionTime',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) async {
                        if (action == 'restore') {
                          setState(() => _loading = true);
                          try {
                            await _client.restoreFiles(
                              publicKeyPem: Global.publicKeyPem,
                              fileIds: [file.fileId],
                            );
                            await _loadDeletedFiles();
                          } catch (e) {
                            setState(() => _loading = false);
                          }
                        } else if (action == 'delete') {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('确认永久删除'),
                              content: Text('将永久删除 "${file.indexedName}"'),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('取消')),
                                FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  style: FilledButton.styleFrom(
                                      backgroundColor:
                                          Theme.of(ctx).colorScheme.error),
                                  child: const Text('永久删除'),
                                ),
                              ],
                            ),
                          );
                          if (ok == true) {
                            setState(() => _loading = true);
                            try {
                              await _client.permanentDeleteFiles(
                                publicKeyPem: Global.publicKeyPem,
                                fileIds: [file.fileId],
                              );
                              await _loadDeletedFiles();
                            } catch (e) {
                              setState(() => _loading = false);
                            }
                          }
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                            value: 'restore',
                            child: ListTile(
                              leading: Icon(Icons.restore_outlined),
                              title: Text('恢复'),
                              dense: true,
                            )),
                        const PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                              leading: Icon(Icons.delete_forever_outlined,
                                  color: Colors.red),
                              title: Text('永久删除',
                                  style: TextStyle(color: Colors.red)),
                              dense: true,
                            )),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
