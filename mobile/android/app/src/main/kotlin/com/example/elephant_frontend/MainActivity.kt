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
    private var callScreenOpen = false
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showIfCalling(intent)
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

    override fun onDestroy() {
        callAudio?.release()
        super.onDestroy()
    }
}
