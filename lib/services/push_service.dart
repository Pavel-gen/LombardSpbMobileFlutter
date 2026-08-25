import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../firebase_options.dart';
import '../utils/device_id.dart';
import 'push_storage.dart';

const _channelId = 'twa_push_channel';
const _channelName = 'Уведомления приложения';

/// Данные пуша, по которому пользователь тапнул уведомление —
/// аналог pendingPushTitle/Body/Link/Id полей MainActivity.kt.
class PendingPush {
  final String id;
  final String title;
  final String body;
  final String link;

  const PendingPush({
    required this.id,
    required this.title,
    required this.body,
    required this.link,
  });

  factory PendingPush.fromJson(Map<String, dynamic> json) => PendingPush(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    link: json['link'] as String? ?? '',
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

    try {
      await FirebaseMessaging.instance.requestPermission().timeout(const Duration(seconds: 5));
    } catch (_) {}

    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Приложение запущено тапом по уведомлению, показанному flutter_local_notifications,
    // пока процесс был полностью убит — payload сюда прилетает отдельно от FCM.
    final launchDetails = await _local.getNotificationAppLaunchDetails();
    final launchPayload = launchDetails?.notificationResponse?.payload;
    if (launchDetails?.didNotificationLaunchApp == true && launchPayload != null) {
      _setPendingPushFromPayload(launchPayload);
    }

    try {
      final token = await FirebaseMessaging.instance.getToken().timeout(const Duration(seconds: 5));
      if (token != null) {
        unawaited(_sendTokenToServer(token));
      }
    } catch (_) {}
    FirebaseMessaging.instance.onTokenRefresh.listen(_sendTokenToServer);
  }

  static Future<void> _handleForegroundMessage(RemoteMessage message) => _handleMessage(message);

  static Future<void> _handleMessage(RemoteMessage message) async {
    final data = message.data;
    final title = data['title'] as String? ?? 'Уведомление';
    final body = data['body'] as String? ?? '';
    final link = data['link'] as String? ?? 'https://lombard.center/';

    final id = await PushStorage.addPush(title: title, body: body, link: link);
    await _showLocalNotification(id: id, title: title, body: body, link: link);
  }

  static Future<void> _showLocalNotification({
    required String id,
    required String title,
    required String body,
    required String link,
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
      payload: jsonEncode({'id': id, 'title': title, 'body': body, 'link': link}),
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
      pendingPush.value = PendingPush.fromJson(map);
    } catch (_) {
      // Некорректный payload — просто игнорируем тап.
    }
  }

  static Future<void> _sendTokenToServer(String token) async {
    try {
      final deviceId = await resolveDeviceId();
      final packageInfo = await PackageInfo.fromPlatform();
      final deviceInfo = DeviceInfoPlugin();

      String platform;
      String deviceModel;
      String osVersion;
      if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        // Формат совпадает со схемой 'android-X' из оригинала — уточните у бэкенда,
        // ждёт ли он именно такое значение для iOS, если это критично для сервера.
        platform = 'ios-${iosInfo.systemVersion}';
        deviceModel = iosInfo.utsname.machine;
        osVersion = iosInfo.systemVersion;
      } else {
        final androidInfo = await deviceInfo.androidInfo;
        platform = 'android-${androidInfo.version.release}';
        deviceModel = '${androidInfo.manufacturer} ${androidInfo.model}';
        osVersion = androidInfo.version.release;
      }

      await http.post(
        Uri.parse('https://lombard.center/api/fcm-token.php'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': token,
          'platform': platform,
          'device_model': deviceModel,
          'app_version': packageInfo.version,
          'os_version': osVersion,
          'device_uuid': deviceId,
        }),
      );
    } catch (_) {
      // Сеть недоступна — токен уйдёт при следующем onTokenRefresh/старте приложения.
    }
  }
}

/// Должна быть top-level функцией с этой аннотацией — так требует firebase_messaging
/// для обработки пушей, когда приложение свёрнуто/закрыто (headless-изолят).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await PushService._handleMessage(message);
}
