# ChowSA R8 / ProGuard keep rules for Play-Store release builds.
#
# Targeted keep rules — defaults from proguard-android-optimize.txt handle the
# core Android + Flutter engine. Below are the plugin-specific keeps that the
# release build needs so the AAB doesn't crash on launch after R8 strips
# reflectively-loaded classes.

# ── Flutter ────────────────────────────────────────────────────────────────
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }

# ── Kotlin (coroutines + reflection used by Supabase + Gemini SDK) ─────────
-keep class kotlin.Metadata { *; }
-keepclasseswithmembers class * {
    @kotlin.Metadata <fields>;
}
-keep class kotlinx.coroutines.** { *; }
-keepnames class kotlinx.serialization.** { *; }

# ── flutter_local_notifications (reflective broadcast + scheduler) ─────────
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class * extends android.app.Application { *; }
-keep class android.app.AlarmManager { *; }

# ── geolocator (reflective service binding on some devices) ────────────────
-keep class com.baseflow.geolocator.** { *; }

# ── image_picker / camera FileProvider ────────────────────────────────────
-keep class io.flutter.plugins.imagepicker.** { *; }

# ── Supabase realtime + GoTrue serializers (Kotlin data classes via reflection)
-keep class io.github.jan.supabase.** { *; }

# ── google_generative_ai (response_mime_type + structured JSON deserialise) ─
-keep class com.google.ai.client.generativeai.** { *; }

# ── pdf / printing ────────────────────────────────────────────────────────
-keep class com.dpdf.android.** { *; }
-dontwarn com.dpdf.**

# ── url_launcher (Android intent receivers) ───────────────────────────────
-keep class io.flutter.plugins.urllauncher.** { *; }

# ── in_app_purchase (Play Billing client + listener reflection) ────────────
-keep class io.flutter.plugins.inapppurchase.** { *; }
-keep class com.android.billingclient.api.** { *; }
-keep class com.android.vending.billing.** { *; }
-dontwarn com.android.billingclient.**

# ── firebase_crashlytics (NDK symbol upload + reflective metadata) ─────────
-keep class com.google.firebase.crashlytics.** { *; }
-dontwarn com.google.firebase.crashlytics.**
-keepattributes SourceFile,LineNumberTable,LocalVariableTable

# ── google_mobile_ads (AdMob reflective ad-format loaders + UMP) ──────────
-keep class com.google.android.gms.ads.** { *; }
-keep class com.google.android.ump.** { *; }
-dontwarn com.google.android.gms.ads.**
-dontwarn com.google.android.ump.**

# ── in_app_review (Play Core API) ─────────────────────────────────────────
-keep class com.google.android.play.core.review.** { *; }
-dontwarn com.google.android.play.core.review.**

# ── firebase_messaging (FCM token + background isolate dispatcher) ────────
-keep class io.flutter.plugins.firebase.messaging.** { *; }
-keep class com.google.firebase.messaging.** { *; }

# Generic — preserve enum reflection (used widely by deserialisers).
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Preserve native methods, line numbers for crash reports, and the
# attributes Play Store crash mapping needs.
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Flutter's PlayStoreDeferredComponentManager references the optional
# com.google.android.play.core.tasks.* classes for split-install support.
# ChowSA does not use deferred components, so the Play Core dependency
# isn't on the classpath. Tell R8 the references are intentional and
# don't fail the build over them.
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-keep class io.flutter.embedding.engine.deferredcomponents.** { *; }
