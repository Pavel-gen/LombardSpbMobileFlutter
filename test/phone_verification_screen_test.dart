// Экран «Персональные уведомления»: проверяем, что нет мигания «форма → ✅»
// (сначала крутилка, потом последнее известное состояние), и что привязка
// восстанавливается с сервера. `flutter test`.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lombardspb/services/app_log.dart';
import 'package:lombardspb/services/push_service.dart';
import 'package:lombardspb/screens/phone_verification_screen.dart';

// resolveDeviceId() дергает канал android_id — на хосте плагина нет, мокируем.
const _androidIdChannel = MethodChannel('android_id');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(
      _androidIdChannel,
      (call) async => call.method == 'getId' ? 'test-device-uuid' : null,
    );
    PushService.resetForTest();
    AppLog.resetForTest();
    AppLog.httpClient = MockClient((_) async => http.Response('{}', 200));
  });

  tearDown(() => messenger.setMockMethodCallHandler(_androidIdChannel, null));

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

  testWidgets('локально привязан → сразу «подключены», без формы', (tester) async {
    SharedPreferences.setMockInitialValues({
      'phone_verified': true,
      'verified_user_id': 'u-1',
      'verified_phone': '+79991234567',
    });
    PushService.httpClient = MockClient((_) async => http.Response('{}', 200));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('подключены'), findsOneWidget);
    expect(find.text('Введите номер телефона:'), findsNothing);
    // полный номер показывается без маски
    expect(find.textContaining('зарегистрирован номер +7 (999) 123-45-67'), findsOneWidget);
    expect(find.text('Отписаться от персональных пушей'), findsOneWidget);
  });

  testWidgets('локально НЕ привязан, сервер bound:true + phone → полный номер с сервера', (tester) async {
    SharedPreferences.setMockInitialValues({});
    PushService.httpClient = MockClient((r) async {
      if (r.url.path.contains('bind-status')) {
        return http.Response(
          '{"bound":true,"user_id":"srv-u","phone":"+79995550095","phone_mask":"+7xxx95"}',
          200,
        );
      }
      return http.Response('{}', 200);
    });

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('подключены'), findsOneWidget);
    expect(find.textContaining('зарегистрирован номер +7 (999) 555-00-95'), findsOneWidget);
  });

  testWidgets('локально НЕ привязан, сервер bound:true только с маской → показывает маску', (tester) async {
    SharedPreferences.setMockInitialValues({});
    PushService.httpClient = MockClient((r) async {
      if (r.url.path.contains('bind-status')) {
        return http.Response('{"bound":true,"user_id":"srv-u","phone_mask":"+7xxx95"}', 200);
      }
      return http.Response('{}', 200);
    });

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('подключены'), findsOneWidget);
    expect(find.textContaining('зарегистрирован номер +7xxx95'), findsOneWidget);
  });

  testWidgets('локально НЕ привязан, сервер bound:true но user_id пуст (пуши без привязки) → форма ввода', (tester) async {
    SharedPreferences.setMockInitialValues({});
    PushService.httpClient = MockClient((r) async {
      if (r.url.path.contains('bind-status')) {
        return http.Response('{"bound":true,"user_id":"","push_enabled":false}', 200);
      }
      return http.Response('{}', 200);
    });

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('Введите номер телефона:'), findsOneWidget);
    expect(find.textContaining('подключены'), findsNothing);
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
    expect(find.textContaining('подключены'), findsNothing);
  });

  testWidgets('заголовок AppBar — короткий, без обрезки', (tester) async {
    SharedPreferences.setMockInitialValues({'phone_verified': true});
    PushService.httpClient = MockClient((_) async => http.Response('{}', 200));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('Уведомления'), findsOneWidget);
  });
}
