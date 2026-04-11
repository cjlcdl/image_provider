import 'package:flutter/material.dart';

import 'generated_public_key.dart';

class Global {
  static const String baseUrl = String.fromEnvironment('BASE_URL');
  static const String appChannel = String.fromEnvironment('APP_CHANNEL');
  static const String user = String.fromEnvironment('USER');
  static const String appTitle = '勇气大存储';

  static const Color fallbackColorSeed = Colors.blue;
  static const bool useSystemColors = true;

  static const String? appFontFamily = null;
  static const _GlobalTextScale _textScale = _GlobalTextScale();

  static const String publicKeyPem = generatedPublicKeyPem;

  static String? get startupConfigurationError {
    final normalizedPublicKey = publicKeyPem.trim();
    if (normalizedPublicKey.isEmpty) {
      return '未检测到客户端公钥配置。\n请先在 flutter_client_app 目录执行 python generate_public_key_dart.py，再重新启动应用。';
    }
    if (!normalizedPublicKey.contains('BEGIN PUBLIC KEY') ||
        !normalizedPublicKey.contains('END PUBLIC KEY')) {
      return '客户端公钥配置格式无效。\n请检查 keys/permanent_public.pem，或重新执行 python generate_public_key_dart.py 生成 generated_public_key.dart。';
    }
    return null;
  }

  static void ensureStartupConfiguration() {
    final message = startupConfigurationError;
    if (message == null) {
      return;
    }
    throw StateError(message);
  }

  static TextStyle? _scaleTextStyle(TextStyle? style, double factor) {
    if (style == null) {
      return null;
    }
    final fontSize = style.fontSize;
    if (fontSize == null) {
      return style;
    }
    return style.copyWith(fontSize: fontSize * factor);
  }

  static TextTheme buildTextTheme({Brightness brightness = Brightness.light}) {
    final baseTheme = ThemeData(
      useMaterial3: true,
      brightness: brightness,
    ).textTheme;
    final themed = baseTheme.apply(fontFamily: appFontFamily);
    return themed.copyWith(
      displayLarge: _scaleTextStyle(themed.displayLarge, _textScale.displayLarge),
      displayMedium: _scaleTextStyle(themed.displayMedium, _textScale.displayMedium),
      displaySmall: _scaleTextStyle(themed.displaySmall, _textScale.displaySmall),
      headlineLarge: _scaleTextStyle(themed.headlineLarge, _textScale.headlineLarge),
      headlineMedium: _scaleTextStyle(themed.headlineMedium, _textScale.headlineMedium),
      headlineSmall: _scaleTextStyle(themed.headlineSmall, _textScale.headlineSmall),
      titleLarge: _scaleTextStyle(themed.titleLarge, _textScale.titleLarge),
      titleMedium: _scaleTextStyle(themed.titleMedium, _textScale.titleMedium),
      titleSmall: _scaleTextStyle(themed.titleSmall, _textScale.titleSmall),
      bodyLarge: _scaleTextStyle(themed.bodyLarge, _textScale.bodyLarge),
      bodyMedium: _scaleTextStyle(themed.bodyMedium, _textScale.bodyMedium),
      bodySmall: _scaleTextStyle(themed.bodySmall, _textScale.bodySmall),
      labelLarge: _scaleTextStyle(themed.labelLarge, _textScale.labelLarge),
      labelMedium: _scaleTextStyle(themed.labelMedium, _textScale.labelMedium),
      labelSmall: _scaleTextStyle(themed.labelSmall, _textScale.labelSmall),
    );
  }

  static ThemeData buildLightTheme() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: fallbackColorSeed,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      useSystemColors: useSystemColors,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      canvasColor: colorScheme.surface,
      cardColor: colorScheme.surface,
      dialogTheme: DialogThemeData(backgroundColor: colorScheme.surface),
      textTheme: buildTextTheme(),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
      ),
    );
  }
}

class _GlobalTextScale {
  const _GlobalTextScale();

  final double displayLarge = 0.7;
  final double displayMedium = 0.7;
  final double displaySmall = 0.7;
  final double headlineLarge = 0.7;
  final double headlineMedium = 0.7;
  final double headlineSmall = 0.7;
  final double titleLarge = 0.7;
  final double titleMedium = 0.7;
  final double titleSmall = 0.7;
  final double bodyLarge = 0.7;
  final double bodyMedium = 0.7;
  final double bodySmall = 0.7;
  final double labelLarge = 0.7;
  final double labelMedium = 0.7;
  final double labelSmall = 0.7;
}
