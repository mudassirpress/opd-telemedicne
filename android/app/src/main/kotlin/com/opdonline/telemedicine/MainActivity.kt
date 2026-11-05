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
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val ringtoneChannel = "telemedicine/system_ringtone"
    private val callPlatformChannel = "telemedicine/call_platform"
    private val proximityChannel = "telemedicine/proximity"
    private var ringtonePlayer: MediaPlayer? = null
    private var proximityWakeLock: PowerManager.WakeLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (isCallIntent(intent)) {
            turnScreenOnAndShowWhenLocked()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (isCallIntent(intent)) {
            turnScreenOnAndShowWhenLocked()
        }
    }

    private fun isCallIntent(intent: Intent?): Boolean {
        if (intent == null) return false
        val action = intent.action
        val hasCallExtra = intent.hasExtra("call_id") ||
                intent.hasExtra("callId") ||
                intent.hasExtra("is_call") ||
                intent.hasExtra("incoming_call") ||
                intent.hasExtra("EXTRA_CALLKIT_INCOMING_DATA")
        return hasCallExtra ||
                action == "ACTION_CALL_INCOMING" ||
                action == "ACTION_CALL_ACCEPT"
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
        // Do not add FLAG_KEEP_SCREEN_ON unconditionally here so the device
        // can respect the user's display timeout and sleep when inactive.
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
                "setKeepScreenOn" -> {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                "turnScreenOnAndShowWhenLocked" -> {
                    turnScreenOnAndShowWhenLocked()
                    result.success(null)
                }
                "isIgnoringBatteryOptimizations" -> {
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                            data = Uri.parse("package:$packageName")
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("BATTERY_OPT_FAILED", e2.localizedMessage, null)
                        }
                    }
                }
                "openAutoStartSettings" -> {
                    val autoStartIntents = listOf(
                        Intent().setComponent(android.content.ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")),
                        Intent().setComponent(android.content.ComponentName("com.letv.android.letvsafe", "com.letv.android.letvsafe.AutobootManageActivity")),
                        Intent().setComponent(android.content.ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity")),
                        Intent().setComponent(android.content.ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.bootstart.BootStartActivity")),
                        Intent().setComponent(android.content.ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity")),
                        Intent().setComponent(android.content.ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity")),
                        Intent().setComponent(android.content.ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity")),
                        Intent().setComponent(android.content.ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity")),
                        Intent().setComponent(android.content.ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager")),
                        Intent().setComponent(android.content.ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity")),
                        Intent().setComponent(android.content.ComponentName("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity")),
                        Intent().setComponent(android.content.ComponentName("com.samsung.android.sm", "com.samsung.android.sm.ui.battery.BatteryActivity")),
                        Intent().setComponent(android.content.ComponentName("com.samsung.android.sm_cn", "com.samsung.android.sm.ui.battery.BatteryActivity")),
                        Intent().setComponent(android.content.ComponentName("com.asus.mobilemanager", "com.asus.mobilemanager.autostart.AutoStartActivity"))
                    )
                    var opened = false
                    for (intent in autoStartIntents) {
                        try {
                            if (packageManager.resolveActivity(intent, 0) != null) {
                                startActivity(intent)
                                opened = true
                                break
                            }
                        } catch (_: Exception) {}
                    }
                    if (!opened) {
                        try {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                            }
                            startActivity(intent)
                            opened = true
                        } catch (e: Exception) {
                            result.error("AUTOSTART_FAILED", e.localizedMessage, null)
                            return@setMethodCallHandler
                        }
                    }
                    result.success(opened)
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            proximityChannel
        ).setMethodCallHandler { call, result ->
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            when (call.method) {
                "enableProximitySensor" -> {
                    try {
                        if (proximityWakeLock == null) {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                                val isSupported = powerManager.isWakeLockLevelSupported(
                                    PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK
                                )
                                if (!isSupported) {
                                    result.success(false)
                                    return@setMethodCallHandler
                                }
                            }
                            proximityWakeLock = powerManager.newWakeLock(
                                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                                "telemedicine:proximity_lock"
                            )
                        }
                        if (proximityWakeLock?.isHeld == false) {
                            proximityWakeLock?.acquire()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("PROXIMITY_ENABLE_FAILED", e.localizedMessage, null)
                    }
                }
                "disableProximitySensor" -> {
                    try {
                        if (proximityWakeLock?.isHeld == true) {
                            proximityWakeLock?.release()
                        }
                        proximityWakeLock = null
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("PROXIMITY_DISABLE_FAILED", e.localizedMessage, null)
                    }
                }
                "isProximitySensorSupported" -> {
                    val isSupported = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        powerManager.isWakeLockLevelSupported(
                            PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK
                        )
                    } else {
                        true
                    }
                    result.success(isSupported)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun playDefaultRingtone() {
        stopDefaultRingtone()

        // Respect device silent and vibrate modes
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        if (audioManager != null) {
            val ringerMode = audioManager.ringerMode
            if (ringerMode == AudioManager.RINGER_MODE_SILENT || ringerMode == AudioManager.RINGER_MODE_VIBRATE) {
                return
            }
        }

        try {
            // Master ringtone: use app's bundled call_ringtoun resource
            ringtonePlayer = MediaPlayer().apply {
                setRawRingtone(this)
                applyRingtoneAudioAttributes(this)
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            try {
                ringtonePlayer?.release()
            } catch (_: Exception) {
            }
            ringtonePlayer = null

            // Fallback to system default ringtone if raw resource fails
            val ringtoneUri = RingtoneManager.getActualDefaultRingtoneUri(
                this,
                RingtoneManager.TYPE_RINGTONE
            ) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)

            if (ringtoneUri != null) {
                try {
                    ringtonePlayer = MediaPlayer().apply {
                        setDataSource(this@MainActivity, ringtoneUri)
                        applyRingtoneAudioAttributes(this)
                        isLooping = true
                        prepare()
                        start()
                    }
                } catch (_: Exception) {
                    ringtonePlayer = null
                }
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
        try {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } catch (_: Exception) {}
        try {
            if (proximityWakeLock?.isHeld == true) {
                proximityWakeLock?.release()
            }
        } catch (_: Exception) {}
        proximityWakeLock = null
        super.onDestroy()
    }
}
