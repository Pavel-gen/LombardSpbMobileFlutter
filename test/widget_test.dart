// Смоук-тест запуска приложения: LombardApp строится, лендинг рендерится.
// connectivity_plus мокируется на уровне каналов (на хосте плагина нет).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lombardspb/main.dart';

const _connMethod = MethodChannel('dev.fluttercommunity.plus/connectivity');
const _connEvent = EventChannel('dev.fluttercommunity.plus/connectivity_status');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(_connMethod, (call) async {
      // connectivity_plus 6.x: check → invokeListMethod, ждёт List, не String.
      if (call.method == 'check') return <String>['wifi'];
      return null;
    });
    messenger.setMockStreamHandler(
      _connEvent,
      MockStreamHandler.inline(onListen: (args, sink) => sink.success(<String>['wifi'])),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_connMethod, null);
    messenger.setMockStreamHandler(_connEvent, null);
  });

  testWidgets('LombardApp поднимается и показывает MaterialApp', (tester) async {
    await tester.pumpWidget(const LombardApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
