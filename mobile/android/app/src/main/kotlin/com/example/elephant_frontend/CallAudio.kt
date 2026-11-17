package com.example.elephant_frontend

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Build
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * The sounds and screen behaviour around a call: the ringtone for an incoming
 * call, the ringback tone while calling, and turning the screen off when the
 * phone is held to the ear.
 */
class CallAudio(private val context: Context) {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var ringtone: Ringtone? = null
    private var toneGenerator: ToneGenerator? = null
    private var proximityLock: PowerManager.WakeLock? = null

    private val vibrator: Vibrator? by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    /** Plays the phone's ringtone and vibrates, following the ringer mode. */
    fun ring() {
        stopTones()
        val mode = audioManager.ringerMode
        if (mode == AudioManager.RINGER_MODE_NORMAL) {
            val uri = RingtoneManager.getActualDefaultRingtoneUri(context, RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ringtone = RingtoneManager.getRingtone(context, uri)?.apply {
                audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isLooping = true
                play()
            }
        }
        if (mode != AudioManager.RINGER_MODE_SILENT) {
            val pattern = longArrayOf(0, 800, 1200)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(pattern, 0)
            }
        }
    }

    /** The "ring ring" the caller hears while the other phone rings. */
    fun ringback() {
        stopTones()
        toneGenerator = try {
            ToneGenerator(AudioManager.STREAM_VOICE_CALL, 70).apply {
                startTone(ToneGenerator.TONE_SUP_RINGTONE)
            }
        } catch (e: RuntimeException) {
            null
        }
    }

    fun stopTones() {
        ringtone?.stop()
        ringtone = null
        vibrator?.cancel()
        toneGenerator?.stopTone()
        toneGenerator?.release()
        toneGenerator = null
    }

    /** During a call, the screen turns off while the phone is at the ear. */
    fun setInCall(on: Boolean) {
        if (on) {
            if (proximityLock == null) {
                val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                if (power.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
                    proximityLock = power.newWakeLock(
                        PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "elephant:call"
                    ).apply { acquire(4 * 60 * 60 * 1000L) }
                }
            }
        } else {
            proximityLock?.let { if (it.isHeld) it.release() }
            proximityLock = null
        }
    }

    fun release() {
        stopTones()
        setInCall(false)
    }
}
