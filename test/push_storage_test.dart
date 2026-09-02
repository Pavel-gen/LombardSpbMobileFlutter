// Локальная история пушей + дедуп. `flutter test` (нужен SharedPreferences mock).
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lombardspb/services/push_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('addPush сохраняет запись и возвращает непустой id', () async {
    final id = await PushStorage.addPush(title: 'T', body: 'B', link: 'L', msgId: 'm1');
    expect(id, isNotEmpty);
    final all = await PushStorage.getAll();
    expect(all, hasLength(1));
    expect(all.single.msgId, 'm1');
    expect(all.single.read, isFalse);
  });

  test('повторный msg_id → "" и без дубля в истории', () async {
    await PushStorage.addPush(title: 'A', body: '', link: 'l', msgId: 'dup');
    final again = await PushStorage.addPush(title: 'A2', body: '', link: 'l', msgId: 'dup');
    expect(again, isEmpty);
    expect(await PushStorage.getAll(), hasLength(1));
  });

  test('пустой msg_id не считается дублем', () async {
    await PushStorage.addPush(title: 'a', body: '', link: 'l');
    await PushStorage.addPush(title: 'b', body: '', link: 'l');
    expect(await PushStorage.getAll(), hasLength(2));
  });

  test('сортировка: свежая запись сверху', () async {
    await PushStorage.addPush(title: 'old', body: '', link: 'l', msgId: 'o', timestampMs: 1000);
    await PushStorage.addPush(title: 'new', body: '', link: 'l', msgId: 'n', timestampMs: 9000);
    await PushStorage.addPush(title: 'mid', body: '', link: 'l', msgId: 'm', timestampMs: 5000);
    final titles = (await PushStorage.getAll()).map((e) => e.title).toList();
    expect(titles, ['new', 'mid', 'old']);
  });

  test('история обрезается до 200, старые выкидываются', () async {
    for (var i = 0; i < 215; i++) {
      await PushStorage.addPush(title: 't$i', body: '', link: 'l', msgId: 'm$i', timestampMs: i);
    }
    final all = await PushStorage.getAll();
    expect(all, hasLength(200));
    expect(all.any((e) => e.title == 't0'), isFalse);
    expect(all.first.title, 't214');
  });

  test('markRead помечает прочитанным, hasUnread реагирует', () async {
    final id = await PushStorage.addPush(title: 'T', body: '', link: 'l', msgId: 'r1');
    expect(await PushStorage.hasUnread(), isTrue);
    await PushStorage.markRead(id);
    expect(await PushStorage.hasUnread(), isFalse);
    expect((await PushStorage.getAll()).single.read, isTrue);
  });

  test('markRead с пустым/несуществующим id не падает', () async {
    await PushStorage.markRead(null);
    await PushStorage.markRead('');
    await PushStorage.markRead('нет-такого');
  });

  test('битый JSON в хранилище → getAll возвращает []', () async {
    SharedPreferences.setMockInitialValues({'items': 'не-json'});
    expect(await PushStorage.getAll(), isEmpty);
  });

  test('clear очищает историю', () async {
    await PushStorage.addPush(title: 'T', body: '', link: 'l', msgId: 'c1');
    await PushStorage.clear();
    expect(await PushStorage.getAll(), isEmpty);
  });
}
