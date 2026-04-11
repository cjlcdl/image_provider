import 'dart:convert';

import 'package:courage_storage/controllers/file_manager_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loadPreferences restores saved base url preset selection', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'base_url_presets': jsonEncode(<Map<String, String>>[
        <String, String>{
          'id': 'staging',
          'name': '预发环境',
          'baseUrl': 'https://staging.example.com/',
        },
      ]),
      'selected_base_url_preset_id': 'staging',
    });

    final controller = FileManagerController(
      initialBaseUrl: 'https://prod.example.com/',
      publicKeyPem: 'test-key',
    );

    await controller.loadPreferences();

    expect(controller.baseUrl, 'https://staging.example.com');
    expect(controller.currentBaseUrlPreset.name, '预发环境');
    expect(controller.baseUrlPresets.length, 2);

    controller.dispose();
  });

  test('add select and remove custom base url preset', () async {
    final controller = FileManagerController(
      initialBaseUrl: 'https://prod.example.com/',
      publicKeyPem: 'test-key',
    );

    await controller.loadPreferences();

    final preset = await controller.addBaseUrlPreset(
      name: '本地开发',
      baseUrl: 'https://dev.example.com/',
    );

    expect(
      controller.baseUrlPresets.map((item) => item.baseUrl),
      contains('https://dev.example.com'),
    );

    final changed = await controller.selectBaseUrlPreset(preset.id);
    expect(changed, isTrue);
    expect(controller.baseUrl, 'https://dev.example.com');

    final removed = await controller.removeBaseUrlPreset(preset.id);
    expect(removed, isTrue);
    expect(controller.baseUrl, 'https://prod.example.com');
    expect(controller.baseUrlPresets.length, 1);
    expect(controller.currentBaseUrlPreset.isBuiltIn, isTrue);

    controller.dispose();
  });

  test('update selected custom base url preset', () async {
    final controller = FileManagerController(
      initialBaseUrl: 'https://prod.example.com/',
      publicKeyPem: 'test-key',
    );

    await controller.loadPreferences();

    final preset = await controller.addBaseUrlPreset(
      name: '测试环境',
      baseUrl: 'https://test.example.com/',
    );
    await controller.selectBaseUrlPreset(preset.id);

    final updatedPreset = await controller.updateBaseUrlPreset(
      presetId: preset.id,
      name: '测试环境2',
      baseUrl: 'https://test2.example.com/',
    );

    expect(updatedPreset.name, '测试环境2');
    expect(controller.baseUrl, 'https://test2.example.com');
    expect(controller.currentBaseUrlPreset.name, '测试环境2');

    controller.dispose();
  });
}
