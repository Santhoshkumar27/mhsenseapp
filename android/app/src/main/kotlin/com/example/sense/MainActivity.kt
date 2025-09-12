package com.example.sense

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.example.sense.ble.SenseBleService

class MainActivity : FlutterActivity() {
    private val CHANNEL = "sense/ble"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startBleService" -> {
                    val deviceId = call.argument<String>("deviceId")
                    val intent = Intent(this, SenseBleService::class.java).apply {
                        action = SenseBleService.ACTION_START
                        if (!deviceId.isNullOrEmpty()) {
                            putExtra("deviceId", deviceId)
                        }
                    }
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("START_FAILED", e.message, null)
                    }
                }
                "stopBleService" -> {
                    val intent = Intent(this, SenseBleService::class.java).apply {
                        action = SenseBleService.ACTION_STOP
                    }
                    try {
                        startService(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_FAILED", e.message, null)
                    }
                }
                "getBatteryInfo" -> {
                    val prefs = getSharedPreferences("sense_prefs", MODE_PRIVATE)
                    // SenseBleService stores the full INFO payload under key "info_json"
                    val info = prefs.getString("info_json", "{}")
                    result.success(info)
                }
                "getPresence" -> {
                    val prefs = getSharedPreferences("sense_prefs", MODE_PRIVATE)
                    val present = prefs.getBoolean("presence_present", false)
                    result.success(present)
                }
                "getBatteryPct" -> {
                    val prefs = getSharedPreferences("sense_prefs", MODE_PRIVATE)
                    val pct = prefs.getInt("battery_pct_cached", -1)
                    result.success(pct)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
            }
        }
    }
}
