import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/push_item.dart';

/// История push-уведомлений в SharedPreferences.
/// Аналог PushStorage.kt из Android-версии — тот же формат JSON-массива,
/// тот же ключ и лимит, чтобы поведение совпадало 1:1.
class PushStorage {
  static const _keyItems = 'items';
  static const _maxItems = 200;

  static Future<SharedPreferences> _prefs() =>
      SharedPreferences.getInstance();

  static Future<String> addPush({
    required String title,
    required String body,
    required String link,
  }) async {
    final id =
        '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1000000)}';
    final item = PushItem(
      id: id,
      title: title,
      body: body,
      link: link,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      read: false,
    );

    final list = await getAll();
    list.insert(0, item);
    while (list.length > _maxItems) {
      list.removeLast();
    }
    await _saveAll(list);
    return id;
  }

  static Future<void> markRead(String? id) async {
    if (id == null || id.isEmpty) return;
    final list = await getAll();
    final idx = list.indexWhere((e) => e.id == id);
    if (idx >= 0 && !list[idx].read) {
      list[idx] = list[idx].copyWith(read: true);
      await _saveAll(list);
    }
  }

  static Future<List<PushItem>> getAll() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_keyItems);
    if (raw == null) return [];
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      return arr
          .map((e) => PushItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<bool> hasUnread() async {
    final list = await getAll();
    return list.any((e) => !e.read);
  }

  static Future<void> _saveAll(List<PushItem> list) async {
    final prefs = await _prefs();
    final raw = jsonEncode(list.map((e) => e.toJson()).toList());
    await prefs.setString(_keyItems, raw);
  }

  static Future<void> clear() async {
    final prefs = await _prefs();
    await prefs.remove(_keyItems);
  }
}
