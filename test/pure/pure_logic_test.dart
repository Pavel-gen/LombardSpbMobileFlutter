// Быстрые unit-тесты чистой логики push-подсистемы. Не зависят от Flutter —
// запускаются через `dart test test/pure` (в т.ч. в CI без движка Flutter).
//
// Полный набор (виджеты, SharedPreferences, HTTP-моки) — во flutter-тестах
// уровнем выше: `flutter test`.
import 'package:test/test.dart';

import 'package:lombardspb/models/push_item.dart';
import 'package:lombardspb/services/push_logic.dart';

PushItem _item({String id = 'x', String msgId = '', int ts = 0}) => PushItem(
      id: id,
      title: 't',
      body: 'b',
      link: 'https://lombard.center/',
      timestamp: ts,
      read: false,
      msgId: msgId,
    );

void main() {
  group('appLogIsUrgent', () {
    test('срочно для ошибок и *_fail и token_giveup', () {
      expect(appLogIsUrgent('flutter_error'), isTrue);
      expect(appLogIsUrgent('platform_error'), isTrue);
      expect(appLogIsUrgent('zone_error'), isTrue);
      expect(appLogIsUrgent('push_init_fail'), isTrue);
      expect(appLogIsUrgent('token_send_fail'), isTrue);
      expect(appLogIsUrgent('token_giveup'), isTrue);
    });
    test('не срочно для обычных событий', () {
      for (final n in ['app_start', 'token_ok', 'push_received', 'inbox_sync',
          'lifecycle_resumed', 'bind_status', 'net']) {
        expect(appLogIsUrgent(n), isFalse, reason: n);
      }
    });
  });

  group('isTokenRefreshPing', () {
    test('ловит служебный пуш', () {
      expect(isTokenRefreshPing({'type': 'token_refresh'}), isTrue);
    });
    test('обычный пуш — не служебный', () {
      expect(isTokenRefreshPing({'title': 'Привет', 'msg_id': 'a1'}), isFalse);
      expect(isTokenRefreshPing({}), isFalse);
      expect(isTokenRefreshPing({'type': 'other'}), isFalse);
    });
  });

  group('parseInboxCreatedAt', () {
    final now = DateTime.utc(2026, 1, 1);
    test('строка без таймзоны → локальное время устройства', () {
      final ms = parseInboxCreatedAt('2026-08-31 12:34:56', now);
      expect(ms, DateTime.parse('2026-08-31T12:34:56').millisecondsSinceEpoch);
      expect(ms, isNot(now.millisecondsSinceEpoch)); // не свалилось в fallback
    });
    test('ISO с Z трактуется как UTC', () {
      final ms = parseInboxCreatedAt('2026-08-31T12:34:56Z', now);
      expect(ms, DateTime.utc(2026, 8, 31, 12, 34, 56).millisecondsSinceEpoch);
    });
    test('пусто / null / мусор → now', () {
      expect(parseInboxCreatedAt(null, now), now.millisecondsSinceEpoch);
      expect(parseInboxCreatedAt('', now), now.millisecondsSinceEpoch);
      expect(parseInboxCreatedAt('не дата', now), now.millisecondsSinceEpoch);
    });
  });

  group('pushListContainsMsgId', () {
    final list = [_item(id: '1', msgId: 'aaa'), _item(id: '2', msgId: 'bbb')];
    test('находит существующий msg_id', () {
      expect(pushListContainsMsgId(list, 'bbb'), isTrue);
    });
    test('нет такого msg_id', () {
      expect(pushListContainsMsgId(list, 'ccc'), isFalse);
    });
    test('пустой msg_id никогда не дубль', () {
      expect(pushListContainsMsgId(list, ''), isFalse);
      expect(pushListContainsMsgId([_item(id: '3')], ''), isFalse);
    });
  });

  group('pushListInsertSorted', () {
    test('сортирует по времени: новые сверху', () {
      final base = [_item(id: 'old', ts: 100), _item(id: 'new', ts: 300)];
      final out = pushListInsertSorted(base, _item(id: 'mid', ts: 200), 200);
      expect(out.map((e) => e.id).toList(), ['new', 'mid', 'old']);
    });
    test('обрезает до maxItems, выкидывая самые старые', () {
      final base = List.generate(5, (i) => _item(id: 'i$i', ts: i * 10));
      final out = pushListInsertSorted(base, _item(id: 'top', ts: 999), 3);
      expect(out.length, 3);
      expect(out.first.id, 'top');
      expect(out.map((e) => e.id), isNot(contains('i0')));
    });
    test('исходный список не мутируется', () {
      final base = [_item(id: 'a', ts: 1)];
      pushListInsertSorted(base, _item(id: 'b', ts: 2), 200);
      expect(base.length, 1);
    });
  });

  group('buildAppLogPayload', () {
    test('форма тела для app-log.php', () {
      final p = buildAppLogPayload(
        installId: 'inst',
        sessionId: 'sess',
        appVersion: '1.2.3',
        deviceUuid: 'dev',
        events: [
          {'t': '2026-01-01T00:00:00Z', 'e': 'app_start'},
        ],
      );
      expect(p['install_id'], 'inst');
      expect(p['session_id'], 'sess');
      expect(p['app_version'], '1.2.3');
      expect(p['device_uuid'], 'dev');
      expect(p['app_source'], 'flutter');
      expect(p['events'], hasLength(1));
    });
  });
}
