# Push-уведомления: что должен делать бэкенд

Клиент (Flutter-приложение) уже шлёт всё необходимое. Ниже — что нужно
поддержать на стороне `lombard.center/api`, чтобы закрыть пункты 3 и 4.

---

## 1. `POST /api/fcm-token.php` — регистрация токена (уже есть, расширено)

Тело запроса теперь содержит **`user_id`** и `app_source`:

```json
{
  "token": "<FCM token>",
  "user_id": "<из привязки номера, может быть пустым>",
  "platform": "android-14",
  "device_model": "Xiaomi 23021RAA2Y",
  "app_version": "1.0.0",
  "os_version": "14",
  "device_uuid": "<ANDROID_ID / identifierForVendor>",
  "app_source": "flutter"
}
```

Сервер должен: upsert по `token` (или по паре `device_uuid` + `platform`),
сохранять `user_id` и `updated_at = now()`. `user_id` нужен, чтобы при
удалении приложения (см. п. 3) можно было вызвать 1С `setpush(operation=0)`.

### `POST /api/fcm-token.php?action=delete` — явная отписка

Клиент вызывает это, когда пользователь сам отключает уведомления
(`PushService.unregisterToken`). Тело:

```json
{ "token": "...", "user_id": "...", "device_uuid": "...", "reason": "user_disconnect", "app_source": "flutter" }
```

Сервер: удалить строку токена; если `user_id` не пустой — вызвать
1С `setpush(operation=0)` для него.

---

## 2. Пункт 3 — «приложение удалили → снять получение пушей в 1С»

**Важно:** при удалении приложения на устройстве **не выполняется никакой код**
(ни Android, ни iOS). Поэтому «отправить запрос при удалении» технически
невозможно со стороны клиента. Единственный надёжный способ — серверный,
через ответ FCM при рассылке:

1. При каждой отправке пуша серверу приходит ответ по каждому токену.
   Токены удалённых приложений возвращают:
   - HTTP v1 API: `UNREGISTERED` (`404`) или `INVALID_ARGUMENT` (`400`) с
     `errorCode: "UNREGISTERED"`;
   - legacy API: `"error": "NotRegistered"` или `"InvalidRegistration"`.
2. Получив такой ответ для токена:
   - удалить токен из своей БД;
   - если у токена был `user_id` — вызвать 1С `setpush(operation=0)` для него
     (тот же вызов, что делает кнопка «Отключить» в приложении).
3. Дополнительно (необязательно, но полезно) раз в N дней прогонять все
   токены через «dry run» отправку и чистить мёртвые так же.

Клиент со своей стороны помогает максимально:
- шлёт `user_id` вместе с токеном — серверу есть кого отвязывать;
- при `onTokenRefresh` присылает новый токен (старый после этого можно
  считать мёртвым и удалять);
- при явном отключении вызывает `?action=delete` и `deleteToken()`.

---

## 3. Пункт 4 — почему на части устройств не генерируется FCM-токен

### `POST /api/fcm-log.php` — приёмник диагностики (нужно создать)

Клиент шлёт сюда JSON на **каждой неудачной попытке** получить токен и один
раз при «выздоровлении» (`note: "recovered"`). Достаточно писать тело в
таблицу/файл как есть. Пример полезной нагрузки:

```json
{
  "stage": "fcm_token",
  "attempt": 2,
  "ts": "2026-08-31T09:12:44.001Z",
  "app_source": "flutter",
  "device_uuid": "…",
  "app_version": "1.0.0",
  "build_number": "1",
  "platform": "android",
  "os_version": "13",
  "sdk_int": 33,
  "device_model": "HUAWEI STK-L21",
  "brand": "HUAWEI",
  "is_physical_device": true,
  "supported_abis": ["arm64-v8a"],
  "google_system_features": [],
  "authorization_status": "authorized",
  "auto_init_enabled": true,
  "error_type": "FirebaseException",
  "error": "[firebase_messaging/unknown] SERVICE_NOT_AVAILABLE",
  "error_code": "unknown",
  "error_plugin": "firebase_messaging",
  "error_message": "SERVICE_NOT_AVAILABLE"
}
```

### Как читать логи

- `error_message: "SERVICE_NOT_AVAILABLE"` / `AUTHENTICATION_FAILED` /
  `MISSING_INSTANCEID_SERVICE`, `google_system_features` пустой,
  `brand: HUAWEI` — **на устройстве нет/сломан Google Play Services**.
  Лечится только на устройстве (обновить GMS, вход в Google-аккаунт).
  Для таких устройств пуши FCM в принципе недоступны.
- `platform: ios`, `apns_token_error` заполнен / `apns_token_present: false` —
  не выдаётся APNS-токен: нет прав на уведомления, не настроен APNS-ключ в
  Firebase, либо сборка без push-entitlement.
- `authorization_status: "denied"` — пользователь запретил уведомления;
  токен на Android всё равно должен выдаваться, на iOS — нет.
- Ошибок нет, но `attempt` доходит до 5 — таймауты сети; обычно
  «вылечивается» само на `note: "recovered"` при следующем запуске.

### Что уже усилено в клиенте (`lib/services/push_service.dart`)

- `setAutoInitEnabled(true)` перед запросом токена;
- получение токена вынесено из старта приложения в фон (старт не блокируется);
- до 6 попыток с нарастающими паузами (3с → 10с → 30с → 90с → 4мин);
- на iOS перед `getToken()` дожидаемся APNS-токена;
- повторная попытка при каждом возврате приложения на передний план, пока
  токена нет;
- каждая неудача логируется локально (`[PushService]` в logcat/flutter logs)
  и уходит на `fcm-log.php`.

---

## 4. Подтверждение доставки пуша (push-ack) — сделано в клиенте 2026-09-01

Клиент (`lib/services/push_service.dart`) уже:
- шлёт `"push_ack": true` в `POST /api/fcm-token.php`;
- читает `data.msg_id` из входящего пуша;
- на приём сообщения (foreground / headless background / тап по уведомлению)
  один раз шлёт `POST /api/push-ack.php {"msg_id": "...", "source": "..."}`,
  fire-and-forget, дедуп по `msg_id` в SharedPreferences (ключ `acked_msg_ids`).

### Что нужно на бэкенде

1. `fcm-token.php` — принимать поле `push_ack` (bool), сохранять в `fcm_tokens`
   (например колонка `push_ack TINYINT(1) DEFAULT 0`). По нему reconcile
   понимает, ждать ли ack от этого устройства.
2. В payload рассылки (`fcm.php` / `1c_push_worker.php`) добавить в `data`:
   `msg_id` (уникальный id доставки на пару токен+рассылка) и, по желанию,
   `id_send`. Хранить отправленные: `msg_id, token_id, user_id, id_send,
   sent_at, acked_at NULL`.
3. `push-ack.php` (новый) — принимает `{msg_id, source}`, проставляет
   `acked_at = NOW()` по `msg_id`. Без авторизации, всегда `{"status":"ok"}`,
   повторный ack игнорировать.
4. `push-reconcile.php` (новый, крон раз в минуту) — по записям, где
   `acked_at IS NULL AND sent_at < NOW() - INTERVAL 5 MINUTE` и устройство
   с `push_ack=1`: считать «не доставлено» → запустить SMS-подстраховку,
   пометить запись обработанной.
