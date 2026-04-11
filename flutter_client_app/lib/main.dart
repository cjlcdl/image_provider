import 'package:flutter/material.dart';
import 'package:courage_storage/data/global.dart';
import 'package:courage_storage/pages/file_manager_page.dart';

void main() {
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
