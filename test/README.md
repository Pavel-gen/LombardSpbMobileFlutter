# Тесты приложения

Запуск всего разом: `.\run_tests.ps1` (из корня проекта).

## Два движка

| Команда | Что гоняет | Где работает |
|---|---|---|
| `dart test test/pure` | чистая логика без Flutter (`test/pure/**`) | **везде**, в т.ч. CI без движка Flutter |
| `flutter test` | всё остальное (`test/*.dart`) — SharedPreferences, HTTP-моки, виджеты | машина разработчика, CI с Flutter |

> В некоторых песочницах `flutter test` не стартует: его служебный
> WebSocket-listener получает HTTP 403 («Connection closed before test suite
> loaded»). Это ограничение окружения, не код. `flutter analyze` при этом
> проходит, и на обычной машине `flutter test` работает.

## Что покрыто

### `test/pure/` — чистые unit-тесты (`dart test`)
| Файл | Покрывает |
|---|---|
| `pure_logic_test.dart` | `appLogIsUrgent` (какие события выгружать сразу), `isTokenRefreshPing` (распознавание тихого пуша), `parseInboxCreatedAt` (разбор времени из inbox.php), дедуп и сортировка истории (`pushListContainsMsgId`, `pushListInsertSorted`), форма тела `app-log.php` |
| `push_item_test.dart` | `PushItem` — toJson/fromJson roundtrip, пустой `msg_id` не пишется, устойчивость к битому JSON, `copyWith` |

### `test/` — Flutter-тесты (`flutter test`)
| Файл | Покрывает |
|---|---|
| `push_storage_test.dart` | история пушей: возврат id, дедуп по `msg_id` (повтор → `''`), сортировка по времени, обрезка до 200, `markRead`/`hasUnread`, битый JSON → `[]`, `clear` |
| `app_log_test.dart` | буфер: запись, кольцо ≤ 600; триггеры выгрузки: < 40 обычных — молчим, 40-е — flush, событие-ошибка — сразу; на 2xx буфер чистится и ставится `last_flush`; на 500 буфер сохраняется; `flush(force:false)` внутри интервала — no-op; форма тела запроса |
| `push_service_test.dart` | `syncInbox`: без `verified_user_id` запроса нет; забор пропущенных → история + `inbox_last_id` + POST-back; `since_id` из префов; дедуп по `msg_id`; HTTP 500 не ломает. `reconcileBindState`: `bound:true` → выставляет `phone_verified`; `bound:false`/500 **не снимает** уже стоящий флаг. `ack`: пустой `msg_id` — тишина; один POST, повтор не шлётся. Входящий пуш: в историю + ушёл ack; дубль по `msg_id` не двоится |
| `phone_mask_formatter_test.dart` | маска `+7 (999) 123-45-67`: первая цифра, `8`→`+7`, вставка 10/11 цифр, промежуточные длины, отсечение сверх 11, полная очистка, курсор не улетает, идемпотентность |
| `phone_verification_screen_test.dart` | первый кадр — крутилка, а не форма (нет мигания); локально привязан → сразу «подключены» + номер + кнопка «Отписаться…»; локально нет, сервер `bound:true` → подключённое состояние + номер с сервера; сервер `bound:false` → форма ввода; короткий заголовок AppBar |
| `widget_test.dart` | смоук: `LombardApp` поднимается, рендерит `MaterialApp` (connectivity_plus замокан на уровне каналов) |

## Как это устроено (тестовые швы в коде)

Прод-поведение не изменено, добавлены только точки подмены:

- `AppLog.httpClient` / `PushService.httpClient` — `http.Client`, в тестах
  подменяется на `MockClient` из `package:http/testing.dart`.
- `AppLog.resetForTest()` / `PushService.resetForTest()` — сброс статического
  состояния между тестами.
- `PushService.debugHandleData(...)` / `debugSendAck(...)` — тест-обёртки над
  приватными обработчиками.
- Чистые решающие функции вынесены в `lib/services/push_logic.dart` (без
  зависимости от Flutter) — оттуда их берут и прод, и `dart test`.
- `_showLocalNotification` в `_handleMessage` обёрнут в try/catch: сбой показа
  уведомления не должен терять ack и запись в истории.

## Серверные тесты

В репозитории сервера (`lombard-server/tests/`):
- `run.php` — чистая логика (`fcmClassify`, `normalizePhone`, `req_hash`),
  без БД: `php tests/run.php`;
- `smoke.sh` — живые эндпоинты отвечают и в нужной форме (health, bind-status,
  inbox, app-log), ничего не меняет: `bash tests/smoke.sh`.
