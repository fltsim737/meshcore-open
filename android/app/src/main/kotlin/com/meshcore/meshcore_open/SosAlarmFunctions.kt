package com.meshcore.meshcore_open

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The incoming SOS alarm, played by the app rather than by its notification, so that it sounds
 * when a notification sound wouldn't:
 *
 * - Silent or vibrate mode: it plays as alarm audio, which the ringer switch doesn't mute, with
 *   the alarm volume turned up for the alert.
 * - Another app holding the audio (music, a video, a Discord call): it takes the audio focus
 *   exclusively, so that app pauses or quietens until the alarm stops.
 * - Do Not Disturb: with Do Not Disturb access, if the current mode would block alarms it lets
 *   alarms through for the alert ("Alarms only"), and puts the person's mode back afterwards.
 * - A phone call: Android only lets other audio play quietly during a call, so it also vibrates
 *   hard, and the full-screen alert does the rest.
 *
 * Everything it changes is put back by [stop].
 */
class SosAlarmFunctions(private val context: Context) {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val notifications =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val alarmAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private var player: MediaPlayer? = null
    private var focus: Any? = null   // AudioFocusRequest from Android 8
    private val focusListener = AudioManager.OnAudioFocusChangeListener { }   // keeps sounding
    private var savedVolume: Int? = null
    private var savedFilter: Int? = null

    fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> result.success(start(call.argument<String>("sound") ?: "sos_alarm_morse"))
                    "stop" -> { stop(); result.success(true) }
                    "hasDndAccess" -> result.success(notifications.isNotificationPolicyAccessGranted)
                    "openDndSetting" -> result.success(openDndSetting())
                    else -> result.notImplemented()
                }
            }
    }

    /** True when the alarm is playing. False and nothing changed if it couldn't start. */
    private fun start(sound: String): Boolean {
        if (player != null) return true
        val res = context.resources.getIdentifier(sound, "raw", context.packageName)
        if (res == 0) return false
        val p = try {
            MediaPlayer().apply {
                setAudioAttributes(alarmAttributes)
                context.resources.openRawResourceFd(res).use {
                    setDataSource(it.fileDescriptor, it.startOffset, it.length)
                }
                isLooping = true
                prepare()
            }
        } catch (e: Exception) {
            return false
        }
        letAlarmsThrough()
        turnAlarmVolumeUp()
        takeAudioFocus()
        p.start()
        player = p
        vibrate()
        return true
    }

    private fun stop() {
        player?.let {
            try { it.stop() } catch (_: Exception) { }
            it.release()
        }
        player = null
        vibrator()?.cancel()
        focus?.let {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audio.abandonAudioFocusRequest(it as AudioFocusRequest)
            } else {
                @Suppress("DEPRECATION")
                audio.abandonAudioFocus(focusListener)
            }
        }
        focus = null
        savedVolume?.let {
            try { audio.setStreamVolume(AudioManager.STREAM_ALARM, it, 0) } catch (_: Exception) { }
        }
        savedVolume = null
        savedFilter?.let {
            try { notifications.setInterruptionFilter(it) } catch (_: Exception) { }
        }
        savedFilter = null
    }

    /** Do Not Disturb set to block alarms ("Total silence", or priority without alarms). */
    private fun letAlarmsThrough() {
        if (!notifications.isNotificationPolicyAccessGranted) return
        val filter = notifications.currentInterruptionFilter
        val blocks = when (filter) {
            NotificationManager.INTERRUPTION_FILTER_NONE -> true
            NotificationManager.INTERRUPTION_FILTER_PRIORITY ->
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                    notifications.notificationPolicy.priorityCategories and
                    NotificationManager.Policy.PRIORITY_CATEGORY_ALARMS == 0
            else -> false
        }
        if (!blocks) return
        try {
            notifications.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALARMS)
            savedFilter = filter
        } catch (_: Exception) { }
    }

    private fun turnAlarmVolumeUp() {
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_ALARM)
        val now = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        if (now >= max) return
        try {
            audio.setStreamVolume(AudioManager.STREAM_ALARM, max, 0)
            savedVolume = now
        } catch (_: Exception) { }
    }

    private fun takeAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                .setAudioAttributes(alarmAttributes)
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            audio.requestAudioFocus(request)
            focus = request
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(focusListener, AudioManager.STREAM_ALARM,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            focus = focusListener
        }
    }

    private fun vibrator(): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }

    // S-O-S in long and short buzzes, over and over
    private fun vibrate() {
        val v = vibrator() ?: return
        if (!v.hasVibrator()) return
        val pattern = longArrayOf(0, 200, 150, 200, 150, 200, 400, 600, 150, 600, 150, 600, 400,
            200, 150, 200, 150, 200, 1200)
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            v.vibrate(VibrationEffect.createWaveform(pattern, 0), alarmAttributes)
        } else {
            v.vibrate(pattern, 0, alarmAttributes)
        }
    }

    private fun openDndSetting(): Boolean = try {
        context.startActivity(
            Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        true
    } catch (e: Exception) {
        false
    }

    private companion object {
        const val CHANNEL = "meshcore_open/sos_alarm"
    }
}
