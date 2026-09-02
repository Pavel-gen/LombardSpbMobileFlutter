// Экран «Персональные уведомления»: проверяем, что нет мигания «форма → ✅»
// (сначала крутилка, потом последнее известное состояние), и что привязка
// восстанавливается с сервера. `flutter test`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lombardspb/services/app_log.dart';
import 'package:lombardspb/services/push_service.dart';
import 'package:lombardspb/screens/phone_verification_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PushService.resetForTest();
    AppLog.resetForTest();
    AppLog.httpClient = MockClient((_) async => http.Response('{}', 200));
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: PhoneVerificationScreen()));
  }

  testWidgets('первый кадр — крутилка, а не форма ввода', (tester) async {
    SharedPreferences.setMockInitialValues({'phone_verified': true});
    PushService.httpClient = MockClient((_) async => http.Response('{}', 200));

    await pumpScreen(tester);
    // до завершения _load()
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Введите номер телефона:'), findsNothing);

    await tester.pumpAndSettle();
  });

  testWidgets('локально привязан → сразу «уже подключили», без формы', (tester) async {
    SharedPreferences.setMockInitialValues({
      'phone_verified': true,
      'verified_user_id': 'u-1',
    });
    PushService.httpClient = MockClient((_) async => http.Response('{}', 200));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('уже подключили'), findsOneWidget);
    expect(find.text('Введите номер телефона:'), findsNothing);
  });

  testWidgets('локально НЕ привязан, сервер bound:true → показывает подключённое состояние', (tester) async {
    SharedPreferences.setMockInitialValues({});
    PushService.httpClient = MockClient((r) async {
      if (r.url.path.contains('bind-status')) {
        return http.Response('{"bound":true,"user_id":"srv-u","phone_mask":"+7•••95"}', 200);
      }
      return http.Response('{}', 200);
    });

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('уже подключили'), findsOneWidget);
  });

  testWidgets('локально НЕ привязан, сервер bound:false → форма ввода номера', (tester) async {
    SharedPreferences.setMockInitialValues({});
    PushService.httpClient = MockClient((r) async {
      if (r.url.path.contains('bind-status')) {
        return http.Response('{"bound":false}', 200);
      }
      return http.Response('{}', 200);
    });

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('Введите номер телефона:'), findsOneWidget);
    expect(find.textContaining('уже подключили'), findsNothing);
  });

  testWidgets('заголовок AppBar — короткий, без обрезки', (tester) async {
    SharedPreferences.setMockInitialValues({'phone_verified': true});
    PushService.httpClient = MockClient((_) async => http.Response('{}', 200));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('Уведомления'), findsOneWidget);
  });
}
