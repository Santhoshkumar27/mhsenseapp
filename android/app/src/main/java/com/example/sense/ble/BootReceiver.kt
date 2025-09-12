package com.example.sense.ble

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "BootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        Log.i(TAG, "onReceive action=$action")
        when (action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                Log.i(TAG, "BOOT/UPDATE completed; checking last_device_id")
                val prefs = context.getSharedPreferences("sense_prefs", Context.MODE_PRIVATE)
                val id = prefs.getString("last_device_id", null)
                if (!id.isNullOrEmpty()) {
                    try {
                        val svc = Intent(context, SenseBleService::class.java)
                            .setAction(SenseBleService.ACTION_START)
                            .putExtra("deviceId", id)
                        // Use ContextCompat.startForegroundService; service must call startForeground() promptly.
                        ContextCompat.startForegroundService(context, svc)
                        Log.i(TAG, "Started SenseBleService with deviceId=$id from action=$action")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to start SenseBleService", e)
                    }
                } else {
                    Log.i(TAG, "No last_device_id found, skipping service start")
                }
            }
            else -> {
                Log.d(TAG, "Ignoring action=$action")
            }
        }
    }
}
