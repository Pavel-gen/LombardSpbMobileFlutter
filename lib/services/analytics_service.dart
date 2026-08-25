import 'package:appmetrica_plugin/appmetrica_plugin.dart';

/// Yandex AppMetrica — тот же API-ключ, что и в оригинальном
/// LombardApplication.kt, метрики продолжают литься в тот же кабинет,
/// история не прерывается.
class AnalyticsService {
  AnalyticsService._();

  static const _apiKey = 'bff681d4-8468-4d0a-aa4e-7f9c075059cc';
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // withLogs() в оригинале был включён и в продакшен-сборке — сохраняем
    // то же поведение 1:1, а не "чиним" то, что не трогали в Android-версии.
    const config = AppMetricaConfig(_apiKey, logs: true);
    await AppMetrica.activate(config);
    await AppMetrica.enableActivityAutoTracking();

    // Общий атрибут окружения — прицепляется ко всем событиям и сессиям
    // автоматически, чтобы в кабинете AppMetrica было видно, что это данные
    // с Flutter-сборки, а не со старого нативного Android-приложения (у них
    // общий ключ проекта, и без этого атрибута данные будут неразличимы).
    await AppMetrica.putAppEnvironmentValue('app_source', 'flutter');
  }

  /// В оригинале переходы между экранами трекались автоматически через
  /// enableActivityAutoTracking(this), потому что каждый экран был отдельной
  /// Activity. Во Flutter всё приложение — одна Activity на весь навигационный
  /// стек, поэтому открытие каждого экрана репортим вручную одним и тем же
  /// событием "screen_open" с атрибутом screen — так в кабинете AppMetrica
  /// будет видно, какой конкретно экран открыли.
  static void reportScreen(String name) {
    AppMetrica.reportEventWithMap('screen_open', {'screen': name});
  }
}
