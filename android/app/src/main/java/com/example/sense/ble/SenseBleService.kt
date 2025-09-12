package com.example.sense.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.*
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.util.Log
import androidx.core.app.NotificationCompat
import android.content.SharedPreferences
import com.example.sense.MainActivity
import com.example.sense.R
import java.util.UUID
import kotlin.math.min
import android.annotation.SuppressLint
/**
 * SenseBleService
 * - Foreground service that maintains a single BluetoothGatt with autoConnect=true after first connect
 * - Backoff reconnect, keeps running across app restarts
 * - Discovers SensePi service & INFO characteristic; reads it periodically
 * - Stores presence JSON to SharedPreferences for instant Flutter reads
 */

class SenseBleService : Service() {

    companion object {
        private const val TAG = "SenseBleService"

        // Actions received via Intent and Dart MethodChannel bridge
        const val ACTION_START = "com.example.sense.ACTION_START"
        const val ACTION_STOP  = "com.example.sense.ACTION_STOP"

        // Notification
        private const val NOTIF_CHANNEL_ID = "sense_ble_foreground"
        private const val NOTIF_ID = 1001
        private const val NOTIF_CHANNEL_PRESENCE_ID = "sense_ble_presence"
        private const val NOTIF_ID_PRESENCE = 1002

        private const val NOTIF_CHANNEL_BATTERY_ID = "sense_ble_battery"
        private const val NOTIF_ID_BATTERY = 1003

        // Pref keys (shared with Flutter)
        private const val PREF_LAST_DEVICE_ID = "last_device_id"
        private const val PREF_PRESENCE = "presence_json"   // raw JSON string from INFO
        private const val PREF_INFO = "info_json"           // new: full INFO JSON incl. battery
        private const val PREF_PRESENCE_PRESENT = "presence_present" // boolean mirror for quick Flutter reads
        private const val PREF_BATTERY_PCT = "battery_pct_cached"

        private const val PREF_LAST_INFO_TIME = "presence_mtime"

        // SensePi UUIDs (must match Dart)
        private val UUID_SERVICE: UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        private val UUID_INFO:    UUID = UUID.fromString("6e400004-b5a3-f393-e0a9-e50e24dcca9e")
    }

    private val prefs: SharedPreferences by lazy { getSharedPreferences("sense_prefs", Context.MODE_PRIVATE) }
    private val nm by lazy { getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager }

    private var gatt: BluetoothGatt? = null
    private var deviceId: String? = null
    private var infoChar: BluetoothGattCharacteristic? = null
    private var lastPresenceSignature: String? = null
    // Battery dedupe/state
    private var lastBatteryState: String? = null
    private var lastBatteryBucket: Int? = null
    private var reconnecting = false
    private var backoffSec = 1

    private var infoHandler: Handler? = null
    private var infoPoller: Runnable? = null

    private var wakeScanHandler: Handler? = null
    private var wakeScanRunnable: Runnable? = null
    private var scanner: BluetoothLeScanner? = null
    private var scanning = false
    private var rediscoverTries: Int = 0

    private val btReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == BluetoothAdapter.ACTION_STATE_CHANGED) {
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                Log.d(TAG, "BT state change: $state")
                if (state == BluetoothAdapter.STATE_ON) {
                    if (!deviceId.isNullOrEmpty()) {
                        connectOrReconnect()
                    } else {
                        deviceId = prefs.getString(PREF_LAST_DEVICE_ID, null)
                        if (!deviceId.isNullOrEmpty()) connectOrReconnect()
                    }
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // region — Lifecycle
    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIF_ID, buildNotification(connected = false, text = "Waiting…"))
        try {
            val f = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
            registerReceiver(btReceiver, f)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to register BT receiver: ${e.message}")
        }
        Log.d(TAG, "Service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                Log.d(TAG, "ACTION_STOP")
                stopSelfSafely()
                return START_NOT_STICKY
            }
            ACTION_START, null -> {
                // may include explicit deviceId extra; else use saved one
                deviceId = intent?.getStringExtra("deviceId") ?: prefs.getString(PREF_LAST_DEVICE_ID, null)
                deviceId?.let { id ->
                    prefs.edit().putString(PREF_LAST_DEVICE_ID, id).apply()
                }
                Log.d(TAG, "ACTION_START for id=$deviceId")
                if (!deviceId.isNullOrEmpty()) {
                    connectOrReconnect()
                    startWakeScanCycle()
                } else {
                    Log.w(TAG, "No last_device_id; staying idle")
                    startWakeScanCycle()
                }
                return START_STICKY
            }
            else -> {
                return START_STICKY
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopInfoPoller()
        stopWakeScanCycle()
        infoChar = null
        try { gatt?.disconnect() } catch (_: Exception) {}
        try { gatt?.close() } catch (_: Exception) {}
        gatt = null
        try { unregisterReceiver(btReceiver) } catch (_: Exception) {}
        Log.d(TAG, "Service destroyed")
    }
    // endregion

    // region — Foreground notification
    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Foreground service channel (low importance, no sound)
            val fg = NotificationChannel(
                NOTIF_CHANNEL_ID,
                "Sense BLE (service)",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps Sense BLE connected for presence"
                setShowBadge(false)
            }
            nm.createNotificationChannel(fg)
            // Battery alert channel (default importance)
            val batt = NotificationChannel(
                NOTIF_CHANNEL_BATTERY_ID,
                "Sense battery alerts",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Notifies when device battery is low or critical"
                setShowBadge(true)
            }
            nm.createNotificationChannel(batt)
            // Presence alert channel (default importance so it alerts)
            val pres = NotificationChannel(
                NOTIF_CHANNEL_PRESENCE_ID,
                "Sense presence alerts",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Notifies when a known user is detected nearby"
                setShowBadge(true)
            }
            nm.createNotificationChannel(pres)
        }
    }

    private fun buildNotification(connected: Boolean, text: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        )
        val title = if (connected) "Sense connected" else "Sense connecting…"
        val icon = R.drawable.ic_stat_sense_ble  // your custom vector

        return NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setSmallIcon(icon)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun updateNotif(connected: Boolean, text: String) {
        nm.notify(NOTIF_ID, buildNotification(connected, text))
    }
    // endregion

    // region — GATT connect/discover/info-poll
    private fun connectOrReconnect() {
        val id = deviceId ?: return
        startWakeScanCycle()  // nudge OEM stacks even on the first connect
        if (gatt != null) {
            try { gatt?.disconnect() } catch (_: Exception) {}
            try { gatt?.close() } catch (_: Exception) {}
            gatt = null
        }
        val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        if (adapter == null) {
            Log.w(TAG, "Bluetooth adapter is null; will retry")
            scheduleReconnect(null)
            return
        }
        val device = adapter.getRemoteDevice(id)
        updateNotif(false, "Connecting to $id…")
        backoffSec = 1
        reconnecting = false

        // First attempt: direct connect
        gatt = device.connectGatt(this, false, cb, BluetoothDevice.TRANSPORT_LE)
    }
    // Wake-scan callback: nudges OEM stacks to attach when the Pi powers on
    private val scanCb = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            if (result?.device?.address?.equals(deviceId, ignoreCase = true) == true) {
                try { stopWakeScan() } catch (_: Exception) {}
                connectOrReconnect()
            }
        }
        override fun onBatchScanResults(results: MutableList<ScanResult>?) {
            results?.forEach { onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, it) }
        }
        override fun onScanFailed(errorCode: Int) {
            Log.w(TAG, "Wake scan failed: $errorCode")
        }
    }
    private val cb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            Log.d(TAG, "onConnectionStateChange status=$status state=$newState")
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                gatt = g
                rediscoverTries = 0          // reset per fresh connection
                lastPresenceSignature = null // allow next "present" to notify
                stopWakeScanCycle()
                try {
                    prefs.edit().putString(PREF_LAST_DEVICE_ID, g.device.address).apply()
                } catch (_: Exception) {}
                backoffSec = 1
                reconnecting = false
                updateNotif(true, "Connected — discovering services…")
                try {
                    g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                } catch (_: Exception) {}
                try { g.requestMtu(185) } catch (_: Exception) {}
                g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                stopInfoPoller()
                infoChar = null
                rediscoverTries = 0          // reset retries on disconnect
                lastPresenceSignature = null // clear dedupe on link loss
                writeInfoJson("""{"present":false,"user":null,"since":0}""")
                updateNotif(false, "Reconnecting…")
                startWakeScanCycle()
                scheduleReconnect(g)
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "Service discovery failed: $status")
                // Try a quick rediscover rather than full reconnect
                Handler(mainLooper).postDelayed({ try { g.discoverServices() } catch (_: Exception) {} }, 1000)
                return
            }

            // TEMP: dump the whole GATT so we can see what's actually there
            logGattTable(g)

            // Find INFO characteristic
            val svc = g.getService(UUID_SERVICE)
            val chr = svc?.getCharacteristic(UUID_INFO)
            if (chr == null) {
                // Retry a few in-place rediscoveries, then refresh cache, then (only then) reconnect
                val tries = (++rediscoverTries)
                Log.w(TAG, "Sense service/INFO not found (try=$tries); will retry")
                if (tries == 2 || tries == 4) {
                    // Android cache refresh voodoo
                    try { refreshDeviceCache(g) } catch (_: Exception) {}
                }
                if (tries < 6) {
                    Handler(mainLooper).postDelayed({ try { g.discoverServices() } catch (_: Exception) {} }, 1200L * tries)
                    return
                }
                // Give up on in-place rediscovery; do a reconnect once
                rediscoverTries = 0
                scheduleReconnect(g)
                return
            }
            // Found it
            rediscoverTries = 0
            infoChar = chr

            // Read once immediately
            try { g.readCharacteristic(chr) } catch (_: Exception) {}

            // Enable notifications; keep polling as fallback
            try { enableInfoNotifications(g) } catch (_: Exception) {}
            startInfoPoller()
            updateNotif(true, "Connected")
        }

        private fun enableInfoNotifications(g: BluetoothGatt) {
            val svc = g.getService(UUID_SERVICE) ?: return
            val chr = svc.getCharacteristic(UUID_INFO) ?: return
            g.setCharacteristicNotification(chr, true)
            // CCC descriptor for notifications
            val cccUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
            val ccc = chr.getDescriptor(cccUuid) ?: return
            ccc.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            g.writeDescriptor(ccc)
        }

        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            if (ch.uuid == UUID_INFO && status != BluetoothGatt.GATT_SUCCESS) {
                // Handle any non-success (including invalid handle) by clearing stale characteristic
                // and re-discovering services to refresh handles.
                infoChar = null
                try { g.discoverServices() } catch (_: Exception) {}
                return
            }
            if (ch.uuid == UUID_INFO && status == BluetoothGatt.GATT_SUCCESS) {
                val data = ch.value ?: ByteArray(0)
                val s = runCatching { String(data, Charsets.UTF_8) }.getOrDefault("{}")
                maybeHandleInfo(s)
            }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (ch.uuid == UUID_INFO) {
                val data = ch.value ?: ByteArray(0)
                val s = runCatching { String(data, Charsets.UTF_8) }.getOrDefault("{}")
                maybeHandleInfo(s)
            }
        }
    }

    private fun startInfoPoller() {
        stopInfoPoller()
        val handler = Handler(mainLooper)
        val runnable = object : Runnable {
            override fun run() {
                val g = gatt
                val ch = infoChar
                if (g == null || ch == null) {
                    try { gatt?.discoverServices() } catch (_: Exception) {}
                } else {
                    try {
                        g.readCharacteristic(ch)
                    } catch (e: Exception) {
                        Log.w(TAG, "read INFO failed: ${e.message}")
                    }
                }
                // re-post only if handler still active
                if (infoHandler === handler && infoPoller === this) {
                    handler.postDelayed(this, 15000L)
                }
            }
        }
        infoHandler = handler
        infoPoller = runnable
        handler.post(runnable)
    }

    private fun stopInfoPoller() {
        infoHandler?.removeCallbacksAndMessages(null)
        infoHandler = null
        infoPoller = null
    }

    private fun refreshDeviceCache(g: BluetoothGatt): Boolean {
        return try {
            val m = g.javaClass.getMethod("refresh")
            m.isAccessible = true
            val res = m.invoke(g) as Boolean
            Log.d(TAG, "refreshDeviceCache() -> $res")
            res
        } catch (e: Exception) {
            Log.w(TAG, "refreshDeviceCache() failed: ${e.message}")
            false
        }
    }

    private fun logGattTable(g: BluetoothGatt) {
        val sb = StringBuilder("GATT table:\n")
        for (svc in g.services) {
            sb.append("  SVC ${svc.uuid}\n")
            for (ch in svc.characteristics) {
                sb.append("    CH  ${ch.uuid} props=${ch.properties}\n")
            }
        }
        Log.d(TAG, sb.toString())
    }

    private fun scheduleReconnect(g: BluetoothGatt?) {
        if (reconnecting) return
        reconnecting = true
        try { g?.close() } catch (_: Exception) {}
        gatt = null
        infoChar = null

        val delayMs = (backoffSec * 1000).toLong()
        backoffSec = min(backoffSec * 2, 30)
        val id = deviceId ?: prefs.getString(PREF_LAST_DEVICE_ID, null)
        if (id.isNullOrEmpty()) {
            Log.w(TAG, "No deviceId to reconnect")
            return
        }
        val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        if (adapter == null) {
            Log.w(TAG, "Bluetooth adapter null during reconnect — will retry after backoff")
            reconnecting = false
            android.os.Handler(mainLooper).postDelayed({ scheduleReconnect(null) }, (backoffSec * 1000).toLong())
            return
        }
        val device = adapter.getRemoteDevice(id)
        android.os.Handler(mainLooper).postDelayed({
            try {
                // autoConnect so the OS keeps the link
                gatt = device.connectGatt(this, true, cb, BluetoothDevice.TRANSPORT_LE)
                updateNotif(false, "Reconnecting to $id…")
                reconnecting = false
            } catch (e: Exception) {
                Log.e(TAG, "Reconnect failed: ${e.message}")
                reconnecting = false
                scheduleReconnect(null)
            }
        }, delayMs)
    }
    // endregion

    // region — Presence persistence
    private fun writePresenceJson(json: String) {
        try {
            prefs.edit().putString(PREF_PRESENCE, json)
                .putLong(PREF_LAST_INFO_TIME, System.currentTimeMillis())
                .apply()
        } catch (_: Exception) {}
    }
    // kept for backward compatibility with older Flutter code
    // region — INFO persistence (presence + battery)
    private fun writeInfoJson(json: String) {
        try {
            prefs.edit()
                .putString(PREF_INFO, json)
                .putLong(PREF_LAST_INFO_TIME, System.currentTimeMillis())
                .apply()
        } catch (_: Exception) {}
    }
    // endregion

    private fun maybeHandleInfo(json: String) {
        // Persist full INFO first so Flutter home card can read it immediately
        writeInfoJson(json)

        // ---- Presence mirroring (legacy + new schema) ----
        // Prefer explicit boolean if present; else fall back to legacy presence.state heuristics.
        var present = false
        // Top-level present:true
        if (Regex("\"present\"\\s*:\\s*true").containsMatchIn(json)) {
            present = true
        } else {
            // Try nested presence.present:true
            val presObj = Regex("\"presence\"\\s*:\\s*\\{([^}]*)\\}").find(json)?.groupValues?.getOrNull(1)
            if (presObj != null) {
                if (Regex("\"present\"\\s*:\\s*true").containsMatchIn(presObj)) {
                    present = true
                } else {
                    val st = Regex("\"state\"\\s*:\\s*\"([^\"]+)\"").find(presObj)?.groupValues?.getOrNull(1)?.lowercase()
                    if (st != null) {
                        present = (st.contains("sit") || st.contains("occup") || st.contains("present") || st == "1" || st == "true")
                    }
                }
            }
        }
        val user  = Regex("\"user\"\\s*:\\s*\"([^\"]+)\"").find(json)?.groupValues?.getOrNull(1)
        val place = Regex("\"place\"\\s*:\\s*\"([^\"]+)\"").find(json)?.groupValues?.getOrNull(1)
        val presenceOnly = if (present) {
            "{" + "\"present\":true,\"user\":\"" + (user ?: "Someone") + "\",\"place\":\"" + (place ?: "near your SensePi") + "\"}"
        } else {
            "{\"present\":false}"
        }
        writePresenceJson(presenceOnly)
        try { prefs.edit().putBoolean(PREF_PRESENCE_PRESENT, present).apply() } catch (_: Exception) {}

        // Presence notification (dedupe on signature)
        if (present) {
            val sig = (user ?: "Someone") + "@" + (place ?: "near your SensePi")
            if (sig != lastPresenceSignature) {
                lastPresenceSignature = sig
                postPresenceNotification("${user ?: "Someone"} detected ${place ?: "near your SensePi"}")
            }
        } else {
            lastPresenceSignature = null
        }

        // ---- Battery parsing (accept several JSON shapes) ----
        // Accept either:
        //   {"battery":{"pct":30,"state":"ok"}} OR {"battery":{"percent":30}} OR {"battery":{"soc_pct":30}}
        // Or top-level: {"battery_pct":30,"battery_state":"ok"}
        var percent: Int? = null
        var state: String? = null

        // 1) Try top-level first
        Regex("\"battery_pct\"\\s*:\\s*([0-9]{1,3})")
            .find(json)?.groupValues?.getOrNull(1)?.toIntOrNull()?.let { percent = it }
        Regex("\"battery_state\"\\s*:\\s*\"([^\"]+)\"")
            .find(json)?.groupValues?.getOrNull(1)?.let { state = it }

        // 2) If not found, try inside "battery" object for pct/percent/soc_pct + state
        if (percent == null) {
            // Quick substring for the "battery" object, then scan inside it
            val battObj = Regex("\"battery\"\\s*:\\s*\\{([^}]*)\\}").find(json)?.groupValues?.getOrNull(1)
            if (battObj != null) {
                // Try pct, percent, soc_pct
                Regex("\"pct\"\\s*:\\s*([0-9]{1,3})").find(battObj)?.groupValues?.getOrNull(1)?.toIntOrNull()?.let { percent = it }
                if (percent == null) {
                    Regex("\"percent\"\\s*:\\s*([0-9]{1,3})").find(battObj)?.groupValues?.getOrNull(1)?.toIntOrNull()?.let { percent = it }
                }
                if (percent == null) {
                    Regex("\"soc_pct\"\\s*:\\s*([0-9]{1,3})").find(battObj)?.groupValues?.getOrNull(1)?.toIntOrNull()?.let { percent = it }
                }
                // Optional state
                Regex("\"state\"\\s*:\\s*\"([^\"]+)\"").find(battObj)?.groupValues?.getOrNull(1)?.let { state = it }
            }
        }

        // Normalize and notify on thresholds
        if (percent != null) {
            val p = percent!!.coerceIn(0, 100)
            // Persist battery percent in prefs
            try { prefs.edit().putInt(PREF_BATTERY_PCT, p).apply() } catch (_: Exception) {}
            val bucket = when {
                p <= 10 -> 10   // CRITICAL
                p <= 30 -> 30   // LOW
                p <= 50 -> 50
                p <= 80 -> 80
                else -> 100
            }
            if (bucket != lastBatteryBucket || state != lastBatteryState) {
                if (bucket == 30 || bucket == 10) {
                    postBatteryNotification(p, state ?: "")
                }
                lastBatteryBucket = bucket
                lastBatteryState = state
            }
        }
    }

    private fun postPresenceNotification(message: String) {
        val intent = Intent(this, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        )

        val n = NotificationCompat.Builder(this, NOTIF_CHANNEL_PRESENCE_ID)
            .setSmallIcon(R.drawable.ic_stat_sense_ble)
            .setContentTitle("Sense presence")
            .setContentText(message)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()
        nm.notify(NOTIF_ID_PRESENCE, n)
    }

    private fun postBatteryNotification(percent: Int, state: String) {
        val intent = Intent(this, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        )
        val critical = percent <= 10
        val title = if (critical) "Sense battery critical" else "Sense battery low"
        val text = "$percent% (${state})"
        val n = NotificationCompat.Builder(this, NOTIF_CHANNEL_BATTERY_ID)
            .setSmallIcon(R.drawable.ic_stat_sense_ble)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()
        nm.notify(NOTIF_ID_BATTERY, n)
    }

    private fun stopSelfSafely() {
        stopInfoPoller()
        infoHandler?.removeCallbacksAndMessages(null)
        infoHandler = null
        infoPoller = null
        try { unregisterReceiver(btReceiver) } catch (_: Exception) {}
        infoChar = null
        try { gatt?.disconnect() } catch (_: Exception) {}
        try { gatt?.close() } catch (_: Exception) {}
        gatt = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startWakeScanCycle() {
        if (wakeScanHandler == null) wakeScanHandler = Handler(mainLooper)
        val h = wakeScanHandler ?: return
        if (wakeScanRunnable != null) return
        wakeScanRunnable = Runnable {
            if (gatt == null && !deviceId.isNullOrEmpty()) {
                try { startWakeScan() } catch (_: Exception) {}
            }
            h.postDelayed(wakeScanRunnable!!, 60_000L) // every 60s
        }
        h.post(wakeScanRunnable!!)
    }

    private fun stopWakeScanCycle() {
        wakeScanRunnable?.let { wakeScanHandler?.removeCallbacks(it) }
        wakeScanRunnable = null
        try { stopWakeScan() } catch (_: Exception) {}
    }

    private fun startWakeScan() {
        if (scanning) return
        val mgr = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val ad = mgr.adapter ?: return
        val le = ad.bluetoothLeScanner ?: return
        scanner = le
        val filters = if (!deviceId.isNullOrEmpty()) {
            listOf(ScanFilter.Builder().setDeviceAddress(deviceId).build())
        } else emptyList()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
            .build()
        try {
            le.startScan(filters, settings, scanCb)
            scanning = true
            Handler(mainLooper).postDelayed({ stopWakeScan() }, 5_000L) // stop after 5s
            Log.d(TAG, "Wake scan started")
        } catch (e: Exception) {
            Log.w(TAG, "Wake scan start failed: ${e.message}")
        }
    }

    private fun stopWakeScan() {
        val le = scanner ?: return
        try { le.stopScan(scanCb) } catch (_: Exception) {}
        scanning = false
        scanner = null
        Log.d(TAG, "Wake scan stopped")
    }
}