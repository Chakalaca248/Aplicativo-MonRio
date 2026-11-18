## Suppress missing class warnings for optional Flutter Deferred Components (Play Core)
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

## Preserve Attributes for Reflection, Annotations & Generic Signatures
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod, InnerClasses, LineNumberTable

## Preserve Kotlin Coroutines and Continuation classes
-keep class kotlin.coroutines.** { *; }
-keepclassmembers class kotlin.coroutines.** { *; }
-keep class kotlin.Result** { *; }

## Preserve Flutter Engine & Platform Channels
-keep class io.flutter.plugin.common.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }
-keepclassmembers class io.flutter.plugins.** { *; }

## Shared Preferences (Pigeon generated interfaces & implementations)
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep interface io.flutter.plugins.sharedpreferences.** { *; }
-keep class * implements io.flutter.plugins.sharedpreferences.** { *; }
-keepclassmembers class io.flutter.plugins.sharedpreferences.** { *; }
-keepclassmembers class * implements io.flutter.plugins.sharedpreferences.** { *; }

## Flutter Local Notifications & Gson rules
-dontwarn com.google.gson.**
-keep class com.google.gson.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keepclassmembers class * extends com.google.gson.reflect.TypeToken { *; }

-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keepclassmembers class com.dexterous.flutterlocalnotifications.** { *; }
