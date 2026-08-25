import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/analytics_service.dart';
import '../services/push_service.dart';
import '../services/push_storage.dart';
import 'phone_verification_screen.dart';

/// Полноэкранный WebView сайта lombard.center — аналог MainActivity.kt.
class MainWebViewScreen extends StatefulWidget {
  const MainWebViewScreen({super.key});

  /// true, пока этот экран смонтирован — по нему main.dart решает, нужно ли
  /// открывать новый экран поверх текущего при тапе по уведомлению, или он
  /// уже открыт и сам подхватит пуш через свой listener (см. showPendingPushDialog).
  static bool isOpen = false;

  @override
  State<MainWebViewScreen> createState() => _MainWebViewScreenState();
}

class _MainWebViewScreenState extends State<MainWebViewScreen> {
  static const _pageLoadTimeout = Duration(seconds: 15);
  static const _homeUrl = 'https://lombard.center/';

  late final WebViewController _controller;
  late final StreamSubscription<List<ConnectivityResult>> _connSub;

  bool _loading = true;
  bool _pageFailed = false;
  bool _hasUnread = false;
  Timer? _loadTimeoutTimer;

  @override
  void initState() {
    super.initState();
    AnalyticsService.reportScreen('MainWebView');
    MainWebViewScreen.isOpen = true;
    PushService.pendingPush.addListener(_onPendingPushChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPendingPushChanged());

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _beginPageLoad();
            // Синхронная замена addJavascriptInterface("Android", isApp()) —
            // JavaScriptChannel в webview_flutter асинхронный (postMessage),
            // поэтому сайту отдаём обычный синхронный метод через инъекцию JS.
            _controller.runJavaScript(
              'window.Android = window.Android || {}; '
              'window.Android.isApp = function() { return true; };',
            );
          },
          onPageFinished: (url) {
            _loadTimeoutTimer?.cancel();
            if (!mounted) return;
            // _pageFailed НЕ сбрасываем здесь: onPageStarted уже сделал это в начале
            // текущей загрузки. Если между onPageStarted и onPageFinished успел
            // сработать onWebResourceError (Android WebView после ошибки всё равно
            // вызывает onPageFinished для своей внутренней страницы ошибки) —
            // заглушка должна остаться на экране, а не гаситься этим "успешным" finish.
            setState(() => _loading = false);
            _onPendingPushChanged();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? true) {
              _showOfflinePlaceholder();
            }
          },
          onNavigationRequest: (request) async {
            final uri = Uri.parse(request.url);

            if (request.url.toLowerCase().endsWith('.pdf')) {
              final viewerUrl =
                  'https://docs.google.com/gview?embedded=true&url=${Uri.encodeComponent(request.url)}';
              _controller.loadRequest(Uri.parse(viewerUrl));
              return NavigationDecision.prevent;
            }

            if (uri.scheme == 'http' || uri.scheme == 'https') {
              return NavigationDecision.navigate;
            }

            final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
            if (!opened && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Приложение банка не найдено')),
              );
            }
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse(_homeUrl));

    _beginPageLoad();
    _refreshBadge();
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = !results.contains(ConnectivityResult.none);
      if (!mounted) return;
      if (!online) {
        _showOfflinePlaceholder();
      } else if (_pageFailed) {
        _reload();
      }
    });
  }

  @override
  void dispose() {
    MainWebViewScreen.isOpen = false;
    PushService.pendingPush.removeListener(_onPendingPushChanged);
    _loadTimeoutTimer?.cancel();
    _connSub.cancel();
    super.dispose();
  }

  /// Аналог showPendingPushDialog() — как только страница догрузилась и есть
  /// пуш, по которому тапнули (сейчас или ранее), показываем диалог.
  void _onPendingPushChanged() {
    final push = PushService.pendingPush.value;
    if (push == null || _loading) return;
    _showPushDialog(push);
  }

  Future<void> _showPushDialog(PendingPush push) async {
    PushService.pendingPush.value = null;
    await PushStorage.markRead(push.id);
    _refreshBadge();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(push.title),
        content: SingleChildScrollView(child: Text(push.body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (push.link.startsWith('http')) {
                _controller.loadRequest(Uri.parse(push.link));
              }
            },
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }

  void _beginPageLoad() {
    _pageFailed = false;
    if (mounted) setState(() => _loading = true);
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = Timer(_pageLoadTimeout, () {
      if (_loading) _showOfflinePlaceholder();
    });
  }

  void _showOfflinePlaceholder() {
    _loadTimeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _pageFailed = true;
      _loading = false;
    });
  }

  void _reload() {
    _beginPageLoad();
    _controller.reload();
  }

  Future<void> _refreshBadge() async {
    final unread = await PushStorage.hasUnread();
    if (!mounted) return;
    setState(() => _hasUnread = unread);
  }

  Future<void> _openVerification() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PhoneVerificationScreen()),
    );
    _refreshBadge();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          _controller.goBack();
        } else if (mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              Positioned(
                bottom: 16,
                right: 16,
                child: _notificationsButton(),
              ),
              if (_loading && !_pageFailed)
                Container(
                  color: Theme.of(context).colorScheme.surface,
                  child: const Center(child: CircularProgressIndicator()),
                ),
              if (_pageFailed) _offlineOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  /// Кнопка открытия истории уведомлений — внизу экрана (аналог кнопки
  /// "Уведомления" на LandingActivity.kt), а не сверху, как временная иконка
  /// verifyIcon в оригинальном MainActivity.kt.
  Widget _notificationsButton() {
    final color = _hasUnread ? const Color(0xFFE53935) : const Color(0xFF555555);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 4,
      child: IconButton(
        icon: Icon(Icons.mail_outline, color: color),
        onPressed: _openVerification,
      ),
    );
  }

  Widget _offlineOverlay() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 72, color: Colors.grey),
            const SizedBox(height: 24),
            const Text(
              'Не удалось загрузить страницу',
              style: TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: Text(
                'Проверьте подключение к интернету и попробуйте снова',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                textAlign: TextAlign.center,
              ),
            ),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Вернуться на главную', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
