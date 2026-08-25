import 'dart:async';

import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/analytics_service.dart';
import '../services/push_storage.dart';
import 'calculator_screen.dart';
import 'main_webview_screen.dart';
import 'phone_verification_screen.dart';

/// Стартовый экран — аналог LandingActivity.kt.
class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key});

  @override
  State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen> with WidgetsBindingObserver {
  bool _online = true;
  int _unreadCount = 0;
  late final StreamSubscription<List<ConnectivityResult>> _connSub;

  @override
  void initState() {
    super.initState();
    AnalyticsService.reportScreen('Landing');
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _connSub = Connectivity().onConnectivityChanged.listen((_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connSub.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final results = await Connectivity().checkConnectivity();
    final online = !results.contains(ConnectivityResult.none);
    final items = await PushStorage.getAll();
    final unread = items.where((e) => !e.read).length;
    if (!mounted) return;
    setState(() {
      _online = online;
      _unreadCount = unread;
    });
  }

  Future<void> _openContent() async {
    final results = await Connectivity().checkConnectivity();
    final online = !results.contains(ConnectivityResult.none);
    if (online) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const MainWebViewScreen()),
      );
      _refresh();
    } else {
      _refresh();
    }
  }

  Future<void> _openVerification() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PhoneVerificationScreen()),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              const SizedBox(height: 24),
              // Чёрно-белая иконка "весы" — та же, что и в push-уведомлениях
              // (ic_stat_name.xml из оригинального NativePushService.kt),
              // цвет подстраивается под тему (чёрный на светлой, белый на тёмной).
              SvgPicture.asset(
                'assets/images/ic_scales.svg',
                width: 140,
                height: 140,
                colorFilter: ColorFilter.mode(
                  Theme.of(context).colorScheme.onSurface,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(height: 24),
              const Text('Ломбард', style: TextStyle(fontSize: 26)),
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 32),
                child: Text(
                  'Ваш личный финансовый помощник',
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                  textAlign: TextAlign.center,
                ),
              ),
              if (_online)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _actionButton('Наши услуги', _openContent),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Нет подключения к интернету. Доступны калькулятор и уведомления.',
                    style: TextStyle(fontSize: 13, color: Color(0xFFF57C00)),
                    textAlign: TextAlign.center,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _actionButton(
                  'Калькулятор займа',
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CalculatorScreen()),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _actionButton('Уведомления', _openVerification),
                    if (_unreadCount > 0)
                      Positioned(
                        top: -4,
                        right: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$_unreadCount',
                            style: const TextStyle(color: Colors.white, fontSize: 11),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                'lombard.center',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton(String text, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: onPressed,
        child: Text(text, style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}
