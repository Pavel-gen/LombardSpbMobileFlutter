import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_api_availability/google_api_availability.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';
import '../utils/device_id.dart';
import 'app_log.dart';
import 'push_logic.dart';
import 'push_storage.dart';

const _channelId = 'twa_push_channel';
const _channelName = 'Уведомления приложения';

const _tokenEndpoint = 'https://lombard.center/api/fcm-token.php';

/// Куда шлём диагностику генерации FCM-токена. Серверный обработчик пишет тело
/// запроса в лог/таблицу — по нему видно, ПОЧЕМУ на конкретном устройстве
/// токен не сгенерировался (см. docs/PUSH_BACKEND.md).
const _diagEndpoint = 'https://lombard.center/api/fcm-log.php';

/// Подтверждение доставки пуша: приложение, получив сообщение, дёргает этот
/// эндпоинт с msg_id из data. Нет подтверждения за N минут → сервер шлёт SMS.
const _ackEndpoint = 'https://lombard.center/api/push-ack.php';

/// Сверка «привязан ли номер» с сервером — источник истины, а не локальный
/// SharedPreferences (его может стереть OEM-очистка / переустановка).
const _bindStatusEndpoint = 'https://lombard.center/api/bind-status.php';

/// Серверный «ящик» уведомлений: приложение подтягивает пропущенные пуши,
/// даже если ни один не дошёл (токен умер / приложение было закрыто).
const _inboxEndpoint = 'https://lombard.center/api/inbox.php';

/// Данные пуша, по которому пользователь тапнул уведомление —
/// аналог pendingPushTitle/Body/Link/Id полей MainActivity.kt.
class PendingPush {
  final String id;
  final String title;
  final String body;
  final String link;
  final String msgId;

  const PendingPush({
    required this.id,
    required this.title,
    required this.body,
    required this.link,
    this.msgId = '',
  });

  factory PendingPush.fromJson(Map<String, dynamic> json) => PendingPush(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    link: json['link'] as String? ?? '',
    msgId: json['msg_id'] as String? ?? '',
  );
}

/// Firebase Cloud Messaging + локальные уведомления.
/// Аналог NativePushService.kt и FCM-части MainActivity.kt.
class PushService {
  PushService._();

  /// Позволяет показать диалог по пушу поверх любого текущего экрана —
  /// как showPendingPushDialog() в оригинале.
  static final ValueNotifier<PendingPush?> pendingPush = ValueNotifier(null);

  static final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// HTTP-клиент. В проде обычный, в тестах подменяется на MockClient.
  @visibleForTesting
  static http.Client httpClient = http.Client();

  /// Сброс сессионного состояния между тестами.
  @visibleForTesting
  static void resetForTest() {
    _lastToken = null;
    _tokenInProgress = false;
    _tokenSentOk = false;
    _inboxInProgress = false;
    _ackFlushInProgress = false;
  }

  /// Тест-обёртки над приватными обработчиками.
  @visibleForTesting
  static Future<void> debugHandleData(Map<String, dynamic> data, {String source = 'test'}) =>
      _handleMessage(RemoteMessage(data: data), source: source);
  @visibleForTesting
  static Future<void> debugSendAck(String msgId, String source) => _enqueueAck(msgId, source);

  /// Последний успешно полученный FCM-токен в этой сессии. null — значит на
  /// устройстве токен ещё ни разу не сгенерировался (см. ensureToken()).
  static String? _lastToken;
  static bool _tokenInProgress = false;

  /// true — токен успешно принят сервером. Если false, а токен есть — значит
  /// POST не прошёл (был офлайн); повторим при возврате сети / на след. старте.
  static bool _tokenSentOk = false;
  static StreamSubscription<List<ConnectivityResult>>? _connSub;

  static String? get lastToken => _lastToken;

  /// Паузы между попытками получить токен. Растут, чтобы пережить долгое
  /// обновление Google Play Services / временное отсутствие сети, но не
  /// молотить бесконечно. Всего попыток = длина списка + 1.
  static const List<Duration> _retryDelays = [
    Duration(seconds: 3),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(seconds: 90),
    Duration(minutes: 4),
  ];

  static void _log(String msg) => debugPrint('[PushService] $msg');

  static String _short(String token) => token.length <= 14
      ? token
      : '${token.substring(0, 8)}…${token.substring(token.length - 4)} (len=${token.length})';

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

    // Иконка "весы" — как ic_stat_name.xml в оригинальном NativePushService.kt.
    const androidInit = AndroidInitializationSettings('@drawable/ic_stat_name');
    await _local.initialize(
      settings: const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: _onLocalNotificationTapped,
    );

    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: 'Push уведомления',
      importance: Importance.high,
    );
    await _local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      _log('onTokenRefresh: ${_short(token)}');
      unawaited(AppLog.event('token_refresh', {'tok': _short(token)}));
      _lastToken = token;
      unawaited(_sendTokenToServer(token));
    });

    // Приложение запущено тапом по уведомлению, показанному flutter_local_notifications,
    // пока процесс был полностью убит — payload сюда прилетает отдельно от FCM.
    final launchDetails = await _local.getNotificationAppLaunchDetails();
    final launchPayload = launchDetails?.notificationResponse?.payload;
    if (launchDetails?.didNotificationLaunchApp == true && launchPayload != null) {
      _setPendingPushFromPayload(launchPayload);
    }

    // Сеть появилась/сменилась — дотягиваем то, что не успели офлайн:
    // нет токена → новый цикл попыток; токен есть, но не ушёл → повторный POST.
    _connSub ??= Connectivity().onConnectivityChanged.listen((results) {
      final online = !results.contains(ConnectivityResult.none);
      unawaited(AppLog.event('net', {'online': online, 'has_token': _lastToken != null, 'sent_ok': _tokenSentOk}));
      if (!online) return;
      if (_lastToken == null) {
        retryTokenIfMissing();
      } else if (!_tokenSentOk) {
        unawaited(_sendTokenToServer(_lastToken!));
      }
      // Сеть вернулась — дослать подтверждения доставки, застрявшие офлайн.
      unawaited(flushPendingAcks());
    });

    // Разрешение и получение токена НЕ ждём здесь — иначе холодный старт
    // блокируется на устройствах с медленным/недоступным FCM (см. коммит
    // "fix startup hang on push init failure"). Всё уходит в фон.
    unawaited(_bootstrapMessaging());
  }

  static Future<void> _bootstrapMessaging() async {
    try {
      await FirebaseMessaging.instance.setAutoInitEnabled(true);
    } catch (e) {
      _log('setAutoInitEnabled failed: $e');
    }
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      _log('permission: ${settings.authorizationStatus.name}');
      unawaited(AppLog.event('permission', {'status': settings.authorizationStatus.name}));
    } catch (e) {
      _log('requestPermission failed: $e');
      unawaited(AppLog.event('permission_fail', {'err': '$e'}));
    }
    await ensureToken();
    // после получения токена — сверить привязку номера с сервером
    // (лечит «разлогин» из-за потери локальных префов) и подтянуть из ящика
    // всё, что не дошло пушем.
    final restored = await reconcileBindState();
    if (restored) {
      // Сервер узнал устройство по device_uuid и вернул user_id — то есть
      // пользователь уже подключал персональные пуши раньше. Сразу
      // до-регистрируем токен с известным теперь user_id, чтобы серверная
      // строка токена получила владельца и сервер включил push-канал в 1С
      // (setpush(1)) — не дожидаясь следующего запуска приложения.
      await refreshServerRegistration();
    }
    unawaited(syncInbox());
    unawaited(flushPendingAcks());
  }

  /// Пытается получить FCM-токен с ретраями. На каждой неудаче шлёт подробную
  /// диагностику на сервер (_diagEndpoint) и пишет её же в лог — чтобы было
  /// видно, ПОЧЕМУ токен не сгенерировался на конкретном устройстве.
  static Future<void> ensureToken({bool force = false}) async {
    if (_tokenInProgress) return;
    if (_lastToken != null && !force) return;
    _tokenInProgress = true;
    try {
      for (var attempt = 0; attempt <= _retryDelays.length; attempt++) {
        Object? failure;
        StackTrace? failureStack;
        try {
          if (Platform.isIOS) {
            await _ensureApnsToken();
          }
          final token = await FirebaseMessaging.instance
              .getToken()
              .timeout(const Duration(seconds: 30));
          if (token != null && token.isNotEmpty) {
            _log('token acquired on attempt $attempt: ${_short(token)}');
            unawaited(AppLog.event('token_ok', {'attempt': attempt, 'tok': _short(token)}));
            _lastToken = token;
            await _sendTokenToServer(token);
            if (attempt > 0) {
              unawaited(AppLog.event('token_recovered', {'attempt': attempt}));
              // Токен в итоге получили, но не с первой попытки — фиксируем,
              // чтобы на сервере было видно "проблемные, но рабочие" устройства.
              unawaited(_reportDiagnostics(
                await _collectDiagnostics(attempt: attempt, note: 'recovered'),
              ));
            }
            return;
          }
          failure = 'getToken() returned null';
        } on TimeoutException catch (e, s) {
          failure = 'getToken() timed out after 30s: $e';
          failureStack = s;
        } catch (e, s) {
          failure = e;
          failureStack = s;
        }

        _log('token attempt $attempt failed: $failure');
        unawaited(AppLog.event('token_fail', {'attempt': attempt, 'err': '$failure'}));
        unawaited(_reportDiagnostics(await _collectDiagnostics(
          attempt: attempt,
          error: failure,
          stack: failureStack,
        )));

        if (attempt < _retryDelays.length) {
          await Future.delayed(_retryDelays[attempt]);
        }
      }
      _log('token could NOT be acquired after ${_retryDelays.length + 1} attempts');
      unawaited(AppLog.event('token_giveup', {'attempts': _retryDelays.length + 1}));
    } finally {
      _tokenInProgress = false;
    }
  }

  /// Сверяет с сервером, привязан ли номер к этому устройству. Если сервер
  /// говорит «да», а локально флаг потерян (очистка префов на MIUI,
  /// переустановка, сбой миграции shared_preferences) — восстанавливаем его.
  /// Только ДОБАВЛЯЕМ привязку; из-за ошибки/недоступности сервера ничего не
  /// снимаем — иначе разлогинили бы при первом сбое сети.
  ///
  /// «Привязан» = сервер вернул `bound:true` И знает `user_id` клиента 1С.
  /// Часть установок — «только пуши без привязки»: FCM-токен на сервере есть,
  /// но `user_id` пустой (пользователь дал разрешение на уведомления, но номер
  /// не подтверждал). Для них `bind-status.php` возвращает `bound:false`; здесь
  /// дополнительно страхуемся от `bound:true` с пустым `user_id` — иначе экран
  /// показал бы «подключено», а в 1С этого клиента нет (мусорное состояние).
  ///
  /// Возвращает `true`, только если привязка была ВОССТАНОВЛЕНА в этом вызове
  /// (сервер знает device_uuid и user_id, а локально флага не было). Вызывающий
  /// код по этому признаку до-регистрирует токен с уже известным user_id.
  static Future<bool> reconcileBindState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final alreadyVerified = prefs.getBool('phone_verified') ?? false;
      final deviceId = await resolveDeviceId();

      final resp = await httpClient
          .post(
            Uri.parse(_bindStatusEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'device_uuid': deviceId, if (_lastToken != null) 'token': _lastToken}),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return false;

      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final serverBound = j['bound'] == true;
      final uid = (j['user_id'] as String?)?.trim() ?? '';
      final bound = serverBound && uid.isNotEmpty;
      unawaited(AppLog.event('bind_status', {
        'server_bound': serverBound,
        'has_user_id': uid.isNotEmpty,
        'push_enabled': j['push_enabled'] == true,
        'local_verified': alreadyVerified,
      }));
      if (!bound) return false;

      // Номер для показа на экране «Уведомления» сохраняем всегда, когда сервер
      // его прислал. Если `bind-status.php` отдаёт полный `phone` — показываем
      // его без маски; иначе оседает хотя бы маска `phone_mask`.
      final fullPhone = j['phone'] as String?;
      if (fullPhone != null && fullPhone.isNotEmpty) {
        await prefs.setString('verified_phone', fullPhone);
      }
      final mask = j['phone_mask'] as String?;
      if (mask != null && mask.isNotEmpty) {
        await prefs.setString('verified_phone_mask', mask);
      }

      if (alreadyVerified) return false;

      await prefs.setBool('phone_verified', true);
      await prefs.setString('verified_user_id', uid);
      _log('bind state restored from server (user $uid)');
      unawaited(AppLog.event('bind_restored', {'user': uid}));
      return true;
    } catch (e) {
      _log('reconcileBindState failed: $e');
      unawaited(AppLog.event('bind_status_fail', {'err': '$e'}));
      return false;
    }
  }

  /// Повторно регистрирует ТЕКУЩИЙ FCM-токен на сервере с актуальными данными
  /// из SharedPreferences (в первую очередь — user_id). Вызывается сразу после
  /// того, как привязка номера восстановлена по device_uuid: без этого
  /// серверная строка токена осталась бы без владельца до следующего запуска
  /// приложения / onTokenRefresh.
  ///
  /// Если токен в этой сессии ещё не получен (`_lastToken == null`) — ничего не
  /// делаем: его отправит обычный путь `ensureToken()`, а из `_bootstrapMessaging`
  /// этот метод и так вызывается уже после `ensureToken()`.
  static Future<void> refreshServerRegistration() async {
    final token = _lastToken;
    if (token == null || token.isEmpty) return;
    try {
      await _sendTokenToServer(token);
    } catch (e) {
      _log('refreshServerRegistration failed: $e');
      unawaited(AppLog.event('token_reregister_fail', {'err': '$e'}));
    }
  }

  /// Подтягивает из серверного ящика уведомления, которые НЕ дошли пушем
  /// (токен умер, приложение было закрыто, OEM зарезал фон). Мёржит в локальную
  /// историю с дедупом по msg_id. Работает только для привязанного номера.
  static bool _inboxInProgress = false;
  static Future<void> syncInbox() async {
    if (_inboxInProgress) return;
    _inboxInProgress = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('verified_user_id') ?? '';
      if (userId.isEmpty) return; // номер не привязан — ящика нет
      final deviceId = await resolveDeviceId();
      final sinceId = prefs.getInt('inbox_last_id') ?? 0;

      final resp = await httpClient
          .get(Uri.parse('$_inboxEndpoint?user_id=${Uri.encodeComponent(userId)}'
              '&device_uuid=${Uri.encodeComponent(deviceId)}&since_id=$sinceId&limit=100'))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return;

      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = (j['items'] as List?) ?? const [];
      var added = 0;
      for (final it in items) {
        final m = it as Map<String, dynamic>;
        final msgId = m['msg_id'] as String? ?? '';
        final ts = parseInboxCreatedAt(m['created_at'] as String?);
        final id = await PushStorage.addPush(
          title: m['title'] as String? ?? 'Уведомление',
          body: m['body'] as String? ?? '',
          link: m['link'] as String? ?? 'https://lombard.center/',
          msgId: msgId,
          timestampMs: ts,
        );
        if (id.isNotEmpty) added++;
      }

      final lastId = (j['last_id'] as num?)?.toInt() ?? sinceId;
      if (lastId > sinceId) {
        await prefs.setInt('inbox_last_id', lastId);
        // подтвердим серверу, что забрали
        unawaited(httpClient
            .post(Uri.parse(_inboxEndpoint),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'user_id': userId, 'device_uuid': deviceId, 'last_id': lastId}))
            .timeout(const Duration(seconds: 8))
            .catchError((_) => http.Response('', 0)));
      }
      unawaited(AppLog.event('inbox_sync', {'got': items.length, 'added': added, 'last_id': lastId}));
    } catch (e) {
      unawaited(AppLog.event('inbox_sync_fail', {'err': '$e'}));
    } finally {
      _inboxInProgress = false;
    }
  }

  /// Точка входа фоновой задачи WorkManager (headless-изолят, отдельный от UI).
  /// Раз в сутки, даже если приложение не открывают: свежий токен → на сервер,
  /// подтянуть пропущенные уведомления из ящика, выгрузить журнал.
  @pragma('vm:entry-point')
  static Future<void> runBackgroundTokenSync() async {
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    } catch (_) {}
    try {
      await FirebaseMessaging.instance.setAutoInitEnabled(true);
    } catch (_) {}
    unawaited(AppLog.event('bg_worker_run'));
    try {
      if (Platform.isIOS) await _ensureApnsToken();
      final token = await FirebaseMessaging.instance
          .getToken()
          .timeout(const Duration(seconds: 30));
      if (token != null && token.isNotEmpty) {
        _lastToken = token;
        await _sendTokenToServer(token);
      } else {
        await _reportDiagnostics(await _collectDiagnostics(
            attempt: -1, error: 'bg: token_null', note: 'bg_worker'));
      }
    } catch (e, s) {
      await _reportDiagnostics(await _collectDiagnostics(
          attempt: -1, error: e, stack: s, note: 'bg_worker'));
    }
    // Сверить привязку с сервером и, если восстановилась (prefs стёрли, а
    // приложение так и не открывали) — до-зарегистрировать токен уже с user_id.
    if (await reconcileBindState()) {
      await refreshServerRegistration();
    }
    await syncInbox();
    await flushPendingAcks();
    await AppLog.flush(force: true);
  }

  /// Дёргать при возврате приложения на передний план — если токена всё ещё
  /// нет, запускаем новый цикл попыток (сеть/Play Services могли починиться).
  static void retryTokenIfMissing() {
    if (_lastToken != null || _tokenInProgress) return;
    unawaited(ensureToken());
  }

  /// На iOS getToken() бросает исключение, пока не получен APNS-токен —
  /// ждём его до ~6 секунд, потом пробуем всё равно.
  static Future<void> _ensureApnsToken() async {
    for (var i = 0; i < 3; i++) {
      try {
        final apns = await FirebaseMessaging.instance.getAPNSToken();
        if (apns != null && apns.isNotEmpty) return;
      } catch (e) {
        _log('getAPNSToken failed: $e');
      }
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  static Future<Map<String, dynamic>> _collectDiagnostics({
    required int attempt,
    Object? error,
    StackTrace? stack,
    String? note,
  }) async {
    final map = <String, dynamic>{
      'stage': 'fcm_token',
      'attempt': attempt,
      'ts': DateTime.now().toUtc().toIso8601String(),
      if (note != null) 'note': note,
      'app_source': 'flutter',
    };

    try {
      map['device_uuid'] = await resolveDeviceId();
    } catch (_) {}
    try {
      final pkg = await PackageInfo.fromPlatform();
      map['app_version'] = pkg.version;
      map['build_number'] = pkg.buildNumber;
    } catch (_) {}

    try {
      final di = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final ios = await di.iosInfo;
        map['platform'] = 'ios';
        map['os_version'] = ios.systemVersion;
        map['device_model'] = ios.utsname.machine;
        map['is_physical_device'] = ios.isPhysicalDevice;
        try {
          map['apns_token_present'] =
              (await FirebaseMessaging.instance.getAPNSToken()) != null;
        } catch (e) {
          map['apns_token_error'] = e.toString();
        }
      } else {
        final a = await di.androidInfo;
        map['platform'] = 'android';
        map['os_version'] = a.version.release;
        map['sdk_int'] = a.version.sdkInt;
        map['device_model'] = '${a.manufacturer} ${a.model}';
        map['brand'] = a.brand;
        map['is_physical_device'] = a.isPhysicalDevice;
        map['supported_abis'] = a.supportedAbis;
        // Есть ли на устройстве Google-сервисы вообще (дешёвый признак).
        map['has_gms_feature'] =
            a.systemFeatures.any((f) => f.startsWith('com.google.android'));
        // Точный статус Google Play Services — главный ответ на вопрос
        // "почему не генерируется токен": serviceMissing / serviceDisabled /
        // serviceVersionUpdateRequired / serviceInvalid / serviceUpdating / success.
        try {
          final gps = await GoogleApiAvailability.instance
              .checkGooglePlayServicesAvailability();
          map['play_services'] = gps.toString().split('.').last;
        } catch (e) {
          map['play_services'] = 'check_failed';
          map['play_services_error'] = e.toString();
        }
      }
    } catch (_) {}

    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      map['authorization_status'] = settings.authorizationStatus.name;
    } catch (_) {}
    try {
      map['auto_init_enabled'] = FirebaseMessaging.instance.isAutoInitEnabled;
    } catch (_) {}

    if (error != null) {
      map['error_type'] = error.runtimeType.toString();
      map['error'] = error.toString();
      if (error is FirebaseException) {
        map['error_code'] = error.code;
        map['error_plugin'] = error.plugin;
        map['error_message'] = error.message;
      }
    }
    if (stack != null) {
      map['stack'] = stack.toString().split('\n').take(8).join('\n');
    }
    return map;
  }

  static Future<void> _reportDiagnostics(Map<String, dynamic> data) async {
    try {
      await httpClient
          .post(
            Uri.parse(_diagEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(data),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      _log('failed to POST diagnostics: $e');
    }
  }

  static Future<void> _handleForegroundMessage(RemoteMessage message) =>
      _handleMessage(message, source: 'foreground');

  static Future<void> _handleMessage(RemoteMessage message, {String source = 'background'}) async {
    final data = message.data;

    // Тихий служебный пуш от сервера (push-refresh-ping.php): просто
    // перерегистрируем токен. Без истории, без уведомления, без ack.
    // Закрывает «токен ротировался, а приложение не открывали».
    if (isTokenRefreshPing(data)) {
      _log('token_refresh ping received → re-register token');
      unawaited(AppLog.event('refresh_ping_received', {'source': source}));
      await ensureToken(force: true);
      await syncInbox(); // раз уж подняли изолят — подтянем пропущенные уведомления
      unawaited(flushPendingAcks());
      unawaited(AppLog.flush(force: true));
      return;
    }

    // Сервер может принудительно попросить перерегистрировать токен и обычным
    // (не тихим) пушем — data.refresh_token=1. Полезно, когда сервер заметил,
    // что доставка на текущий токен деградирует, но пуш пока доходит. Токен
    // обновляем в фоне и продолжаем обычный показ самого сообщения.
    final rt = data['refresh_token'];
    if (rt == '1' || rt == 1 || rt == true) {
      unawaited(AppLog.event('force_token_refresh', {'source': source}));
      unawaited(ensureToken(force: true));
    }

    final title = data['title'] as String? ?? 'Уведомление';
    final body = data['body'] as String? ?? '';
    final link = data['link'] as String? ?? 'https://lombard.center/';
    final msgId = data['msg_id'] as String? ?? '';

    unawaited(AppLog.event('push_received', {'msg_id': msgId, 'source': source}));

    // Ставим подтверждение доставки в очередь и шлём СРАЗУ, до показа
    // уведомления. Если POST не пройдёт (обрыв связи в момент приёма) —
    // подтверждение останется в очереди и уйдёт при следующем старте /
    // возврате в приложение / появлении сети / syncInbox / фоновом воркере.
    unawaited(_enqueueAck(msgId, source));

    final id = await PushStorage.addPush(title: title, body: body, link: link, msgId: msgId);
    if (id.isEmpty) return; // дубль (msg_id уже в истории) — уведомление не повторяем
    try {
      await _showLocalNotification(id: id, title: title, body: body, link: link, msgId: msgId);
    } catch (e) {
      // Сбой показа уведомления не должен терять ack и запись в истории.
      _log('showLocalNotification failed: $e');
      unawaited(AppLog.event('notif_show_fail', {'err': '$e'}));
    }
  }

  static Future<void> _showLocalNotification({
    required String id,
    required String title,
    required String body,
    required String link,
    String msgId = '',
  }) async {
    const details = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Push уведомления',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@drawable/ic_stat_name',
    );
    await _local.show(
      id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(android: details),
      payload: jsonEncode({
        'id': id,
        'title': title,
        'body': body,
        'link': link,
        'msg_id': msgId,
      }),
    );
  }

  static void _onLocalNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;
    _setPendingPushFromPayload(payload);
  }

  static void _setPendingPushFromPayload(String payload) {
    try {
      final map = jsonDecode(payload) as Map<String, dynamic>;
      final push = PendingPush.fromJson(map);
      pendingPush.value = push;
      // Тап по уведомлению — тоже подтверждение доставки (на случай, если
      // headless-хендлер не поднялся). Дедуп по msg_id внутри очереди ack.
      unawaited(_enqueueAck(push.msgId, 'tap'));
    } catch (_) {
      // Некорректный payload — просто игнорируем тап.
    }
  }

  // --- Подтверждение доставки пуша (push-ack) --------------------------------
  //
  // Ack — единственный сигнал «пуш реально дошёл до устройства». Поэтому он НЕ
  // fire-and-forget: неотправленные подтверждения складываются в очередь
  // `pending_acks` и до-сылаются при старте, возврате в приложение, появлении
  // сети, syncInbox и фоновом воркере. Иначе секундный обрыв связи в момент
  // приёма пуша = потерянный ack → сервер считает «не доставлено» и шлёт
  // лишнюю SMS (а раньше ещё и «замок» на 7 дней).

  static const _ackedKey = 'acked_msg_ids';       // успешно подтверждённые (дедуп)
  static const _ackedMax = 300;
  static const _pendingAckKey = 'pending_acks';   // ждут отправки: "<msgId>#<source>"
  static const _pendingAckMax = 200;
  static const _ackSep = '#'; // msgId — hex, source — слово; '#' в них не встречается
  static bool _ackFlushInProgress = false;

  /// Поставить подтверждение в очередь и сразу попытаться отправить.
  static Future<void> _enqueueAck(String msgId, String source) async {
    if (msgId.isEmpty) return;
    if (await _isAcked(msgId)) return;
    await _addPendingAck(msgId, source);
    await flushPendingAcks();
  }

  /// Дослать все неподтверждённые ack. Безопасно дёргать часто и из разных мест
  /// (guard `_ackFlushInProgress`). Успех → в `acked_msg_ids`; неудача →
  /// остаётся в очереди до следующего вызова.
  static Future<void> flushPendingAcks() async {
    if (_ackFlushInProgress) return;
    _ackFlushInProgress = true;
    try {
      final p = await SharedPreferences.getInstance();
      final pending = p.getStringList(_pendingAckKey) ?? const <String>[];
      if (pending.isEmpty) return;
      final keep = <String>[];
      var sent = 0;
      for (final entry in pending) {
        final i = entry.indexOf(_ackSep);
        final msgId = i >= 0 ? entry.substring(0, i) : entry;
        final source = i >= 0 ? entry.substring(i + 1) : 'queued';
        if (msgId.isEmpty) continue;
        if (await _isAcked(msgId)) continue;
        if (await _postAck(msgId, source)) {
          await _markAcked(msgId);
          sent++;
        } else {
          keep.add(entry);
        }
      }
      await p.setStringList(_pendingAckKey, keep);
      if (sent > 0 || keep.isNotEmpty) {
        unawaited(AppLog.event('ack_flush', {'sent': sent, 'pending': keep.length}));
      }
    } catch (e) {
      _log('flushPendingAcks failed: $e');
    } finally {
      _ackFlushInProgress = false;
    }
  }

  /// Один POST на push-ack.php (2 быстрых попытки). true — сервер принял (2xx).
  static Future<bool> _postAck(String msgId, String source) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await httpClient
            .post(
              Uri.parse(_ackEndpoint),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'msg_id': msgId, 'source': source}),
            )
            .timeout(const Duration(seconds: 8));
        if (r.statusCode >= 200 && r.statusCode < 300) {
          _log('ack ok $msgId ($source)');
          unawaited(AppLog.event('ack_ok', {'msg_id': msgId, 'src': source, 'try': attempt}));
          return true;
        }
        _log('ack $msgId: HTTP ${r.statusCode}');
      } catch (e) {
        _log('ack $msgId failed (attempt $attempt): $e');
      }
      if (attempt == 0) await Future.delayed(const Duration(seconds: 2));
    }
    unawaited(AppLog.event('ack_retry_later', {'msg_id': msgId, 'src': source}));
    return false;
  }

  static Future<void> _addPendingAck(String msgId, String source) async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = [...(p.getStringList(_pendingAckKey) ?? const <String>[])];
      if (list.any((e) => e == msgId || e.startsWith('$msgId$_ackSep'))) return;
      list.add('$msgId$_ackSep$source');
      while (list.length > _pendingAckMax) {
        list.removeAt(0);
      }
      await p.setStringList(_pendingAckKey, list);
    } catch (_) {}
  }

  static Future<bool> _isAcked(String msgId) async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getStringList(_ackedKey) ?? const []).contains(msgId);
    } catch (_) {
      return false;
    }
  }

  static Future<void> _markAcked(String msgId) async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = [...(p.getStringList(_ackedKey) ?? const <String>[])];
      if (list.contains(msgId)) return;
      list.add(msgId);
      while (list.length > _ackedMax) {
        list.removeAt(0);
      }
      await p.setStringList(_ackedKey, list);
    } catch (_) {}
  }

  static Future<void> _sendTokenToServer(String token) async {
    try {
      final deviceId = await resolveDeviceId();
      final packageInfo = await PackageInfo.fromPlatform();
      final deviceInfo = DeviceInfoPlugin();
      final prefs = await SharedPreferences.getInstance();
      // user_id нужен серверу, чтобы при NotRegistered (приложение удалено)
      // он мог сам отвязать пуши в 1С — setpush(operation=0). См. docs/PUSH_BACKEND.md.
      final userId = prefs.getString('verified_user_id') ?? '';

      String platform;
      String deviceModel;
      String osVersion;
      if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        platform = 'ios-${iosInfo.systemVersion}';
        deviceModel = iosInfo.utsname.machine;
        osVersion = iosInfo.systemVersion;
      } else {
        final androidInfo = await deviceInfo.androidInfo;
        platform = 'android-${androidInfo.version.release}';
        deviceModel = '${androidInfo.manufacturer} ${androidInfo.model}';
        osVersion = androidInfo.version.release;
      }

      final response = await httpClient.post(
        Uri.parse(_tokenEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': token,
          'user_id': userId,
          'platform': platform,
          'device_model': deviceModel,
          'app_version': packageInfo.version,
          'os_version': osVersion,
          'device_uuid': deviceId,
          'app_source': 'flutter',
          // Устройство умеет подтверждать доставку пуша (push-ack.php) —
          // сервер по этому флагу ждёт ack и включает SMS-подстраховку.
          'push_ack': true,
        }),
      );
      _tokenSentOk = response.statusCode >= 200 && response.statusCode < 300;
      _log('token sent to server: HTTP ${response.statusCode}');
      unawaited(AppLog.event('token_sent', {'http': response.statusCode, 'has_user': userId.isNotEmpty}));
    } catch (e) {
      _tokenSentOk = false;
      _log('failed to send token: $e (повторим при возврате сети / на след. старте)');
      unawaited(AppLog.event('token_send_fail', {'err': '$e'}));
    }
  }

  /// Явная отписка от пушей — вызывать, когда пользователь сам отключает
  /// уведомления. Сервер по этому запросу должен удалить токен и вызвать
  /// 1С setpush(operation=0). Локально удаляем токен в FCM, чтобы устройство
  /// перестало числиться получателем. См. docs/PUSH_BACKEND.md.
  static Future<void> unregisterToken({String reason = 'user_disconnect'}) async {
    unawaited(AppLog.event('disconnect', {'reason': reason}));
    try {
      final token = _lastToken ??
          await FirebaseMessaging.instance.getToken().timeout(const Duration(seconds: 10));
      final deviceId = await resolveDeviceId();
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('verified_user_id') ?? '';
      await httpClient
          .post(
            Uri.parse('$_tokenEndpoint?action=delete'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'token': token,
              'user_id': userId,
              'device_uuid': deviceId,
              'reason': reason,
              'app_source': 'flutter',
            }),
          )
          .timeout(const Duration(seconds: 10));
      _log('unregister sent to server (reason=$reason)');
    } catch (e) {
      _log('unregister request failed: $e');
    }
    try {
      await FirebaseMessaging.instance.deleteToken();
      _log('local FCM token deleted');
    } catch (e) {
      _log('deleteToken failed: $e');
    }
    _lastToken = null;
  }
}

/// Должна быть top-level функцией с этой аннотацией — так требует firebase_messaging
/// для обработки пушей, когда приложение свёрнуто/закрыто (headless-изолят).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await PushService._handleMessage(message, source: 'background');
}
