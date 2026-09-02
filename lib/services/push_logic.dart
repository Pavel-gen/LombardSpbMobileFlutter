import '../models/push_item.dart';

/// Чистые (без Flutter/сети/диска) решающие функции push-подсистемы.
/// Вынесены отдельно, чтобы покрыть быстрыми unit-тестами (`dart test`) и не
/// дублировать логику между push_storage / app_log / push_service.

/// Событие-«ошибка», которое нельзя откладывать до пачки — `AppLog` выгружает
/// его на сервер немедленно.
bool appLogIsUrgent(String name) =>
    name.contains('error') || name.endsWith('_fail') || name == 'token_giveup';

/// Служебный пуш `token_refresh` (от `push-refresh-ping.php`): приложение его
/// не показывает и не пишет в историю — только перерегистрирует токен.
bool isTokenRefreshPing(Map<String, dynamic> data) => data['type'] == 'token_refresh';

/// `created_at` из ответа `inbox.php` (`YYYY-MM-DD HH:MM:SS`) → epoch ms.
/// Строка без суффикса таймзоны трактуется как локальное время устройства
/// (сервер пишет её по МСК, приложение используется в том же поясе). Строка с
/// `Z`/смещением — по нему. Пусто / не распарсилось → `now`.
int parseInboxCreatedAt(String? createdAt, [DateTime? now]) {
  if (createdAt != null && createdAt.isNotEmpty) {
    final d = DateTime.tryParse(createdAt.replaceFirst(' ', 'T'));
    if (d != null) return d.millisecondsSinceEpoch;
  }
  return (now ?? DateTime.now()).millisecondsSinceEpoch;
}

/// true — пуш с таким `msgId` уже в списке (дедуп). Пустой `msgId` дублем не
/// считается (у старых записей его нет).
bool pushListContainsMsgId(List<PushItem> list, String msgId) =>
    msgId.isNotEmpty && list.any((e) => e.msgId == msgId);

/// Вставляет `item`, сортирует по времени (новые сверху), обрезает до
/// `maxItems`. Возвращает НОВЫЙ список, исходный не меняет.
List<PushItem> pushListInsertSorted(List<PushItem> list, PushItem item, int maxItems) {
  final out = [...list, item]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  if (out.length > maxItems) out.removeRange(maxItems, out.length);
  return out;
}

/// Тело запроса, которое приложение шлёт в `app-log.php`. Вынесено ради теста
/// формы полезной нагрузки.
Map<String, dynamic> buildAppLogPayload({
  required String installId,
  required String sessionId,
  required String appVersion,
  required String deviceUuid,
  required List<dynamic> events,
}) => {
      'install_id': installId,
      'session_id': sessionId,
      'app_version': appVersion,
      'device_uuid': deviceUuid,
      'app_source': 'flutter',
      'events': events,
    };
