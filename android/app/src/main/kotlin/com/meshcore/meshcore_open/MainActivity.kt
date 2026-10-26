package com.meshcore.meshcore_open

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

class MainActivity : FlutterActivity() {
    /**
     * One engine for the whole process. Closing the screen (Back, or swiping the app away)
     * then leaves the app running in the background under the foreground service, connected
     * to the radio, instead of shutting it down with the activity.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val appContext = context.applicationContext
        val engine = FlutterEngine(appContext)
        MeshcoreUsbFunctions(appContext).configureFlutterEngine(engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    // An incoming SOS's full-screen alert opens the app over the lock screen with the screen
    // turned on. Only then: once the app leaves the screen it no longer shows over the lock.
    private var overLockScreen = false

    override fun onCreate(savedInstanceState: Bundle?) {
        showOverLockScreenForSos(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        showOverLockScreenForSos(intent)
    }

    override fun onStop() {
        super.onStop()
        if (!overLockScreen) return
        overLockScreen = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(false)
            setTurnScreenOn(false)
        } else {
            @Suppress("DEPRECATION")
            window.clearFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
    }

    /** The intent flutter_local_notifications gives the SOS alert (payload "sos:<key>"). */
    private fun showOverLockScreenForSos(intent: Intent?) {
        if (intent?.action != "SELECT_NOTIFICATION") return
        if (intent.getStringExtra("payload")?.startsWith("sos:") != true) return
        overLockScreen = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
    }

    private companion object {
        const val ENGINE_ID = "meshcore_main"
    }
}
