package com.example.elephant_frontend

import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var callAudio: CallAudio? = null

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
