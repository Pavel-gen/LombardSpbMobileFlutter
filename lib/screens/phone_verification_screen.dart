import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_auth/smart_auth.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/push_item.dart';
import '../services/analytics_service.dart';
import '../services/app_log.dart';
import '../services/push_service.dart';
import '../services/push_storage.dart';
import '../utils/device_id.dart';
import '../utils/phone_mask_formatter.dart';
import '../widgets/linkified_text.dart';

/// Привязка номера телефона (push-уведомления) + история пушей.
/// Аналог PhoneVerificationActivity.kt + SmsCodeRetriever.kt (SMS User Consent API).
class PhoneVerificationScreen extends StatefulWidget {
  const PhoneVerificationScreen({super.key});

  @override
  State<PhoneVerificationScreen> createState() => _PhoneVerificationScreenState();
}

class _PhoneVerificationScreenState extends State<PhoneVerificationScreen> {
  static const _skipStatuses = {0, 2, 3, 4, 5, 6, 7};

  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  bool _showCodeStep = false;
  bool _isVerified = false;
  bool _busy = false;
  bool _loading = true; // первичная загрузка локального состояния
  String _statusText = '';

  String _currentKod = '';
  String _currentPhone = '';
  String _currentUserId = '';

  /// Зарегистрированный номер для показа в подключённом состоянии, уже
  /// отформатированный (`+7 (999) 123-45-67`). Приоритет — полный
  /// `verified_phone`; если его нет (привязка восстановлена с сервера) —
  /// серверная маска `verified_phone_mask` как есть.
  String _verifiedPhone = '';

  List<PushItem> _history = [];

  @override
  void initState() {
    super.initState();
    AnalyticsService.reportScreen('PhoneVerification');
    _load();
  }

  @override
  void dispose() {
    // SMS User Consent API — Android-only, на iOS плагин этот вызов не поддерживает.
    if (Platform.isAndroid) {
      SmartAuth.instance.removeUserConsentApiListener();
    }
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  /// Аналог SmsCodeRetriever.start() — слушает входящие SMS через SMS User
  /// Consent API: система сама покажет диалог с превью текста и кнопкой
  /// "Разрешить", после чего код автоматически подставляется в поле.
  /// Только Android — на iOS такого API нет, там код подставляется штатно
  /// через autofillHints: [AutofillHints.oneTimeCode] на самом текстовом поле.
  Future<void> _startSmsListener() async {
    if (!Platform.isAndroid) return;
    final result = await SmartAuth.instance.getSmsWithUserConsentApi();
    if (!mounted || !_showCodeStep) return;
    if (result.hasData && result.data?.code != null) {
      setState(() => _codeController.text = result.data!.code!);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Код подставлен из SMS')),
      );
    }
  }

  Future<String> _deviceId() => resolveDeviceId();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final verifiedLocal = prefs.getBool('phone_verified') ?? false;

    // ШАГ 1. Сразу показываем последнее известное состояние из локальной
    // памяти — без ожидания сети, чтобы экран не мигал «форма ввода → ✅».
    final history0 = await PushStorage.getAll();
    if (!mounted) return;
    setState(() {
      _isVerified = verifiedLocal;
      _verifiedPhone = _readPhone(prefs);
      _history = history0;
      _loading = false;
    });

    // ШАГ 2. Тихая синхронизация с сервером в фоне. Если локально «не
    // привязан» — спросим сервер по device_uuid (источник истины): флаг мог
    // потеряться из-за очистки префов на MIUI / переустановки, ИЛИ пользователь
    // уже подключал персональные пуши на этом устройстве раньше. В этом случае
    // включаем их сразу — без повторного ввода номера и кода из SMS.
    if (!verifiedLocal) {
      final restored = await PushService.reconcileBindState();
      if (restored) {
        await PushService.refreshServerRegistration();
      }
    }
    await PushService.syncInbox();

    final verifiedAfter = prefs.getBool('phone_verified') ?? false;
    final history1 = await PushStorage.getAll();
    if (!mounted) return;
    setState(() {
      _isVerified = verifiedAfter;
      _verifiedPhone = _readPhone(prefs);
      _history = history1;
    });
  }

  /// Номер для подключённого состояния: приоритет — полный `verified_phone`
  /// (форматируем в `+7 (999) 123-45-67`), иначе — серверная маска как есть.
  String _readPhone(SharedPreferences prefs) {
    final full = prefs.getString('verified_phone') ?? '';
    if (full.isNotEmpty) return formatRuPhone(full);
    return prefs.getString('verified_phone_mask') ?? '';
  }

  String _statusMessage(int status, String statusText) {
    switch (status) {
      case 0:
        return 'Номер не найден в базе. Продолжаем без уведомлений.';
      case 2:
        return 'Push-уведомления уже подключены.';
      case 3:
        return 'Для вашего аккаунта отключён ЭДО.';
      case 4:
        return 'Ошибка авторизации сервера. Попробуйте позже.';
      case 5:
        return 'Неверный формат номера телефона.';
      case 6:
        return 'Неверные параметры запроса.';
      case 7:
        return 'Номер привязан к нескольким аккаунтам. Обратитесь в поддержку.';
      default:
        return statusText.isNotEmpty ? statusText : 'Неизвестная ошибка ($status)';
    }
  }

  Future<void> _onGetCode() async {
    final digits = _phoneController.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 11 || !digits.startsWith('7')) {
      setState(() => _statusText = 'Введите корректный номер телефона');
      return;
    }
    final phone = '+$digits';

    setState(() {
      _busy = true;
      _statusText = 'Отправка запроса...';
    });

    try {
      final response = await http.post(
        Uri.parse('https://lombard.center/api/1c.php?action=getcontactid'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'phone': phone, 'device_uuid': await _deviceId()}),
      );
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final success = json['success'] == true;
      final status = (json['status'] as num?)?.toInt() ?? -1;
      final statusTxt = json['status_text'] as String? ?? '';

      if (!success) {
        setState(() => _statusText = _statusMessage(status, json['message'] as String? ?? ''));
        _skipVerification();
        return;
      }

      if (status == 1 || status == 2) {
        setState(() {
          _currentPhone = phone;
          _currentUserId = json['user_id'] as String? ?? '';
          _currentKod = json['kod'] as String? ?? '';
          _showCodeStep = true;
          _statusText = 'Код отправлен на $phone';
          _busy = false;
        });
        _startSmsListener();
      } else if (_skipStatuses.contains(status)) {
        setState(() => _statusText = _statusMessage(status, statusTxt));
        _skipVerification();
      } else {
        setState(() {
          _statusText = 'Неизвестный статус: $status. $statusTxt';
          _busy = false;
        });
      }
    } catch (e) {
      setState(() {
        _statusText = 'Ошибка сети: $e';
        _busy = false;
      });
    }
  }

  Future<void> _onVerifyCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _statusText = 'Введите код');
      return;
    }
    if (code != _currentKod) {
      setState(() => _statusText = 'Неверный код. Попробуйте ещё раз');
      return;
    }

    setState(() {
      _busy = true;
      _statusText = 'Привязка устройства...';
    });

    try {
      final response = await http.post(
        Uri.parse('https://lombard.center/api/1c.php?action=binddevice'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': _currentUserId,
          'device_uuid': await _deviceId(),
          'phone': _currentPhone,
        }),
      );
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['success'] == true) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('phone_verified', true);
        await prefs.setString('verified_user_id', _currentUserId);
        await prefs.setString('verified_phone', _currentPhone);
        AppLog.event('verify_ok', {'user': _currentUserId});
        if (mounted) Navigator.of(context).pop(true);
      } else {
        AppLog.event('verify_fail', {'msg': json['message']});
        setState(() {
          _statusText = json['message'] as String? ?? 'Ошибка сервера';
          _busy = false;
        });
      }
    } catch (e) {
      setState(() {
        _statusText = 'Ошибка сети: $e';
        _busy = false;
      });
    }
  }

  void _skipVerification() {
    setState(() => _busy = false);
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  Future<void> _onDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отписаться от персональных пушей?'),
        content: const Text(
          'Сообщения ломбарда и коды подтверждения будут приходить по SMS. '
          'Снова подключить персональные пуши можно в любой момент — '
          'достаточно подтвердить номер телефона.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Отписаться')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _performDisconnect();
  }

  Future<void> _performDisconnect() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('verified_user_id') ?? '';

    if (userId.isEmpty) {
      await PushService.unregisterToken();
      await _clearVerificationLocally();
      return;
    }

    setState(() {
      _busy = true;
      _statusText = 'Отписываем от персональных пушей...';
    });

    try {
      final response = await http.post(
        Uri.parse('https://lombard.center/api/1c.php?action=setpush'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': userId, 'operation': 0}),
      );
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['success'] == true) {
        // Удаляем FCM-токен на устройстве и просим сервер снять получение
        // пушей (по этому же device_uuid/user_id) — чтобы токен не оставался
        // «живым» получателем после отключения.
        await PushService.unregisterToken();
        await _clearVerificationLocally();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Вы отписались от персональных пушей')),
          );
        }
      } else {
        setState(() {
          _statusText = json['message'] as String? ?? 'Не удалось отписаться от персональных пушей';
          _busy = false;
        });
      }
    } catch (e) {
      setState(() {
        _statusText = 'Ошибка сети: $e';
        _busy = false;
      });
    }
  }

  Future<void> _clearVerificationLocally() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('phone_verified', false);
    await prefs.remove('verified_user_id');
    await prefs.remove('verified_phone');
    await prefs.remove('verified_phone_mask');

    _phoneController.clear();
    _codeController.clear();
    setState(() {
      _busy = false;
      _isVerified = false;
      _showCodeStep = false;
      _currentUserId = '';
      _currentPhone = '';
      _currentKod = '';
      _verifiedPhone = '';
      _statusText = 'Вы отписались от персональных пушей. Можно подключить снова или привязать другой номер.';
    });
  }

  Future<void> _openPush(PushItem item) async {
    if (!item.read) {
      await PushStorage.markRead(item.id);
      final history = await PushStorage.getAll();
      if (mounted) setState(() => _history = history);
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.title),
        // Ссылки внутри текста пуша — кликабельные, открываются во внешнем
        // браузере. Аналог formatTextWithClickableLinks() + LinkMovementMethod
        // из PhoneVerificationActivity.kt.
        content: SingleChildScrollView(child: LinkifiedText(item.body)),
        actions: [
          if (item.link.startsWith('http'))
            TextButton(
              onPressed: () => launchUrl(Uri.parse(item.link), mode: LaunchMode.externalApplication),
              child: const Text('Открыть ссылку'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  String _formatTimestamp(int ts) {
    if (ts <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Подписи над полями и статус-строка — цвет из темы, чтобы не сливались
    // с тёмным фоном (раньше был жёстко зашит Colors.black54).
    final labelStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: cs.onSurface,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Уведомления', overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_statusText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    _statusText,
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              if (_isVerified) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '✅ Персональные push-уведомления подключены',
                    style: TextStyle(fontSize: 16, color: cs.onSurface),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Text(
                    _verifiedPhone.isNotEmpty
                        ? 'На этом устройстве зарегистрирован номер $_verifiedPhone. '
                            'Сообщения ломбарда и коды подтверждения приходят push-уведомлением.'
                        : 'Номер телефона зарегистрирован на этом устройстве. '
                            'Сообщения ломбарда и коды подтверждения приходят push-уведомлением.',
                    style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _busy ? null : _onDisconnect,
                    style: TextButton.styleFrom(
                      foregroundColor: cs.onSurfaceVariant,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                    child: const Text('Отписаться от персональных пушей'),
                  ),
                ),
              ] else if (!_showCodeStep) ...[
                Text('Введите номер телефона:', style: labelStyle),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  inputFormatters: [PhoneMaskFormatter()],
                  decoration: const InputDecoration(hintText: '+7 (999) 123-45-67'),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _busy ? null : _onGetCode,
                    child: const Text('Получить код'),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Пропустить', style: TextStyle(color: Colors.grey)),
                ),
              ] else ...[
                Text('Введите код из СМС:', style: labelStyle),
                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  // На iOS штатно подставляет код из SMS через QuickType — аналог
                  // SMS User Consent API, который на iOS недоступен.
                  autofillHints: const [AutofillHints.oneTimeCode],
                  decoration: const InputDecoration(hintText: '0000'),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _busy ? null : _onVerifyCode,
                    child: const Text('Подтвердить'),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Пропустить', style: TextStyle(color: Colors.grey)),
                ),
              ],
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 8),
                child: Text('История уведомлений:', style: labelStyle),
              ),
              _historyList(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _historyList() {
    if (_history.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('Уведомлений пока нет', style: TextStyle(color: Colors.grey)),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: _history.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) => _historyTile(_history[index]),
      ),
    );
  }

  /// Строка истории. Дата/время — ПОД текстом, а не в trailing: длинный
  /// заголовок теперь переносится максимум на 2 строки с многоточием и не
  /// расталкивает вёрстку (как это делала колонка в buildPushRow() Kotlin-версии).
  Widget _historyTile(PushItem item) {
    return InkWell(
      onTap: () => _openPush(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 12),
              child: Icon(
                item.read ? Icons.circle_outlined : Icons.circle,
                size: 12,
                color: item.read ? Colors.grey.shade300 : const Color(0xFFE53935),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: item.read ? FontWeight.normal : FontWeight.bold,
                    ),
                  ),
                  if (item.body.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        item.body,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _formatTimestamp(item.timestamp),
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
