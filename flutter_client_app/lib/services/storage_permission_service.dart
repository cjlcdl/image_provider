import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

enum StoragePermissionResult { granted, denied, permanentlyDenied }

class StoragePermissionService {
  static Future<StoragePermissionResult> ensureFileWritePermission() async {
    if (!Platform.isAndroid) {
      return StoragePermissionResult.granted;
    }

    final sdkInt = await _readAndroidSdkInt();

    if (sdkInt >= 30) {
      return _mapStatus(await Permission.manageExternalStorage.request());
    }

    return _mapStatus(await Permission.storage.request());
  }

  static Future<int> _readAndroidSdkInt() async {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    return androidInfo.version.sdkInt;
  }

  static StoragePermissionResult _mapStatus(PermissionStatus status) {
    if (status.isGranted) {
      return StoragePermissionResult.granted;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return StoragePermissionResult.permanentlyDenied;
    }
    return StoragePermissionResult.denied;
  }
}
