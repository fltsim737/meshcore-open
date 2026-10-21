# ONNX Runtime looks its Java classes up from native code with FindClass /
# GetMethodID, by literal name. R8 renames them, the lookup returns null, and
# the process dies with:
#
#   JNI DETECTED ERROR IN APPLICATION: java_class == null
#     at art::JNI<false>::GetMethodID
#     from convertToTensorInfo -> Java_ai_onnxruntime_OrtSession_run
#
# It is a hard SIGABRT in native code, so nothing in Dart can catch it: the app
# vanishes the moment the codec touches the model. Keep the whole package —
# these are the types the native layer reflects on to build tensors and read
# results back.
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# The Flutter plugin's platform-channel handler, reached the same way.
-keep class com.masicai.flutteronnxruntime.** { *; }
-dontwarn com.masicai.flutteronnxruntime.**

# shared_preferences_android 2.5 calls its Kotlin suspend functions from Dart
# through JNI (package:jni), looking each one up by its full JVM signature,
# and package:jni resolves Kotlin classes by name to drive them: the
# coroutine machinery, Result (and Result$Failure) and Unit. These are all
# the kotlin/ names the jni 1.1 and shared_preferences_android 2.5 Dart
# bindings look up. R8 renames
# those (Continuation became m3.c), the lookups fail, and
# PrefsManager.initialize() throws
#
#   NoSuchMethodError: no non-static method
#     "Lio/flutter/plugins/sharedpreferences/SharedPreferencesApiRegistrar;.getAll(
#      Ljava/lang/String;Ljava/util/List;Lkotlin/coroutines/Continuation;)..."
#
# before runApp, so the app sits on the launch screen forever.
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class kotlin.coroutines.** { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }
-dontwarn io.flutter.plugins.sharedpreferences.**
