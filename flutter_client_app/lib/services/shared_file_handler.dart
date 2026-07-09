import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 用于接收 Android 系统分享（"打开方式"）传入的文件。
///
/// 使用方式：
/// 1. 在应用启动时调用 [SharedFileHandler.instance.initialize]。
/// 2. 监听 [onSharedFilesReceived] 流获取分享的文件路径列表。
/// 3. 页面销毁时调用 [dispose] 清理。
class SharedFileHandler {
  SharedFileHandler._();

  static final SharedFileHandler instance = SharedFileHandler._();

  static const String _channelName = 'com.wao27cv.courage_storage/shared_files';

  MethodChannel? _channel;
  bool _initialized = false;

  final StreamController<List<String>> _fileStreamController =
      StreamController<List<String>>.broadcast();

  /// 监听从其他应用分享进来的文件路径列表。
  Stream<List<String>> get onSharedFilesReceived =>
      _fileStreamController.stream;

  /// 是否在 Android 平台上可用。
  bool get isAvailable => Platform.isAndroid;

  /// 初始化 MethodChannel 并检查初始分享意图。
  ///
  /// 应在 [WidgetsFlutterBinding.ensureInitialized] 之后调用。
  void initialize() {
    if (_initialized || !isAvailable) return;
    _initialized = true;

    _channel = const MethodChannel(_channelName);
    _channel!.setMethodCallHandler(_handleMethodCall);

    // 检查是否有初始分享文件（冷启动时通过分享菜单打开）
    _checkInitialSharedFiles();
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onSharedFilesReceived':
        final files = List<String>.from(call.arguments as List<dynamic>);
        if (files.isNotEmpty) {
          _fileStreamController.add(files);
        }
    }
  }

  Future<void> _checkInitialSharedFiles() async {
    try {
      final result = await _channel?.invokeMethod<List<dynamic>>(
        'getSharedFiles',
      );
      if (result != null && result.isNotEmpty) {
        _fileStreamController.add(List<String>.from(result));
      }
    } catch (e) {
      debugPrint('SharedFileHandler: 获取初始分享文件失败: $e');
    }
  }

  /// 释放资源。
  void dispose() {
    _fileStreamController.close();
    _initialized = false;
  }
}
