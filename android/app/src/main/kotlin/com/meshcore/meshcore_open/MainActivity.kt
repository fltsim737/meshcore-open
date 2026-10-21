package com.meshcore.meshcore_open

import android.content.Context
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

    private companion object {
        const val ENGINE_ID = "meshcore_main"
    }
}
