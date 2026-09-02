// Модель PushItem — чистый Dart, `dart test test/pure`.
import 'package:test/test.dart';

import 'package:lombardspb/models/push_item.dart';

void main() {
  group('PushItem.toJson / fromJson', () {
    test('roundtrip сохраняет все поля', () {
      const src = PushItem(
        id: 'id-1',
        title: 'Заголовок',
        body: 'Тело со ссылкой https://lombard.center/x',
        link: 'https://lombard.center/x',
        timestamp: 1735689600000,
        read: true,
        msgId: 'abcdef0123456789',
      );
      final back = PushItem.fromJson(src.toJson());
      expect(back.id, src.id);
      expect(back.title, src.title);
      expect(back.body, src.body);
      expect(back.link, src.link);
      expect(back.timestamp, src.timestamp);
      expect(back.read, src.read);
      expect(back.msgId, src.msgId);
    });

    test('пустой msgId в JSON не пишется (совместимость со старыми записями)', () {
      const src = PushItem(
        id: 'id-2', title: 't', body: 'b', link: 'l', timestamp: 0, read: false,
      );
      expect(src.toJson().containsKey('msg_id'), isFalse);
    });

    test('fromJson переживает отсутствующие/битые поля', () {
      final back = PushItem.fromJson({'id': 'only-id'});
      expect(back.id, 'only-id');
      expect(back.title, '');
      expect(back.body, '');
      expect(back.timestamp, 0);
      expect(back.read, isFalse);
      expect(back.msgId, '');
    });
  });

  group('PushItem.copyWith', () {
    test('меняет read, остальное (в т.ч. msgId) сохраняет', () {
      const src = PushItem(
        id: 'id', title: 't', body: 'b', link: 'l',
        timestamp: 123, read: false, msgId: 'm1',
      );
      final r = src.copyWith(read: true);
      expect(r.read, isTrue);
      expect(r.id, 'id');
      expect(r.timestamp, 123);
      expect(r.msgId, 'm1');
    });
  });
}
