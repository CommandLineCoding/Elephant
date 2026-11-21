package com.example.elephant_frontend

import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var callAudio: CallAudio? = null
    private var locationFinder: LocationFinder? = null
    private var callScreenOpen = false
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Block capture from the first frame, before Flutter has started, so
        // the recent-apps preview never shows a chat when the person asked for
        // screen security. (shared_preferences keeps its keys under "flutter.")
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        setSecure(prefs.getBoolean("flutter.screen_security", false))
        showIfCalling(intent)
    }

    /** Blocks screenshots, screen recording and the recent-apps preview. */
    private fun setSecure(on: Boolean) {
        if (on) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        showIfCalling(intent)
    }

    /**
     * Opened from an incoming-call notification: show over the lock screen
     * and turn the screen on, so the call can be answered without unlocking.
     * The call screen turns this off again when it closes.
     */
    private fun showIfCalling(intent: Intent?) {
        val payload = intent?.getStringExtra("payload") ?: return
        if (intent.action == "SELECT_NOTIFICATION" && payload.contains("\"call\"")) {
            setOverLockScreen(true)
            // If the call has already ended, the call screen never opens; the
            // app mustn't stay usable over the lock screen.
            handler.postDelayed({ if (!callScreenOpen) setOverLockScreen(false) }, 20_000)
        }
    }

    private fun setOverLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val finder = LocationFinder(this)
        locationFinder = finder
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "elephant/location")
            .setMethodCallHandler { call, result ->
                if (call.method == "current") finder.current(result) else result.notImplemented()
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "elephant/window")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "secure" -> {
                        setSecure(call.argument<Boolean>("on") == true)
                        result.success(null)
                    }
                    // What the phone is called, for the list of signed-in devices.
                    "deviceName" -> {
                        val maker = Build.MANUFACTURER.orEmpty().replaceFirstChar { it.uppercase() }
                        val model = Build.MODEL.orEmpty()
                        result.success(
                            if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model".trim()
                        )
                    }
                    else -> result.notImplemented()
                }
            }

        val audio = CallAudio(applicationContext)
        callAudio = audio
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "elephant/call")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ring" -> audio.ring()
                    "ringback" -> audio.ringback()
                    "stopTones" -> audio.stopTones()
                    "overLockScreen" -> {
                        callScreenOpen = call.argument<Boolean>("on") == true
                        setOverLockScreen(callScreenOpen)
                    }
                    "inCall" -> {
                        val on = call.argument<Boolean>("on") == true
                        audio.setInCall(on)
                        // Volume keys set the call's volume, not the media volume.
                        volumeControlStream =
                            if (on) AudioManager.STREAM_VOICE_CALL else AudioManager.USE_DEFAULT_STREAM_TYPE
                        if (on) {
                            CallService.start(this, call.argument<String>("name") ?: "")
                        } else {
                            CallService.stop(this)
                        }
                    }
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
                result.success(null)
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        if (locationFinder?.onPermissionResult(requestCode, grantResults) != true) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    override fun onDestroy() {
        callAudio?.release()
        super.onDestroy()
    }
}
