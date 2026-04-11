import 'package:courage_storage/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('demo app renders title and bottom navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ImageProviderDemoApp(autoLoad: false));
    await tester.pump();

    expect(find.text('勇气大存储'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    await tester.tap(find.text('勇气大存储'));
    await tester.pumpAndSettle();

    expect(find.text('新增服务器'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
