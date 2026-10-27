package com.opdonline.telemedicine

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val ringtoneChannel = "telemedicine/system_ringtone"
    private val callPlatformChannel = "telemedicine/call_platform"
    private var ringtonePlayer: MediaPlayer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        turnScreenOnAndShowWhenLocked()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        turnScreenOnAndShowWhenLocked()
    }

    private fun turnScreenOnAndShowWhenLocked() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            callPlatformChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canUseFullScreenIntent" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        result.success(nm.canUseFullScreenIntent())
                    } else {
                        result.success(true)
                    }
                }
                "openFullScreenIntentSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                                data = Uri.parse("package:$packageName")
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_FAILED", e.localizedMessage, null)
                        }
                    } else {
                        result.success(false)
                    }
                }
                "clearKeepScreenOn" -> {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Notification channels are created by NotificationService bootstrap
        // via flutter_local_notifications. Creating them here as well used to
        // freeze the chat channel at IMPORTANCE_HIGH before Dart could register
        // it with Importance.max — Android ignores the later upgrade. Channels
        // now have exactly one owner.

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ringtoneChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "playDefaultRingtone" -> {
                    try {
                        playDefaultRingtone()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error(
                            "RINGTONE_PLAY_FAILED",
                            e.localizedMessage,
                            null
                        )
                    }
                }
                "stopDefaultRingtone" -> {
                    stopDefaultRingtone()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun playDefaultRingtone() {
        stopDefaultRingtone()

        val ringtoneUri = RingtoneManager.getActualDefaultRingtoneUri(
            this,
            RingtoneManager.TYPE_RINGTONE
        ) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)

        try {
            ringtonePlayer = MediaPlayer().apply {
                if (ringtoneUri != null) {
                    setDataSource(this@MainActivity, ringtoneUri)
                } else {
                    // No system ringtone URI (locked-down / work profile, or a
                    // device that has never had one set): fall back to the
                    // app's own call ringtone so an incoming call can never
                    // ring silently.
                    setRawRingtone(this)
                }
                applyRingtoneAudioAttributes(this)
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            // The system URI could not be opened — use the bundled resource
            // instead of failing (which used to leave the call completely
            // silent).
            try {
                ringtonePlayer?.release()
            } catch (_: Exception) {
            }
            ringtonePlayer = null

            ringtonePlayer = MediaPlayer().apply {
                setRawRingtone(this)
                applyRingtoneAudioAttributes(this)
                isLooping = true
                prepare()
                start()
            }
        }
    }

    // Points a MediaPlayer at the app's own res/raw/call_ringtoun.mp3.
    private fun setRawRingtone(player: MediaPlayer) {
        player.setDataSource(
            this,
            android.net.Uri.parse("android.resource://" + packageName + "/" + R.raw.call_ringtoun)
        )
    }

    private fun applyRingtoneAudioAttributes(player: MediaPlayer) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
        } else {
            @Suppress("DEPRECATION")
            player.setAudioStreamType(AudioManager.STREAM_RING)
        }
    }

    private fun stopDefaultRingtone() {
        try {
            ringtonePlayer?.let { player ->
                if (player.isPlaying) {
                    player.stop()
                }
                player.release()
            }
        } finally {
            ringtonePlayer = null
        }
    }

    override fun onDestroy() {
        stopDefaultRingtone()
        super.onDestroy()
    }
}
