import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'screens/landing_screen.dart';
import 'screens/main_webview_screen.dart';
import 'services/analytics_service.dart';
import 'services/app_log.dart';
import 'services/push_service.dart';

final navigatorKey = GlobalKey<NavigatorState>();

const _bgTokenTask = 'fcmTokenRefresh';

/// Точка входа фоновых задач WorkManager. top-level + vm:entry-point —
/// иначе tree-shaking выкинет её из release-сборки.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    await PushService.runBackgroundTokenSync();
    return true;
  });
}

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await AppLog.init();

    // Все необработанные ошибки Flutter и платформы — в журнал (и на сервер).
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      unawaited(AppLog.event('flutter_error', {
        'msg': details.exceptionAsString(),
        'lib': details.library,
        'stack': details.stack?.toString().split('\n').take(6).join(' | '),
      }));
      prevOnError?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(AppLog.event('platform_error', {
        'msg': error.toString(),
        'stack': stack.toString().split('\n').take(6).join(' | '),
      }));
      return true;
    };

    try {
      await AnalyticsService.init();
    } catch (e) {
      unawaited(AppLog.event('analytics_init_fail', {'err': '$e'}));
    }
    try {
      await PushService.init();
    } catch (e) {
      unawaited(AppLog.event('push_init_fail', {'err': '$e'}));
    }
    try {
      await Workmanager().initialize(callbackDispatcher);
      // Раз в сутки, даже если приложение не открывают: проверить токен и
      // переотправить свежий на сервер. Не выполняется только если приложение
      // именно force-stop / OEM заморозил.
      await Workmanager().registerPeriodicTask(
        'fcmTokenRefresh',
        _bgTokenTask,
        frequency: const Duration(hours: 24),
        initialDelay: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.linear,
      );
    } catch (e) {
      unawaited(AppLog.event('workmanager_init_fail', {'err': '$e'}));
    }
    runApp(const LombardApp());
  }, (error, stack) {
    unawaited(AppLog.event('zone_error', {
      'msg': error.toString(),
      'stack': stack.toString().split('\n').take(6).join(' | '),
    }));
  });
}

class LombardApp extends StatefulWidget {
  const LombardApp({super.key});

  @override
  State<LombardApp> createState() => _LombardAppState();
}

class _LombardAppState extends State<LombardApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PushService.pendingPush.addListener(_onPendingPush);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PushService.pendingPush.removeListener(_onPendingPush);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(AppLog.event('lifecycle_resumed'));
      // Если FCM-токен так и не сгенерировался — при каждом возврате на
      // передний план запускаем ещё один цикл попыток.
      PushService.retryTokenIfMissing();
      // Подтянуть из серверного ящика всё, что не дошло пушем.
      unawaited(PushService.syncInbox());
      // Дослать подтверждения доставки, не ушедшие в момент приёма пуша.
      unawaited(PushService.flushPendingAcks());
    } else if (state == AppLifecycleState.paused) {
      unawaited(AppLog.event('lifecycle_paused'));
      unawaited(AppLog.flush(force: true)); // уходим в фон — выгружаем журнал
    }
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
