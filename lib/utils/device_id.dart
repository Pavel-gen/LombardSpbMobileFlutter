import 'dart:io';

import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// Идентификатор устройства для регистрации на сервере (FCM-токен, 1С).
/// На Android — ANDROID_ID, как в оригинальном приложении. У iOS аналога
/// ANDROID_ID нет, поэтому там используется identifierForVendor.
Future<String> resolveDeviceId() async {
  if (Platform.isIOS) {
    final info = await DeviceInfoPlugin().iosInfo;
    return info.identifierForVendor ?? 'unknown';
  }
  final id = await const AndroidId().getId();
  return id ?? 'unknown';
}
