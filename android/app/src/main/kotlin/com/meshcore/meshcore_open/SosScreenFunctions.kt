package com.meshcore.meshcore_open

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Putting an incoming SOS on the screen when the app is in the background.
 *
 * Android only shows a notification's full-screen alert while the phone is locked, and only with
 * the full-screen notification permission (Android 14 can take it away). With "Display over other
 * apps" allowed, the app may also open itself from the background, so the red alert appears
 * whether the phone is locked or not.
 */
class SosScreenFunctions(private val context: Context) {

    fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canUseFullScreen" -> result.success(canUseFullScreen())
                    "canShowOverApps" -> result.success(Settings.canDrawOverlays(context))
                    "openFullScreenSetting" -> result.success(openFullScreenSetting())
                    "openShowOverAppsSetting" -> result.success(
                        openSetting(Settings.ACTION_MANAGE_OVERLAY_PERMISSION),
                    )
                    "showSosAlert" -> result.success(showSosAlert(call.argument<String>("payload")))
                    else -> result.notImplemented()
                }
            }
    }

    private fun canUseFullScreen(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return manager.canUseFullScreenIntent()
    }

    private fun openFullScreenSetting(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            openSetting(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
        } else {
            openSetting(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
        }

    private fun openSetting(action: String): Boolean = try {
        context.startActivity(
            Intent(action, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        true
    } catch (e: Exception) {
        false
    }

    /** Opens the app on its alert, over the lock screen. False when Android doesn't allow it. */
    private fun showSosAlert(payload: String?): Boolean {
        if (!Settings.canDrawOverlays(context)) return false
        return try {
            context.startActivity(
                Intent(context, MainActivity::class.java)
                    .setAction(MainActivity.ACTION_SOS_ALERT)
                    .putExtra("payload", payload)
                    .addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                    ),
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    private companion object {
        const val CHANNEL = "meshcore_open/sos_screen"
    }
}
