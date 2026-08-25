import 'package:flutter/material.dart';

import 'screens/landing_screen.dart';
import 'screens/main_webview_screen.dart';
import 'services/analytics_service.dart';
import 'services/push_service.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AnalyticsService.init();
  await PushService.init();
  runApp(const LombardApp());
}

class LombardApp extends StatefulWidget {
  const LombardApp({super.key});

  @override
  State<LombardApp> createState() => _LombardAppState();
}

class _LombardAppState extends State<LombardApp> {
  @override
  void initState() {
    super.initState();
    PushService.pendingPush.addListener(_onPendingPush);
  }

  @override
  void dispose() {
    PushService.pendingPush.removeListener(_onPendingPush);
    super.dispose();
  }

  /// Тап по push-уведомлению — как запуск MainActivity через PendingIntent в оригинале.
  /// Если WebView-экран уже открыт, ничего не делаем — он сам подхватит пуш
  /// через собственный listener на PushService.pendingPush.
  void _onPendingPush() {
    if (PushService.pendingPush.value == null) return;
    if (MainWebViewScreen.isOpen) return;

    final nav = navigatorKey.currentState;
    if (nav == null) return;
    nav.popUntil((route) => route.isFirst);
    nav.push(MaterialPageRoute(builder: (_) => const MainWebViewScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Санкт-Петербургский городской ломбард',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      // Следует теме телефона — как values/values-night themes.xml в оригинале.
      themeMode: ThemeMode.system,
      home: const LandingScreen(),
    );
  }
}

const _seedColor = Color(0xFFB8860B);

/// Единый стиль кнопок для всех экранов — минимальное скругление углов
/// (в оригинале кнопки платформенные, без кастомных drawable) и одинаковая
/// высота/шрифт, чтобы кнопки не расползались по стилю от экрана к экрану.
ThemeData _buildTheme(Brightness brightness) {
  final colorScheme = ColorScheme.fromSeed(seedColor: _seedColor, brightness: brightness);
  const shape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(6)));
  const minSize = Size(double.infinity, 52);
  const textStyle = TextStyle(fontSize: 16);

  return ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(shape: shape, minimumSize: minSize, textStyle: textStyle),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: shape, minimumSize: minSize, textStyle: textStyle),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: shape),
    ),
  );
}
