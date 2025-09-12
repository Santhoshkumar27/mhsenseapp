import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ble_ids.dart' as ids;

// Platform channel to start Android BLE foreground service with remembered device
const MethodChannel senseBleChannel = MethodChannel('sense/ble');
/// Simple BLE connect page for SensePi.
/// - Scans for nearby devices
/// - Highlights SensePi peripherals (by UUID / name)
/// - Lets the user tap to connect
///
/// Styling: pink + light blue, with soft cards.

class BleConnectPage extends StatefulWidget {
  const BleConnectPage({Key? key}) : super(key: key);

  @override
  State<BleConnectPage> createState() => _BleConnectPageState();
}

class _BleConnectPageState extends State<BleConnectPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final List<ScanResult> _results = [];
  bool _scanning = false;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _isScanningSub;
  DateTime _lastPress = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _scanWatchdog;
  bool _wantsScanning = false;

  DateTime _lastScanRestart = DateTime.fromMillisecondsSinceEpoch(0);

  AnimationController? _spinCtrl;

  Guid get _senseGuid => Guid(ids.serviceUuid);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _init();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _isScanningSub?.cancel();
    _wantsScanning = false;
    _stopScan(); // best-effort: stop scan before disposing
    _scanWatchdog?.cancel();
    _scanWatchdog = null;
    _spinCtrl?.stop();
    _spinCtrl?.dispose();
    _spinCtrl = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _init() async {
    // Check adapter state for quick UX feedback (optional)
    // final state = await FlutterBluePlus.adapterState.first;
    // if (state != BluetoothAdapterState.on) { ... }

    // Kick the Android BLE foreground service so it can auto-reconnect
    await _startBleService(); // uses saved last_device_id on Android side
  }

  Future<void> _startBleService([String? deviceId]) async {
    if (!Platform.isAndroid) return;
    try {
      if (deviceId != null && deviceId.isNotEmpty) {
        await senseBleChannel.invokeMethod('startBleService', {'deviceId': deviceId});
        debugPrint('[BLE] startBleService sent for $deviceId');
      } else {
        await senseBleChannel.invokeMethod('startBleService'); // Service uses saved last_device_id
        debugPrint('[BLE] startBleService sent (no deviceId; using saved one)');
      }
    } catch (e) {
    debugPrint('[BLE] startBleService failed: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start background BLE service: $e')),
      );
    }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // Pause scanning when app is backgrounded to save battery & avoid OEM throttling
      _wantsScanning = false;
      _stopScan();
    } else if (state == AppLifecycleState.resumed) {
      // Optionally resume scan if user left it on
      if (mounted && !_scanning && _results.isEmpty) {
        // Small delay to give the OS a moment after resume
        Future.delayed(const Duration(milliseconds: 250), () {
          if (mounted && !_scanning) {
            _startScan();
          }
        });
      }
    }
  }

  Future<bool> _ensureRuntimePermissions() async {
    if (!Platform.isAndroid) return true;

    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final sdk = info.version.sdkInt;

      if (sdk >= 31) {
        final statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise, // not strictly needed for central role, but safe if declared
        ].request();
        return statuses.values.every((s) => s.isGranted);
      } else {
        // Older Android path still requires location for scanning
        final loc = await Permission.locationWhenInUse.request();
        return loc.isGranted;
      }
    } catch (_) {
      // If device_info fails for any reason, fall back to requesting both sets
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
      if (statuses.values.every((s) => s.isGranted)) return true;
      final loc = await Permission.locationWhenInUse.request();
      return loc.isGranted;
    }
  }

  Future<bool> _ensureBluetoothOn() async {
    try {
      var state = await FlutterBluePlus.adapterState.first;
      if (state == BluetoothAdapterState.on) return true;
      // Try to prompt enable on Android; iOS returns `unsupported` for turnOn
      await FlutterBluePlus.turnOn();
      // Wait up to 3s for the adapter to turn on
      final ok = await FlutterBluePlus.adapterState
          .timeout(
            const Duration(seconds: 3),
            onTimeout: (sink) {
              sink.add(BluetoothAdapterState.unknown);
              sink.close();
            },
          )
          .firstWhere((s) => s == BluetoothAdapterState.on, orElse: () => BluetoothAdapterState.off);
      return ok == BluetoothAdapterState.on;
    } catch (_) {
      return false;
    }
  }

  bool _looksLikeSense(ScanResult r) {
    final adv = r.advertisementData;

    // Optional MAC lock
    if (ids.kLockToPiMac.isNotEmpty &&
        r.device.remoteId.str.toUpperCase() != ids.kLockToPiMac.toUpperCase()) {
      return false;
    }

    // Prefer ServiceData (most reliable with 31B-safe adverts)
    try {
      final sd = adv.serviceData;
      if (sd.containsKey(Guid(ids.serviceUuid))) {
        return true;
      }
    } catch (_) {}

    // If the advertiser did include ServiceUUIDs, this also works
    try {
      if (adv.serviceUuids.any(
          (g) => g.str.toLowerCase() == ids.serviceUuid.toLowerCase())) {
        return true;
      }
    } catch (_) {}

    // Fallback: name prefix
    final name = (adv.localName.isNotEmpty ? adv.localName : r.device.platformName);
    return name.startsWith('SensePi');
  }

  String _token4(ScanResult r) {
    try {
      final sd = r.advertisementData.serviceData;
      final bytes = sd[Guid(ids.serviceUuid)];
      if (bytes == null || bytes.isEmpty) return '';
      final n = min(bytes.length, 2);
      return bytes.take(n).map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    } catch (_) {
      return '';
    }
  }

  Future<void> _startScan() async {
    if (_scanning) return;

    if (!await _ensureRuntimePermissions()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bluetooth permissions not granted')),
        );
      }
      return;
    }

    if (!await _ensureBluetoothOn()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please turn on Bluetooth to scan')),
        );
      }
      return;
    }

    setState(() {
      _results.clear();
      _scanning = true;
    });
    _wantsScanning = true;

    // Keep UI in sync with platform scanning state
    _isScanningSub?.cancel();
    _isScanningSub = null;
    _isScanningSub = FlutterBluePlus.isScanning.listen((on) {
      if (mounted) setState(() => _scanning = on);
      if (!on && _wantsScanning) {
        final now = DateTime.now();
        if (now.difference(_lastScanRestart).inMilliseconds < 800) {
          return; // throttle restarts
        }
        _lastScanRestart = now;
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted && _wantsScanning && !_scanning) {
            try {
              FlutterBluePlus.startScan(
                androidScanMode: AndroidScanMode.lowLatency,
                androidUsesFineLocation: true,
                timeout: const Duration(seconds: 12),
              );
            } catch (_) {}
          }
        });
      }
    });

    // Results stream
    _scanSub ??= FlutterBluePlus.scanResults.listen((list) {
      setState(() {
        _results
          ..clear()
          ..addAll(list);
        // Debug print for first 10 scan results
        for (final r in list.take(10)) {
          final adv = r.advertisementData;
          debugPrint('[SCAN] id=${r.device.remoteId.str} '
              'name=${adv.localName.isNotEmpty ? adv.localName : r.device.platformName} '
              'uuids=${adv.serviceUuids.map((g) => g.str).toList()} '
              'rssi=${r.rssi}');
        }
        // Sense first, then RSSI
        _results.sort((a, b) {
          final aSense = _looksLikeSense(a) ? 1 : 0;
          final bSense = _looksLikeSense(b) ? 1 : 0;
          if (aSense != bSense) return bSense - aSense;
          return b.rssi.compareTo(a.rssi);
        });
      });
    });

    try {
      await FlutterBluePlus.startScan(
        androidScanMode: AndroidScanMode.lowLatency,
        androidUsesFineLocation: true,
        timeout: const Duration(seconds: 12),
      );
      // No await on isScanning here; UI listener updates _scanning
    } on PlatformException catch (e) {
      debugPrint('startScan PlatformException: ${e.code} ${e.message}');
      if (mounted) setState(() => _scanning = false);
    } catch (e) {
      debugPrint('startScan error: $e');
      if (mounted) setState(() => _scanning = false);
    }

    // Watchdog to nudge scan on OEMs that silently throttle
    _scanWatchdog?.cancel();
    _scanWatchdog = Timer.periodic(const Duration(seconds: 8), (_) async {
      if (!_wantsScanning || !mounted) return;
      final on = await FlutterBluePlus.isScanning.first;
      if (!on) {
        try {
          await FlutterBluePlus.startScan(
            androidScanMode: AndroidScanMode.lowLatency,
            androidUsesFineLocation: true,
            timeout: const Duration(seconds: 12),
          );
        } catch (_) {}
      }
    });
  }

  Future<void> _stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _wantsScanning = false;
    _lastScanRestart = DateTime.fromMillisecondsSinceEpoch(0);
    _scanWatchdog?.cancel();
    _scanWatchdog = null;
    // UI will be updated by _isScanningSub listener
  }

  Future<void> _connect(ScanResult r) async {
    final now = DateTime.now();
    if (now.difference(_lastPress).inMilliseconds < 600) return;
    _lastPress = now;

    await _stopScan();

    final d = r.device;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Connecting to ${d.platformName.isNotEmpty ? d.platformName : d.remoteId.str}…')));

    try {
      await d.connect(timeout: const Duration(seconds: 12), autoConnect: false);
      await d.connectionState.firstWhere((s) => s == BluetoothConnectionState.connected);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Connected!')));
      // Tell Android service to remember this device and auto-reconnect later
      await _startBleService(d.remoteId.str);
      // (Optional) single discover to validate Sense service; non-fatal if it fails
      try {
        final svcs = await d.discoverServices();
        final ok = svcs.any((s) => s.uuid.str.toLowerCase() == ids.serviceUuid.toLowerCase());
        if (!ok) {
          debugPrint('[BLE] Sense service not found on first discover; continuing (service will retry).');
        }
      } catch (_) {}
      // Persist last_device_id and update MRU known_device_ids
      try {
        final sp = await SharedPreferences.getInstance();
        final id = d.remoteId.str;
        await sp.setString('last_device_id', id);
        final list = sp.getStringList('known_device_ids') ?? <String>[];
        final filtered = list.where((e) => e != id).toList(growable: true);
        filtered.insert(0, id);
        if (filtered.length > 5) {
          filtered.removeRange(5, filtered.length);
        }
        await sp.setStringList('known_device_ids', filtered);
      } catch (_) {}
      Navigator.of(context).pop(d); // return the connected device to caller
    } catch (e) {
      // Try background autoConnect as a fallback
      try {
        await d.connect(timeout: const Duration(seconds: 2), autoConnect: true);
        if (!mounted) return;
        // We may not be fully "connected" yet, but we can still seed the Android service
        await _startBleService(d.remoteId.str);
        // Persist last_device_id and update MRU known_device_ids (fallback path)
        try {
          final sp = await SharedPreferences.getInstance();
          final id = d.remoteId.str;
          await sp.setString('last_device_id', id);
          final list = sp.getStringList('known_device_ids') ?? <String>[];
          final filtered = list.where((e) => e != id).toList(growable: true);
          filtered.insert(0, id);
          if (filtered.length > 5) {
            filtered.removeRange(5, filtered.length);
          }
          await sp.setStringList('known_device_ids', filtered);
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reconnecting in background…')));
        Navigator.of(context).pop(d);
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Connect failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect to Sense'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
            child: Row(
              children: [
                const Icon(Icons.bluetooth, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _scanning ? 'Scanning for SensePi…' : 'Find your SensePi',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _scanning
                            ? 'Keep Bluetooth on. This may take a few seconds.'
                            : 'Tap scan to discover nearby devices.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _scanning ? _stopScan : _startScan,
                  icon: RotationTransition(
                    turns: _scanning && _spinCtrl != null ? _spinCtrl! : const AlwaysStoppedAnimation(0),
                    child: Icon(_scanning ? Icons.autorenew : Icons.search),
                  ),
                  label: Text(_scanning ? 'Stop' : 'Scan'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _results.isEmpty
                ? const Center(child: Text('No devices found yet'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      final looksSense = _looksLikeSense(r);
                      final token4 = looksSense ? _token4(r) : '';
                      final name = r.advertisementData.localName.isNotEmpty
                          ? r.advertisementData.localName
                          : (r.device.platformName.isNotEmpty ? r.device.platformName : r.device.remoteId.str);

                      return Card(
                        elevation: looksSense ? 2 : 0.5,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: ListTile(
                          leading: Icon(
                            looksSense ? Icons.sensors : Icons.devices_other,
                            color: looksSense ? Theme.of(context).colorScheme.primary : null,
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            looksSense && token4.isNotEmpty
                                ? 'RSSI ${r.rssi} dBm  •  Sense $token4'
                                : 'RSSI ${r.rssi} dBm',
                          ),
                          trailing: FilledButton.tonal(
                            onPressed: () => _connect(r),
                            child: const Text('Connect'),
                          ),
                          onTap: () => _connect(r),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
