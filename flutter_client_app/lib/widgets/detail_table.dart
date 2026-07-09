import 'dart:math' as math;

import 'package:courage_storage/models/indexed_folder.dart';
import 'package:courage_storage/models/managed_file.dart';
import 'package:courage_storage/widgets/managed_file_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 文件列表列定义。
enum DetailColumn {
  name,
  type,
  size,
  uploadedAt,
}

/// 列头排序方向。
enum SortDirection { asc, desc }

/// 详情表视图组件 — 类似 Windows 资源管理器的"详细信息"视图。
///
/// 支持：
/// - 可点击列头排序
/// - 可拖拽调整列宽
/// - 右键上下文菜单（桌面端）
/// - 拖拽文件到文件夹行触发上传
class DetailTable extends StatefulWidget {
  const DetailTable({
    super.key,
    required this.files,
    required this.folders,
    required this.selectedFilePaths,
    required this.selectedFolderIds,
    required this.batchMode,
    this.sortColumn,
    this.sortDirection,
    required this.columnWidths,
    required this.onFileTap,
    required this.onFileDoubleTap,
    required this.onFolderDoubleTap,
    this.onFileContextMenu,
    this.onFolderContextMenu,
    required this.onToggleFileSelection,
    required this.onToggleFolderSelection,
    required this.onSortChanged,
    required this.onColumnWidthsChanged,
    this.onDragToFolder,
    this.onFolderHover,
    this.onFolderUnhover,
    this.isDesktop = false,
    this.folderIcon,
  });

  final List<ManagedFile> files;
  final List<IndexedFolder> folders;
  final Set<String> selectedFilePaths;
  final Set<String> selectedFolderIds;
  final bool batchMode;
  final DetailColumn? sortColumn;
  final SortDirection? sortDirection;
  final Map<DetailColumn, double> columnWidths;
  final void Function(ManagedFile file, bool isCtrlHeld) onFileTap;
  final void Function(ManagedFile) onFileDoubleTap;
  final void Function(IndexedFolder) onFolderDoubleTap;
  final void Function(ManagedFile, Offset)? onFileContextMenu;
  final void Function(IndexedFolder, Offset)? onFolderContextMenu;
  final void Function(ManagedFile, bool) onToggleFileSelection;
  final void Function(IndexedFolder, bool) onToggleFolderSelection;
  final void Function(DetailColumn) onSortChanged;
  final void Function(Map<DetailColumn, double>) onColumnWidthsChanged;
  final void Function(IndexedFolder)? onDragToFolder;
  final void Function(IndexedFolder)? onFolderHover;
  final VoidCallback? onFolderUnhover;
  final bool isDesktop;
  final IconData Function(IndexedFolder)? folderIcon;

  @override
  State<DetailTable> createState() => _DetailTableState();
}

class _DetailTableState extends State<DetailTable> {
  static const double _checkboxWidth = 48;
  static const double _rowHeight = 44;
  static const double _minColumnWidth = 60;

  IndexedFolder? _hoveredFolder;
  Offset? _contextMenuPosition;
  double _availableWidth = 600;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allItems = <_DetailRow>[
      for (final folder in widget.folders)
        _DetailRow.folder(folder),
      for (final file in widget.files)
        _DetailRow.file(file),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        _availableWidth = constraints.maxWidth;
        return Column(
          children: <Widget>[
            _buildHeader(theme),
            Expanded(
              child: Listener(
                onPointerDown: widget.isDesktop ? _clearContextMenu : null,
                child: ListView.builder(
                  itemCount: allItems.length,
                  itemExtent: _rowHeight,
                  itemBuilder: (context, index) {
                    final row = allItems[index];
                    return _buildRow(context, row, theme);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _clearContextMenu(PointerDownEvent event) {
    if (_contextMenuPosition != null) {
      setState(() {
        _contextMenuPosition = null;
      });
    }
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      height: _rowHeight,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3)),
        ),
      ),
      child: ClipRect(
        child: Row(
          children: <Widget>[
            if (widget.batchMode)
              const SizedBox(width: _checkboxWidth, height: _rowHeight),
            ...DetailColumn.values.map((col) {
            final isActive = widget.sortColumn == col;
            return _ResizableColumnHeader(
              width: _widthFor(col),
              minWidth: _minColumnWidth,
              label: _columnLabel(col),
              active: isActive,
              ascending: widget.sortDirection == SortDirection.asc,
              onTap: () => widget.onSortChanged(col),
              onResized: (newWidth) {
                final updated = Map<DetailColumn, double>.from(
                  widget.columnWidths,
                );
                updated[col] = newWidth;
                widget.onColumnWidthsChanged(updated);
              },
            );
          }),
        ],
        ),
      ),
    );
  }

  double _widthFor(DetailColumn col) {
    if (col == DetailColumn.name) {
      final fixedWidths = DetailColumn.values
          .where((c) => c != DetailColumn.name)
          .fold<double>(0, (sum, c) => sum + _widthFor(c));
      final available =
          _availableWidth -
          (widget.batchMode ? _checkboxWidth : 0) -
          fixedWidths;
      return math.max(available, _minColumnWidth);
    }
    final w = widget.columnWidths[col] ?? _defaultWidth(col);
    if (w <= 0) return _defaultWidth(col);
    return w;
  }

  double _defaultWidth(DetailColumn col) => switch (col) {
    DetailColumn.name => 200,
    DetailColumn.type => 120,
    DetailColumn.size => 100,
    DetailColumn.uploadedAt => 160,
  };

  String _columnLabel(DetailColumn col) => switch (col) {
    DetailColumn.name => '名称',
    DetailColumn.type => '类型',
    DetailColumn.size => '大小',
    DetailColumn.uploadedAt => '上传时间',
  };

  Widget _buildRow(BuildContext context, _DetailRow row, ThemeData theme) {
    final isFile = row.file != null;
    final isFolder = row.folder != null;
    final isSelected = isFile
        ? widget.selectedFilePaths.contains(row.file!.path)
        : widget.selectedFolderIds.contains(row.folder!.id);

    Widget rowWidget = MouseRegion(
      onEnter: isFolder ? (_) {
        setState(() => _hoveredFolder = row.folder);
        widget.onFolderHover?.call(row.folder!);
      } : null,
      onExit: isFolder ? (_) {
        if (_hoveredFolder?.id == row.folder?.id) {
          setState(() => _hoveredFolder = null);
        }
        widget.onFolderUnhover?.call();
      } : null,
      child: Container(
        height: _rowHeight,
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
              : _hoveredFolder?.id == row.folder?.id
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.15)
              : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.12),
            ),
          ),
        ),
        child: ClipRect(
          child: Row(
            children: <Widget>[
                if (widget.batchMode)
                SizedBox(
                  width: _checkboxWidth,
                  child: Checkbox(
                    value: isSelected,
                    onChanged: (value) {
                      if (isFile) {
                        widget.onToggleFileSelection(
                          row.file!,
                          value ?? false,
                        );
                      } else if (isFolder) {
                        widget.onToggleFolderSelection(
                          row.folder!,
                          value ?? false,
                        );
                      }
                    },
                  ),
                ),
              _buildCell(
                _nameContent(row, theme),
                _widthFor(DetailColumn.name),
              ),
              if (isFile) ...[
                _buildCell(
                  Text(
                    ManagedFileTile.fileTypeLabel(row.file!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  _widthFor(DetailColumn.type),
                ),
                _buildCell(
                  Text(
                    ManagedFileTile.formatSize(row.file!.size),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  _widthFor(DetailColumn.size),
                ),
              ] else ...[
                _buildCell(
                  Text('文件夹', style: theme.textTheme.bodySmall),
                  _widthFor(DetailColumn.type),
                ),
                _buildCell(
                  const Text(''),
                  _widthFor(DetailColumn.size),
                ),
              ],
              _buildCell(
                Text(
                  isFile
                      ? ManagedFileTile.formatUploadedAt(row.file!.uploadedAt)
                      : '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
                _widthFor(DetailColumn.uploadedAt),
              ),
            ],
          ),
        ),
      ),
    );

    if (widget.isDesktop) {
      rowWidget = GestureDetector(
        onSecondaryTapDown: (details) {
          setState(() {
            _contextMenuPosition = details.globalPosition;
            _hoveredFolder = row.folder;
          });
          if (isFile) {
            widget.onFileContextMenu?.call(row.file!, details.globalPosition);
          } else if (isFolder) {
            widget.onFolderContextMenu
                ?.call(row.folder!, details.globalPosition);
          }
        },
        child: rowWidget,
      );
    }

    return InkWell(
      onTap: () {
        final ctrl = HardwareKeyboard.instance.logicalKeysPressed
            .intersection(<LogicalKeyboardKey>{
              LogicalKeyboardKey.controlLeft,
              LogicalKeyboardKey.controlRight,
            })
            .isNotEmpty;
        if (isFile) {
          widget.onFileTap(row.file!, ctrl);
        } else if (isFolder) {
          widget.onToggleFolderSelection(
            row.folder!,
            !widget.selectedFolderIds.contains(row.folder!.id),
          );
        }
      },
      onDoubleTap: () {
        if (isFile) {
          widget.onFileDoubleTap(row.file!);
        } else if (isFolder) {
          widget.onFolderDoubleTap(row.folder!);
        }
      },
      child: rowWidget,
    );
  }

  Widget _nameContent(_DetailRow row, ThemeData theme) {
    final icon = row.folder != null
        ? widget.folderIcon?.call(row.folder!) ?? Icons.folder_outlined
        : ManagedFileTile.iconForFile(row.file!);
    final label = row.folder != null
        ? row.folder!.name
        : (row.file!.indexedName.isEmpty
            ? row.file!.systemName
            : row.file!.indexedName);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }

  Widget _buildCell(Widget child, double width) {
    return SizedBox(
      width: width.clamp(_minColumnWidth, _availableWidth),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: child,
        ),
      ),
    );
  }
}

/// 行数据模型。
class _DetailRow {
  const _DetailRow.file(this.file) : folder = null;
  const _DetailRow.folder(this.folder) : file = null;

  final ManagedFile? file;
  final IndexedFolder? folder;
}

/// 可拖拽调整宽度的列头 + 点击排序。
class _ResizableColumnHeader extends StatefulWidget {
  const _ResizableColumnHeader({
    required this.width,
    required this.minWidth,
    required this.label,
    required this.active,
    required this.ascending,
    required this.onTap,
    required this.onResized,
  });

  final double width;
  final double minWidth;
  final String label;
  final bool active;
  final bool ascending;
  final VoidCallback onTap;
  final void Function(double) onResized;

  @override
  State<_ResizableColumnHeader> createState() => _ResizableColumnHeaderState();
}

class _ResizableColumnHeaderState extends State<_ResizableColumnHeader> {
  static const double _handleWidth = 6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: widget.width,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: InkWell(
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight:
                              widget.active ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (widget.active)
                      Icon(
                        widget.ascending
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 14,
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) {
                final newWidth = (widget.width + details.delta.dx)
                    .clamp(widget.minWidth, 600.0)
                    .toDouble();
                widget.onResized(newWidth);
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: Container(
                  width: _handleWidth,
                  color: Colors.transparent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
