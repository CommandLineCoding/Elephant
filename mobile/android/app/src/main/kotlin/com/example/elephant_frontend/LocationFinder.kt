package com.example.elephant_frontend

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Finds the phone's current location with Android's own LocationManager, so
 * the app needs no Google Play Services. Replies to Flutter with
 * {lat, lon, accuracy}, or an error code: "denied" (no permission),
 * "disabled" (location is switched off) or "unavailable" (no fix in time).
 */
class LocationFinder(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private val handler = Handler(Looper.getMainLooper())

    fun current(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "Already looking for a location", null)
            return
        }
        if (!hasPermission()) {
            pending = result
            activity.requestPermissions(
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                ),
                REQUEST_CODE,
            )
            return
        }
        find(result)
    }

    /** Returns true if the result was for this request. */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        pending = null
        if (grantResults.any { it == PackageManager.PERMISSION_GRANTED }) {
            find(result)
        } else {
            result.error("denied", "Location permission was denied", null)
        }
        return true
    }

    private fun hasPermission() =
        activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            activity.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun find(result: MethodChannel.Result) {
        val manager = activity.getSystemService(LocationManager::class.java)
        try {
            val providers = manager.getProviders(true).filter { it != LocationManager.PASSIVE_PROVIDER }
            if (providers.isEmpty()) {
                result.error("disabled", "Location is switched off", null)
                return
            }

            // A fix from the last couple of minutes is good enough.
            val cutoff = System.currentTimeMillis() - RECENT_MS
            val recent = providers
                .mapNotNull { manager.getLastKnownLocation(it) }
                .filter { it.time >= cutoff }
                .minByOrNull { it.accuracy }
            if (recent != null) {
                reply(result, recent)
                return
            }

            // The network provider is quick; GPS is the fallback.
            val provider = when {
                providers.contains(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
                providers.contains(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
                else -> providers.first()
            }

            val done = AtomicBoolean(false)
            fun finish(location: Location?) {
                if (!done.compareAndSet(false, true)) return
                handler.removeCallbacksAndMessages(null)
                if (location != null) reply(result, location)
                else result.error("unavailable", "No location found in time", null)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val cancel = CancellationSignal()
                manager.getCurrentLocation(provider, cancel, activity.mainExecutor) { finish(it) }
                handler.postDelayed({ cancel.cancel() }, TIMEOUT_MS)
            } else {
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) = finish(location)

                    @Deprecated("Deprecated in Java")
                    override fun onStatusChanged(p: String?, s: Int, e: android.os.Bundle?) {}
                    override fun onProviderEnabled(p: String) {}
                    override fun onProviderDisabled(p: String) {}
                }
                @Suppress("DEPRECATION")
                manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
                handler.postDelayed({
                    manager.removeUpdates(listener)
                    finish(null)
                }, TIMEOUT_MS)
            }
        } catch (e: SecurityException) {
            result.error("denied", "Location permission was denied", null)
        }
    }

    private fun reply(result: MethodChannel.Result, location: Location) {
        result.success(
            mapOf(
                "lat" to location.latitude,
                "lon" to location.longitude,
                "accuracy" to location.accuracy.toDouble(),
            ),
        )
    }

    companion object {
        private const val REQUEST_CODE = 7301
        private const val RECENT_MS = 2 * 60 * 1000L
        private const val TIMEOUT_MS = 20_000L
    }
}
