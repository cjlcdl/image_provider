import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:courage_storage/data/global.dart';
import 'package:courage_storage/pages/file_manager_page.dart';
import 'package:courage_storage/services/notification_service.dart';
import 'package:courage_storage/services/shared_file_handler.dart';

Future<void> _loadAppFonts() async {
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
  try {
    // 从可执行文件同级目录的 data/flutter_assets/fonts/ 读取
    final exeDir = File(Platform.resolvedExecutable).parent;
    final fontsDir = Directory('${exeDir.path}/data/flutter_assets/fonts');
    if (!await fontsDir.exists()) {
      debugPrint('AppFont: fonts dir not found at ${fontsDir.path}');
      return;
    }

    final allowedNames = <String>{'font.ttf', 'font.otf', 'fonts.ttf', 'fonts.otf'};
    final fontFiles = <File>[];
    await for (final entity in fontsDir.list()) {
      if (entity is File &&
          allowedNames.contains(entity.path.split(Platform.pathSeparator).last.toLowerCase())) {
        fontFiles.add(entity);
      }
    }

    if (fontFiles.isEmpty) return;

    var loadedCount = 0;
    for (final fontFile in fontFiles) {
      try {
        final bytes = await fontFile.readAsBytes();
        final loader = FontLoader('AppFont')
          ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
        await loader.load();
        loadedCount++;
      } catch (e) {
        debugPrint('AppFont: failed to load ${fontFile.path}: $e');
      }
    }

    // 只有全部字体加载成功才启用
    if (loadedCount == fontFiles.length && loadedCount > 0) {
      Global.customFontFamily = 'AppFont';
      debugPrint('AppFont: loaded $loadedCount font(s)');
    }
  } catch (e) {
    debugPrint('AppFont: init error: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedFileHandler.instance.initialize();
  NotificationService.instance.initialize();
  await _loadAppFonts();
  final startupError = Global.startupConfigurationError;
  runApp(ImageProviderDemoApp(startupError: startupError));
}

class ImageProviderDemoApp extends StatelessWidget {
  const ImageProviderDemoApp({
    super.key,
    this.autoLoad = true,
    this.startupError,
  });

  final bool autoLoad;
  final String? startupError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: Global.appTitle,
      theme: Global.buildLightTheme(),
      home: startupError == null
          ? FileManagerPage(autoLoad: autoLoad)
          : _StartupConfigurationErrorPage(message: startupError!),
    );
  }
}

class _StartupConfigurationErrorPage extends StatelessWidget {
  const _StartupConfigurationErrorPage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            Icons.key_off_rounded,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '启动配置错误',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        message,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '建议操作：',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      const SelectableText(
                        '1. 确认 keys/permanent_public.pem 存在\n'
                        '2. 在 flutter_client_app 目录执行 python generate_public_key_dart.py\n'
                        '3. 重新启动或重新构建客户端',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
