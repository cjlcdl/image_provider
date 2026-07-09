import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Android 通知栏进度服务，用于在上传/下载时显示通知栏进度。
///
/// 使用方式：
/// 1. 在 main() 中调用 [NotificationService.instance.initialize]。
/// 2. 传输开始时调用 [showProgress]。
/// 3. 传输进度更新时调用 [updateProgress]。
/// 4. 传输完成/失败时调用 [complete] / [fail]。
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  int _nextId = 0;

  /// 仅 Android 平台可用
  bool get isAvailable => Platform.isAndroid;

  /// 初始化通知渠道（需在 main() 中调用一次）。
  Future<void> initialize() async {
    if (_initialized || !isAvailable) return;
    _initialized = true;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(settings: settings);

    // 创建传输进度通知渠道
    const channel = AndroidNotificationChannel(
      'courage_transfer_progress',
      '传输进度',
      description: '文件上传/下载进度通知',
      importance: Importance.low,
      enableVibration: false,
      playSound: false,
      showBadge: false,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  /// 显示传输进度通知，返回通知 ID。
  int showProgress({
    required String title,
    required String body,
    int maxProgress = 100,
  }) {
    if (!isAvailable) return -1;
    final id = _nextId++;
    _show(id, title, body, maxProgress: maxProgress, progress: 0);
    return id;
  }

  /// 更新进度。
  void updateProgress(int id, {required String body, required int progress, int? maxProgress}) {
    if (!isAvailable || id < 0) return;
    _show(id, '传输中…', body, maxProgress: maxProgress ?? 100, progress: progress);
  }

  /// 传输完成。
  void complete(int id, {required String body}) {
    if (!isAvailable || id < 0) return;
    _show(id, '传输完成', body, maxProgress: 0, progress: 0, ongoing: false);
    _plugin.cancel(id: id);
  }

  /// 传输失败。
  void fail(int id, {required String body}) {
    if (!isAvailable || id < 0) return;
    _show(id, '传输失败', body, maxProgress: 0, progress: 0, ongoing: false);
    _plugin.cancel(id: id);
  }

  /// 取消通知。
  void cancel(int id) {
    if (!isAvailable || id < 0) return;
    _plugin.cancel(id: id);
  }

  Future<void> _show(
    int id,
    String title,
    String body, {
    required int maxProgress,
    required int progress,
    bool ongoing = true,
  }) async {
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'courage_transfer_progress',
        '传输进度',
        channelDescription: '文件上传/下载进度通知',
        importance: Importance.low,
        priority: Priority.low,
        onlyAlertOnce: true,
        showProgress: maxProgress > 0,
        maxProgress: maxProgress,
        progress: progress,
        ongoing: ongoing,
        autoCancel: !ongoing,
      ),
    );

    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }
}
