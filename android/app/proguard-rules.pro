# Правила R8/ProGuard. Сейчас минификация ВЫКЛЮЧЕНА (см. build.gradle.kts).
# Этот файл — заготовка на момент включения (`isMinifyEnabled = true`) в 2.0.1+.

# --- Flutter ---
# io.flutter.** держит сам Flutter Gradle Plugin автоматически.
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# --- Firebase / Google Play Services (FCM) ---
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# --- flutter_local_notifications ---
-keep class com.dexterous.** { *; }

# --- workmanager (фоновый воркер) ---
-keep class dev.fluttercommunity.workmanager.** { *; }
-keep class androidx.work.** { *; }

# --- AppMetrica ---
-keep class io.appmetrica.** { *; }
-dontwarn io.appmetrica.**

# --- WebView JS-интерфейсы ---
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# --- Play Core (Flutter deferred components — не используем, глушим предупреждения) ---
-dontwarn com.google.android.play.core.**

-keepattributes Signature, *Annotation*, SourceFile, LineNumberTable
