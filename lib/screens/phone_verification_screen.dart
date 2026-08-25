import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_auth/smart_auth.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/push_item.dart';
import '../services/analytics_service.dart';
import '../services/push_storage.dart';
import '../utils/device_id.dart';
import '../utils/phone_mask_formatter.dart';

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
  String _statusText = '';

  String _currentKod = '';
  String _currentPhone = '';
  String _currentUserId = '';

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
    final verified = prefs.getBool('phone_verified') ?? false;
    final history = await PushStorage.getAll();
    if (!mounted) return;
    setState(() {
      _isVerified = verified;
      _history = history;
    });
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
        if (mounted) Navigator.of(context).pop(true);
      } else {
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
        title: const Text('Отключить уведомления?'),
        content: const Text(
          'Вы перестанете получать персональные push-уведомления, и коды '
          'подтверждения будут приходить через SMS. Чтобы включить их снова, '
          'нужно будет привязать номер ещё раз.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Отключить')),
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
      await _clearVerificationLocally();
      return;
    }

    setState(() {
      _busy = true;
      _statusText = 'Отключение уведомлений...';
    });

    try {
      final response = await http.post(
        Uri.parse('https://lombard.center/api/1c.php?action=setpush'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': userId, 'operation': 0}),
      );
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['success'] == true) {
        await _clearVerificationLocally();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Уведомления отключены')),
          );
        }
      } else {
        setState(() {
          _statusText = json['message'] as String? ?? 'Не удалось отключить уведомления';
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

    _phoneController.clear();
    _codeController.clear();
    setState(() {
      _busy = false;
      _isVerified = false;
      _showCodeStep = false;
      _currentUserId = '';
      _currentPhone = '';
      _currentKod = '';
      _statusText = 'Уведомления отключены. Можете привязать другой номер.';
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
        content: SingleChildScrollView(child: Text(item.body)),
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
    return Scaffold(
      appBar: AppBar(title: const Text('Подключение персональных уведомлений')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_statusText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_statusText, style: const TextStyle(color: Colors.black54)),
                ),
              if (_isVerified) ...[
                const Padding(
                  padding: EdgeInsets.only(bottom: 24),
                  child: Text(
                    '✅ Вы уже подключили персональные уведомления',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
                SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: _busy ? null : _onDisconnect,
                    child: const Text('Отключить персональные push уведомления'),
                  ),
                ),
              ] else if (!_showCodeStep) ...[
                const Text('Введите номер телефона:'),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
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
                const Text('Введите код из СМС:'),
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
              const Padding(
                padding: EdgeInsets.only(top: 16, bottom: 8),
                child: Text('История уведомлений:', style: TextStyle(fontSize: 15)),
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
        itemBuilder: (context, index) {
          final item = _history[index];
          return ListTile(
            onTap: () => _openPush(item),
            leading: Icon(
              item.read ? Icons.circle_outlined : Icons.circle,
              size: 12,
              color: item.read ? Colors.grey.shade300 : const Color(0xFFE53935),
            ),
            title: Text(
              item.title,
              style: TextStyle(fontWeight: item.read ? FontWeight.normal : FontWeight.bold),
            ),
            subtitle: Text(item.body, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Text(
              _formatTimestamp(item.timestamp),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          );
        },
      ),
    );
  }
}
