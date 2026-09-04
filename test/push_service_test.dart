// PushService: серверный ящик (inbox), сверка привязки, ack, обработка пуша.
// `flutter test` (SharedPreferences mock + MockClient вместо сети).
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lombardspb/services/app_log.dart';
import 'package:lombardspb/services/push_service.dart';
import 'package:lombardspb/services/push_storage.dart';

// resolveDeviceId() дергает канал android_id — на хосте плагина нет, мокируем.
const _androidIdChannel = MethodChannel('android_id');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(
      _androidIdChannel,
      (call) async => call.method == 'getId' ? 'test-device-uuid' : null,
    );
    PushService.resetForTest();
    AppLog.resetForTest();
    AppLog.httpClient = MockClient((_) async => http.Response('{}', 200));
  });

  tearDown(() => messenger.setMockMethodCallHandler(_androidIdChannel, null));

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  group('syncInbox', () {
    test('без verified_user_id сетевого запроса нет', () async {
      var called = false;
      PushService.httpClient = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });
      await PushService.syncInbox();
      expect(called, isFalse);
    });

    test('забирает пропущенные, кладёт в историю, двигает inbox_last_id, шлёт POST-back', () async {
      SharedPreferences.setMockInitialValues({'verified_user_id': 'user-1'});
      final reqs = <http.BaseRequest>[];
      PushService.httpClient = MockClient((r) async {
        reqs.add(r);
        if (r.method == 'GET') {
          return http.Response(
            jsonEncode({
              'items': [
                {'id': 10, 'msg_id': 'm10', 'title': 'A', 'body': 'a', 'link': 'https://lombard.center/', 'created_at': '2026-08-31 10:00:00'},
                {'id': 11, 'msg_id': 'm11', 'title': 'B', 'body': 'b', 'link': 'https://lombard.center/', 'created_at': '2026-08-31 11:00:00'},
              ],
              'last_id': 11,
            }),
            200,
          );
        }
        return http.Response('{"status":"ok"}', 200);
      });

      await PushService.syncInbox();
      await settle();

      final hist = await PushStorage.getAll();
      expect(hist.map((e) => e.msgId), containsAll(<String>['m10', 'm11']));
      final p = await SharedPreferences.getInstance();
      expect(p.getInt('inbox_last_id'), 11);
      expect(reqs.any((r) => r.method == 'POST'), isTrue);

      final get = reqs.firstWhere((r) => r.method == 'GET');
      expect(get.url.queryParameters['user_id'], 'user-1');
      expect(get.url.queryParameters['since_id'], '0');
    });

    test('повторный вызов подставляет since_id из префов', () async {
      SharedPreferences.setMockInitialValues({'verified_user_id': 'u', 'inbox_last_id': 42});
      String? since;
      PushService.httpClient = MockClient((r) async {
        if (r.method == 'GET') since = r.url.queryParameters['since_id'];
        return http.Response(jsonEncode({'items': <dynamic>[], 'last_id': 42}), 200);
      });
      await PushService.syncInbox();
      expect(since, '42');
    });

    test('item с уже известным msg_id в историю не дублируется', () async {
      SharedPreferences.setMockInitialValues({'verified_user_id': 'u'});
      await PushStorage.addPush(title: 'локальный', body: '', link: 'l', msgId: 'm10');
      PushService.httpClient = MockClient((r) async {
        if (r.method == 'GET') {
          return http.Response(
            jsonEncode({
              'items': [
                {'id': 10, 'msg_id': 'm10', 'title': 'из ящика', 'body': '', 'link': 'l', 'created_at': '2026-08-31 10:00:00'},
              ],
              'last_id': 10,
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      await PushService.syncInbox();
      final hist = await PushStorage.getAll();
      expect(hist.where((e) => e.msgId == 'm10'), hasLength(1));
      expect(hist.single.title, 'локальный');
    });

    test('HTTP 500 от inbox.php не роняет и не двигает last_id', () async {
      SharedPreferences.setMockInitialValues({'verified_user_id': 'u'});
      PushService.httpClient = MockClient((_) async => http.Response('err', 500));
      await PushService.syncInbox();
      final p = await SharedPreferences.getInstance();
      expect(p.getInt('inbox_last_id'), isNull);
    });
  });

  group('reconcileBindState', () {
    test('сервер bound:true, локально не привязан → выставляет phone_verified, номер, маску, и возвращает true', () async {
      PushService.httpClient = MockClient((_) async => http.Response(
            jsonEncode({
              'bound': true,
              'push_enabled': true,
              'user_id': 'srv-user',
              'phone': '+79995550095',
              'phone_mask': '+7xxx95',
            }),
            200,
          ));
      final restored = await PushService.reconcileBindState();
      expect(restored, isTrue);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('phone_verified'), isTrue);
      expect(p.getString('verified_user_id'), 'srv-user');
      expect(p.getString('verified_phone'), '+79995550095');
      expect(p.getString('verified_phone_mask'), '+7xxx95');
    });

    test('сервер bound:true, но локально уже привязан → маску обновляет, возвращает false', () async {
      SharedPreferences.setMockInitialValues({'phone_verified': true, 'verified_user_id': 'keep'});
      PushService.httpClient = MockClient((_) async => http.Response(
            jsonEncode({'bound': true, 'user_id': 'keep', 'phone_mask': '+7xxx42'}),
            200,
          ));
      final restored = await PushService.reconcileBindState();
      expect(restored, isFalse);
      final p = await SharedPreferences.getInstance();
      expect(p.getString('verified_phone_mask'), '+7xxx42');
    });

    test('сервер bound:true, но user_id пуст (пуши без привязки) → НЕ включает, возвращает false', () async {
      PushService.httpClient = MockClient((_) async => http.Response(
            jsonEncode({'bound': true, 'user_id': '', 'push_enabled': false}),
            200,
          ));
      final restored = await PushService.reconcileBindState();
      expect(restored, isFalse);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('phone_verified'), isNot(isTrue));
      expect(p.getString('verified_user_id'), isNull);
    });

    test('сервер bound:false НЕ снимает уже стоящий флаг, возвращает false', () async {
      SharedPreferences.setMockInitialValues({'phone_verified': true, 'verified_user_id': 'keep'});
      PushService.httpClient = MockClient((_) async => http.Response(jsonEncode({'bound': false}), 200));
      final restored = await PushService.reconcileBindState();
      expect(restored, isFalse);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('phone_verified'), isTrue);
      expect(p.getString('verified_user_id'), 'keep');
    });

    test('ошибка сервера (500) ничего не ломает', () async {
      SharedPreferences.setMockInitialValues({'phone_verified': true});
      PushService.httpClient = MockClient((_) async => http.Response('err', 500));
      await PushService.reconcileBindState();
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('phone_verified'), isTrue);
    });
  });

  group('ack', () {
    test('пустой msg_id → запроса нет', () async {
      var called = false;
      PushService.httpClient = MockClient((_) async {
        called = true;
        return http.Response('', 200);
      });
      await PushService.debugSendAck('', 'test');
      expect(called, isFalse);
    });

    test('msg_id → ровно один POST, повторный вызов не шлёт', () async {
      var count = 0;
      PushService.httpClient = MockClient((_) async {
        count++;
        return http.Response('{"status":"ok"}', 200);
      });
      await PushService.debugSendAck('msg-1', 'foreground');
      await PushService.debugSendAck('msg-1', 'foreground');
      expect(count, 1);
    });

    test('POST не прошёл → ack остаётся в очереди и уходит при следующем flushPendingAcks', () async {
      var ok = false;
      var posts = 0;
      PushService.httpClient = MockClient((_) async {
        posts++;
        return ok ? http.Response('{"status":"ok"}', 200) : http.Response('down', 503);
      });

      await PushService.debugSendAck('msg-x', 'background'); // 503 → в очередь
      final p = await SharedPreferences.getInstance();
      expect(p.getStringList('pending_acks'), isNotEmpty);
      expect(p.getStringList('acked_msg_ids') ?? const [], isNot(contains('msg-x')));

      ok = true;
      await PushService.flushPendingAcks(); // сеть вернулась
      expect(p.getStringList('pending_acks'), isEmpty);
      expect(p.getStringList('acked_msg_ids'), contains('msg-x'));

      final before = posts;
      await PushService.flushPendingAcks(); // больше не шлём
      expect(posts, before);
    });
  });

  group('обработка входящего пуша (debugHandleData)', () {
    test('обычный пуш → в историю + ушёл ack', () async {
      final hits = <String>[];
      PushService.httpClient = MockClient((r) async {
        hits.add('${r.method} ${r.url.path}');
        return http.Response('{"status":"ok"}', 200);
      });
      await PushService.debugHandleData({
        'title': 'Привет',
        'body': 'текст',
        'link': 'https://lombard.center/',
        'msg_id': 'p1',
      }, source: 'foreground');
      await settle();

      final hist = await PushStorage.getAll();
      expect(hist.single.msgId, 'p1');
      expect(hist.single.title, 'Привет');
      expect(hits.any((s) => s.contains('push-ack')), isTrue);
    });

    test('тот же msg_id второй раз — в историю не попадает', () async {
      PushService.httpClient = MockClient((_) async => http.Response('{"status":"ok"}', 200));
      await PushService.debugHandleData({'title': 'A', 'body': '', 'link': 'l', 'msg_id': 'p2'});
      await PushService.debugHandleData({'title': 'A', 'body': '', 'link': 'l', 'msg_id': 'p2'});
      await settle();
      final hist = await PushStorage.getAll();
      expect(hist.where((e) => e.msgId == 'p2'), hasLength(1));
    });
  });
}
