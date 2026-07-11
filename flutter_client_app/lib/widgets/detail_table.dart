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
    required this.onFolderTap,
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
    this.onFolderAcceptDrop,
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
  final void Function(IndexedFolder folder, bool isCtrlHeld) onFolderTap;
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
  final void Function(IndexedFolder folder, List<ManagedFile> files)? onFolderAcceptDrop;
  final bool isDesktop;
  final IconData Function(IndexedFolder)? folderIcon;

  @override
  State<DetailTable> createState() => _DetailTableState();
}

class _DetailTableState extends State<DetailTable> {
  static const double _checkboxWidth = 48;
  static const double _rowHeight = 44;
  static const double _minColumnWidth = 60;
  static const double _dividerWidth = 6;

  IndexedFolder? _hoveredFolder;
  Offset? _contextMenuPosition;
  double _availableWidth = 600;
  final Map<DetailColumn, double> _dragWidths = <DetailColumn, double>{};

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
            ..._buildHeaderColumns(theme),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildHeaderColumns(ThemeData theme) {
    final cols = DetailColumn.values.toList();
    final widgets = <Widget>[];
    for (var i = 0; i < cols.length; i++) {
      final col = cols[i];
      final colWidth = _dragWidths[col] ?? _widthFor(col);
      final isActive = widget.sortColumn == col;
      widgets.add(
        SizedBox(
          width: colWidth,
          child: InkWell(
            onTap: () => widget.onSortChanged(col),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      _columnLabel(col),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight:
                            isActive ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (isActive)
                    Icon(
                      widget.sortDirection == SortDirection.asc
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 14,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      if (i < cols.length - 1) {
        final rightCol = cols[i + 1];
        widgets.add(
          _ColumnDivider(
            key: ValueKey('divider_$rightCol'),
            rightCol: rightCol,
            colWidth: _dragWidths[rightCol] ?? _widthFor(rightCol),
            onWidthUpdate: (w) => setState(() => _dragWidths[rightCol] = w),
            onWidthCommit: (w) {
              _dragWidths.remove(rightCol);
              final updated = Map<DetailColumn, double>.from(widget.columnWidths);
              updated[rightCol] = w;
              widget.onColumnWidthsChanged(updated);
              setState(() {});
            },
          ),
        );
      }
    }
    return widgets;
  }

  double _widthFor(DetailColumn col) {
    final availableTotal =
        _availableWidth - (widget.batchMode ? _checkboxWidth : 0);

    if (col == DetailColumn.name) {
      final dividerTotal =
          _dividerWidth * (DetailColumn.values.length - 1);
      final fixedWidths = DetailColumn.values
          .where((c) => c != DetailColumn.name)
          .fold<double>(0, (sum, c) => sum + _widthFor(c));
      return math.max(
        availableTotal - fixedWidths - dividerTotal,
        _minColumnWidth,
      );
    }

    final w = _dragWidths[col] ?? widget.columnWidths[col] ?? _defaultWidth(col);
    if (w <= 0) return _defaultWidth(col);
    return w.clamp(_minColumnWidth, 300.0);
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
              : (isFolder && _hoveredFolder?.id == row.folder?.id)
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
                  style: theme.textTheme.bodySmall,
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

    Widget result = InkWell(
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
          widget.onFolderTap(row.folder!, ctrl);
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

    // 桌面端：文件行支持长按拖拽到文件夹
    if (widget.isDesktop && isFile) {
      final file = row.file!;
      final isFileSelected = widget.selectedFilePaths.contains(file.path);
      result = LongPressDraggable<List<ManagedFile>>(
        data: isFileSelected && widget.selectedFilePaths.isNotEmpty
            ? widget.files
                .where((f) => widget.selectedFilePaths.contains(f.path))
                .toList(growable: false)
            : <ManagedFile>[file],
        delay: const Duration(milliseconds: 400),
        feedback: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.drive_file_move_outline, size: 18),
                const SizedBox(width: 6),
                Text(
                  isFileSelected && widget.selectedFilePaths.length > 1
                      ? '移动 ${widget.selectedFilePaths.length} 项'
                      : '移动文件',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        child: result,
      );
    }

    // 桌面端：文件夹行接收拖拽的文件
    if (widget.isDesktop && isFolder) {
      final child = result;
      result = DragTarget<List<ManagedFile>>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (details) {
          widget.onFolderAcceptDrop?.call(row.folder!, details.data);
        },
        builder: (context, candidateData, rejectedData) {
          return child;
        },
      );
    }

    return result;
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

/// 列间分隔条 — 拖动调整右侧列宽。光标绝对位置为判定基准。
class _ColumnDivider extends StatefulWidget {
  const _ColumnDivider({
    super.key,
    required this.rightCol,
    required this.colWidth,
    required this.onWidthUpdate,
    required this.onWidthCommit,
  });

  final DetailColumn rightCol;
  final double colWidth;
  final void Function(double) onWidthUpdate;
  final void Function(double) onWidthCommit;

  @override
  State<_ColumnDivider> createState() => _ColumnDividerState();
}

class _ColumnDividerState extends State<_ColumnDivider> {
  static const double _minWidth = 60;
  static const double _maxWidth = 300;

  double _startWidth = 0;
  double _startX = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (details) {
        _startWidth = widget.colWidth;
        _startX = details.globalPosition.dx;
      },
      onHorizontalDragUpdate: (details) {
        final w = (_startWidth - (details.globalPosition.dx - _startX))
            .clamp(_minWidth, _maxWidth)
            .toDouble();
        widget.onWidthUpdate(w);
      },
      onHorizontalDragEnd: (_) {
        widget.onWidthCommit(widget.colWidth);
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: Container(
          width: _DetailTableState._dividerWidth,
          color: Colors.transparent,
        ),
      ),
    );
  }
}
