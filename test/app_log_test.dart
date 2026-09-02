// Журнал AppLog: буферизация, триггеры выгрузки, поведение на ошибках сервера.
// `flutter test` (SharedPreferences mock + MockClient).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lombardspb/services/app_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> sent;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLog.resetForTest();
    sent = [];
  });

  MockClient ok() => MockClient((req) async {
        sent.add(req);
        return http.Response('{"status":"ok"}', 200);
      });
  MockClient fail() => MockClient((req) async {
        sent.add(req);
        return http.Response('err', 500);
      });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('event кладёт строку в кольцевой буфер', () async {
    AppLog.httpClient = ok();
    await AppLog.event('token_ok', {'attempt': 1});
    final p = await SharedPreferences.getInstance();
    expect(p.getStringList('app_log_buffer'), hasLength(1));
  });

  test('обычных событий < 40 → выгрузки нет', () async {
    AppLog.httpClient = ok();
    for (var i = 0; i < 39; i++) {
      await AppLog.event('net', {'i': i});
    }
    await settle();
    expect(sent, isEmpty);
  });

  test('40-е обычное событие → выгрузка', () async {
    AppLog.httpClient = ok();
    for (var i = 0; i < 40; i++) {
      await AppLog.event('net', {'i': i});
    }
    await settle();
    expect(sent, isNotEmpty);
  });

  test('событие-ошибка выгружается немедленно, тело правильной формы', () async {
    AppLog.httpClient = ok();
    await AppLog.event('flutter_error', {'msg': 'boom'});
    await settle();
    expect(sent, hasLength(1));
    final body = jsonDecode(sent.first.body) as Map<String, dynamic>;
    expect(body['app_source'], 'flutter');
    expect(body['install_id'], isNotEmpty);
    expect(body['events'], isA<List<dynamic>>());
    expect((body['events'] as List).first['e'], anything);
  });

  test('успешная выгрузка (2xx) очищает буфер и ставит last_flush', () async {
    AppLog.httpClient = ok();
    await AppLog.event('flutter_error', {'x': 1});
    await settle();
    final p = await SharedPreferences.getInstance();
    expect(p.getStringList('app_log_buffer') ?? const [], isEmpty);
    expect(p.getInt('app_log_last_flush_ms'), isNotNull);
  });

  test('ошибка сервера (500) — буфер сохраняется для повторной попытки', () async {
    AppLog.httpClient = fail();
    await AppLog.event('flutter_error', {'x': 1});
    await settle();
    final p = await SharedPreferences.getInstance();
    expect((p.getStringList('app_log_buffer') ?? const []).length, greaterThan(0));
    expect(p.getInt('app_log_last_flush_ms'), isNull);
  });

  test('буфер не растёт бесконечно (кольцо ≤ 600)', () async {
    AppLog.httpClient = fail(); // выгрузка не удаётся — буфер копится
    for (var i = 0; i < 700; i++) {
      await AppLog.event('net', {'i': i});
    }
    await settle();
    final p = await SharedPreferences.getInstance();
    expect((p.getStringList('app_log_buffer') ?? const []).length, lessThanOrEqualTo(600));
  });

  test('flush(force:false) в пределах интервала — no-op', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'app_log_buffer': ['{"t":"x","e":"net"}'],
      'app_log_last_flush_ms': now, // только что флашили
    });
    AppLog.httpClient = ok();
    await AppLog.flush(); // не force
    await settle();
    expect(sent, isEmpty);
  });
}
