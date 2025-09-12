// lib/pages/home_page.dart
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:io' show Platform;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

import '../core/notification_permission.dart';
import './ble_connect.dart';
import './pi_device_page.dart';
import './qr_wifi_page.dart';
import './s3_session_page.dart';
import './presence_bt_card.dart';
const MethodChannel _senseBleChannel = MethodChannel('sense/ble');
Future<void> _startBleForegroundServiceHome(String? deviceId) async {
  try {
    await NotificationPermission.ensure();
    if (deviceId != null && deviceId.isNotEmpty) {
      await _senseBleChannel.invokeMethod('startBleService', {'deviceId': deviceId});
    } else {
      await _senseBleChannel.invokeMethod('startBleService');
    }
  } catch (_) {}
}

// --- Local palette for a friendlier, consistent look ---
class _AppColors {
  static const Color pink = Color(0xFFFF89C0);
  static const Color blue = Color(0xFF9AD9FF);
  static const Color lilac = Color(0xFFD7C7FF);
  static const Color mint = Color(0xFFB8F1D6);
  static const Color ink = Color(0xFF0F172A); // slate-900
  static const Color bg1 = Color(0xFFF8FAFF); // very light bluish
  static const Color bg2 = Color(0xFFF2F6FF); // soft light
  static const Color divider = Color(0x15000000); // subtle
}

/// Home page for the Sense app with a cleaner, more polished UI.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  BluetoothDevice? _lastDevice;
  bool _navigated = false; // guard to avoid double push during quick reconnect
  bool _busy = false; // shows spinner on the Connect card during quick-reconnect/scan
  bool _isPresent = false;
  int? _batteryPct;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _loadLastSnapshot() async {
    try {
      final sp = await SharedPreferences.getInstance();
      // Try multiple common keys so it works with older and newer service patches
      final present = sp.getBool('sense_last_presence') ??
                      sp.getBool('presence_present') ??
                      sp.getBool('present');
      final batt = sp.getInt('sense_last_battery_pct') ??
                   sp.getInt('battery_pct') ??
                   sp.getInt('batteryPercent');
      if (present != null || batt != null) {
        if (mounted) {
          setState(() {
            if (present != null) _isPresent = present;
            if (batt != null) _batteryPct = batt;
          });
        }
      }
    } catch (_) {
      // ignore – card will show defaults
    }
  }

  Future<void> _bootstrap() async {
    await _loadLastSnapshot();
    // Best effort: make sure we have notification permission on Android 13+
    // so our foreground BLE service can show a persistent notification.
    try {
      await NotificationPermission.ensure();
    } catch (_) {}
    // Try to jump straight back into the last device if possible.
    if (mounted) setState(() => _busy = true);
    await _attemptQuickReconnect();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _attemptQuickReconnect() async {
    try {
      if (mounted) setState(() => _busy = true);
      final sp = await SharedPreferences.getInstance();
      final lastId = sp.getString('last_device_id');
      final known = sp.getStringList('known_device_ids') ?? const <String>[];

      // Build candidate list: MRU list first; ensure lastId is included at the front if missing
      final List<String> candidates = <String>[];
      if (known.isNotEmpty) {
        candidates.addAll(known);
        if (lastId != null && lastId.isNotEmpty && !candidates.contains(lastId)) {
          candidates.insert(0, lastId);
        }
      } else if (lastId != null && lastId.isNotEmpty) {
        candidates.add(lastId);
      }
      if (candidates.isEmpty) {
        // Start service without an id so it can run & listen in background
        await _startBleForegroundServiceHome(null);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No saved devices found. Please scan to connect.')),
          );
        }
        if (mounted) setState(() => _busy = false);
        return;
      }

      // Kick the Android BLE foreground service so the OS can autoConnect in background
      await _startBleForegroundServiceHome(candidates.first);

      // Query once for devices the OS already considers "connected"
      List<BluetoothDevice> connected = const <BluetoothDevice>[];
      try {
        connected = await FlutterBluePlus.connectedDevices;
      } catch (_) {}

      // Try each candidate in MRU order until one attaches or we can navigate
      for (final id in candidates) {
        if (!mounted || _navigated) return;

        // Reuse already connected handle if present
        final alreadyConnected = connected.firstWhere(
          (d) => d.remoteId.str == id,
          orElse: () => BluetoothDevice.fromId(id),
        );

        // If it's actually already connected, navigate immediately
        final isConnected = connected.any((d) => d.remoteId.str == id);
        if (isConnected) {
          _navigated = true;
          setState(() => _lastDevice = alreadyConnected);
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => PiDevicePage(device: alreadyConnected)),
          ).then((_) {
            _navigated = false;
            if (mounted) setState(() => _busy = false);
          });
          return;
        }

        // Not connected: nudge a lightweight autoConnect and navigate if we can get a handle
        try {
          await alreadyConnected.connect(timeout: const Duration(seconds: 2), autoConnect: true);
        } catch (_) {
          // ignore races / “already connected” / transient failures
        }

        // If we reached here, we have at least a device handle; try navigating to let the device page finish robust connection
        _navigated = true;
        setState(() => _lastDevice = alreadyConnected);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => PiDevicePage(device: alreadyConnected)),
        ).then((_) {
          _navigated = false;
          if (mounted) setState(() => _busy = false);
        });
        return; // stop after first viable candidate
      }
      if (mounted) setState(() => _busy = false);
    } catch (_) {}
  }

  Future<void> _goConnect() async {
    // Make sure notification permission is granted on Android 13+
    // so our foreground BLE service can show its persistent notification.
    try {
      final ok = await NotificationPermission.ensure();
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please allow notifications so Sense can stay connected in the background.'),
            ),
          );
        }
        // Don’t proceed to the connect flow if notifications are denied
        return;
      }
    } catch (_) {
      // best-effort; proceed even if something odd happened
    }

    // Ensure BLE foreground service is started before navigating to scan page
    await _startBleForegroundServiceHome(null);

    if (mounted) setState(() => _busy = true);
    final device = await Navigator.push<BluetoothDevice?>(
      context,
      MaterialPageRoute(builder: (_) => const BleConnectPage()),
    );
    if (!mounted) return;
    if (mounted) setState(() => _busy = false);
    if (device != null) {
      setState(() => _lastDevice = device);
      Navigator.push(context, MaterialPageRoute(builder: (_) => PiDevicePage(device: device)));
    }
  }

  Future<void> _goWifiQr() async {
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const QrWifiPage()),
    );
  }

  Future<void> _goS3Session() async {
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => const S3SessionPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Sense'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_AppColors.bg1, _AppColors.bg2],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 28),
            children: [
              _HeroHeader(),
              const SizedBox(height: 20),
              const _SectionLabel(text: 'Quick actions'),
              const SizedBox(height: 10),
              PresenceBtCard(
                isPresent: _isPresent,
                batteryPct: _batteryPct,
                onOpenDevice: _goConnect,
              ),
              const SizedBox(height: 12),
              _ConnectCard(onTap: _goConnect, isBusy: _busy),
              const SizedBox(height: 12),
              _WifiQrCard(onTap: _goWifiQr),
              const SizedBox(height: 12),
              _AnalysisCard(onTap: _goS3Session),
              const SizedBox(height: 10),
              if (_lastDevice != null) ...[
                const SizedBox(height: 18),
                const _SectionLabel(text: 'Recent'),
                const SizedBox(height: 8),
                _LastDeviceCard(device: _lastDevice!, onReconnect: _goConnect),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Color(0xFF475569), // slate-600
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(child: Divider(color: _AppColors.divider, thickness: 1)),
      ],
    );
  }
}

class _HeroHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            _AppColors.pink,
            Color(0xFFB0C7FF), // soft periwinkle
            _AppColors.blue,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 18,
            offset: const Offset(0, 8),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.sensors, size: 42, color: Colors.white),
          ),
          const SizedBox(height: 12),
          const Text(
            'Sense',
            style: TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Connect to your SensePi via Bluetooth.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withOpacity(0.95),
              fontSize: 15,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectCard extends StatelessWidget {
  const _ConnectCard({required this.onTap, this.isBusy = false});
  final VoidCallback onTap;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFB8F1D6), Color(0xFFAEE9CD)],
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 14,
              offset: const Offset(0, 8),
            )
          ],
        ),
        padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.30),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.bluetooth, color: Colors.white, size: 28),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connect SensePi',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: 0.2,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Scan and link with a nearby device.',
                    style: TextStyle(
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.35),
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(6),
              child: isBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.chevron_right, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _WifiQrCard extends StatelessWidget {
  const _WifiQrCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF9AD9FF), Color(0xFF88CEFA)],
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 14,
              offset: const Offset(0, 8),
            )
          ],
        ),
        padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.30),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.qr_code, color: Colors.white, size: 28),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Generate Wi‑Fi QR',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: 0.2,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Create a QR for your SSID & password.',
                    style: TextStyle(
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.35),
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(6),
              child: const Icon(Icons.chevron_right, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _LastDeviceCard extends StatelessWidget {
  const _LastDeviceCard({required this.device, required this.onReconnect});
  final BluetoothDevice device;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final title = device.platformName.isNotEmpty
        ? device.platformName
        : device.remoteId.toString();

    return Card(
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF334155),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.history, color: Colors.white),
          ),
          title: const Text('Last device', style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: FilledButton.icon(
            onPressed: onReconnect,
            icon: const Icon(Icons.link),
            label: const Text('Open'),
          ),
        ),
      ),
    );
  }
}

class _AnalysisCard extends StatelessWidget {
  const _AnalysisCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFD7C7FF), Color(0xFFCABAF7)],
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 14,
              offset: const Offset(0, 8),
            )
          ],
        ),
        padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.30),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.analytics_outlined, color: Colors.white, size: 28),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Analysis',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: 0.2,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'View latest images, audio & metrics.',
                    style: TextStyle(
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.35),
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(6),
              child: const Icon(Icons.chevron_right, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}