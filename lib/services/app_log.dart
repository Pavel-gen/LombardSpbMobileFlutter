import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/device_id.dart';
import 'push_logic.dart';

const _appLogEndpoint = 'https://lombard.center/api/app-log.php';

/// Структурный журнал событий приложения с выгрузкой на сервер.
///
/// Зачем: `debugPrint` виден только в logcat и теряется, как только приложение
/// закрыли. Здесь события копятся в кольцевом буфере на устройстве и УХОДЯТ
/// ПАЧКОЙ на сервер (на старте — за прошлую сессию, при уходе в фон, раз в N
/// часов). По ним на сервере (`app-log-view.php`) видно всю хронологию
/// конкретного устройства: получил токен / отправил / пришёл пуш / ack / ошибка.
///
/// Нагрузка на сервер: 1 запрос на запуск/фон/сутки, ~5–20 КБ. Не по событию.
class AppLog {
  AppLog._();

  static const _kBuffer = 'app_log_buffer';    // List<String> — по одному JSON на событие
  static const _kInstallId = 'app_install_id';
  static const _kLastFlush = 'app_log_last_flush_ms';

  static const _maxBuffered = 600;             // кольцо
  static const _flushEveryEvents = 40;         // авто-флаш по числу событий
  static const _flushMinInterval = Duration(hours: 6);

  static String _sessionId = '';
  static String _installId = '';
  static String _appVersion = '';
  static bool _flushing = false;
  static int _sinceFlush = 0;

  /// HTTP-клиент. В проде — обычный, в тестах подменяется на MockClient.
  @visibleForTesting
  static http.Client httpClient = http.Client();

  /// Сброс статического состояния между тестами.
  @visibleForTesting
  static void resetForTest({String installId = 'test-install', String sessionId = 'test-session'}) {
    _installId = installId;
    _sessionId = sessionId;
    _appVersion = 'test';
    _flushing = false;
    _sinceFlush = 0;
  }

  static String get installId => _installId;
  static String get sessionId => _sessionId;

  /// Вызывать один раз при старте (до основной инициализации).
  static Future<void> init() async {
    await _ensureIds();
    try {
      _appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    await event('app_start', {'session': _sessionId});
    // на старте отправляем всё, что накопилось за прошлую сессию
    unawaited(flush(force: true));
  }

  /// Гарантирует `install_id` (постоянный) и `session_id` (на процесс), НЕ
  /// логируя `app_start`. Нужно headless-изолятам (фоновый воркер, обработчик
  /// пуша), где `init()` не вызывается, но события всё равно шлются.
  static Future<void> _ensureIds() async {
    if (_installId.isNotEmpty && _sessionId.isNotEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      if (_installId.isEmpty) {
        _installId = p.getString(_kInstallId) ?? '';
        if (_installId.isEmpty) {
          _installId = _randomId();
          await p.setString(_kInstallId, _installId);
        }
      }
      if (_sessionId.isEmpty) _sessionId = _randomId();
    } catch (_) {}
  }

  /// Записать событие. `data` — компактный map (обрежется до ~1.5 КБ в JSON).
  static Future<void> event(String name, [Map<String, dynamic>? data]) async {
    if (_installId.isEmpty || _sessionId.isEmpty) await _ensureIds();
    final rec = <String, dynamic>{
      't': DateTime.now().toUtc().toIso8601String(),
      'e': name,
      if (data != null && data.isNotEmpty) 'd': data,
    };
    var line = jsonEncode(rec);
    if (line.length > 1600) line = line.substring(0, 1600);
    if (kDebugMode) debugPrint('[AppLog] $name ${data ?? ''}');

    try {
      final p = await SharedPreferences.getInstance();
      final buf = [...(p.getStringList(_kBuffer) ?? const <String>[])];
      buf.add(line);
      if (buf.length > _maxBuffered) buf.removeRange(0, buf.length - _maxBuffered);
      await p.setStringList(_kBuffer, buf);
    } catch (_) {}

    // Ошибки не ждут пачки — выгружаем сразу (они редкие).
    if (appLogIsUrgent(name)) {
      _sinceFlush = 0;
      unawaited(flush(force: true));
    } else if (++_sinceFlush >= _flushEveryEvents) {
      _sinceFlush = 0;
      unawaited(flush());
    }
  }

  /// Отправить накопленное на сервер. `force` — игнорировать интервал.
  static Future<void> flush({bool force = false}) async {
    if (_flushing) return;
    _flushing = true;
    try {
      final p = await SharedPreferences.getInstance();
      final buf = p.getStringList(_kBuffer) ?? const <String>[];
      if (buf.isEmpty) return;

      if (!force) {
        final last = p.getInt(_kLastFlush) ?? 0;
        if (DateTime.now().millisecondsSinceEpoch - last < _flushMinInterval.inMilliseconds) {
          return;
        }
      }

      // берём не больше 400 за раз, чтобы тело было маленьким
      final take = buf.length > 400 ? buf.sublist(0, 400) : buf;
      final events = take
          .map((s) {
            try {
              return jsonDecode(s);
            } catch (_) {
              return {'t': '', 'e': 'parse_error'};
            }
          })
          .toList();

      String deviceId = '';
      try {
        deviceId = await resolveDeviceId();
      } catch (_) {}

      final resp = await httpClient
          .post(
            Uri.parse(_appLogEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(buildAppLogPayload(
              installId: _installId,
              sessionId: _sessionId,
              appVersion: _appVersion,
              deviceUuid: deviceId,
              events: events,
            )),
          )
          .timeout(const Duration(seconds: 12));

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        // удаляем отправленные (буфер мог дополниться — режем по количеству)
        final fresh = [...(p.getStringList(_kBuffer) ?? const <String>[])];
        final remove = take.length <= fresh.length ? take.length : fresh.length;
        fresh.removeRange(0, remove);
        await p.setStringList(_kBuffer, fresh);
        await p.setInt(_kLastFlush, DateTime.now().millisecondsSinceEpoch);
      }
    } catch (_) {
      // не страшно — отправим при следующем триггере
    } finally {
      _flushing = false;
    }
  }

  static String _randomId() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }
}
