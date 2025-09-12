// lib/pages/pi_device_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ble_ids.dart' as ids;
import '../core/notification_permission.dart';
/// Android foreground BLE service bridge
const MethodChannel senseBleChannel = MethodChannel('sense/ble');

Future<void> _startBleForegroundService(String? deviceId) async {
  try {
    // Ensure we have POST_NOTIFICATIONS on Android 13+ before starting a foreground service with a notification
    await NotificationPermission.ensure();
    // Start foreground BLE service; pass deviceId when available so Android can remember it
    if (deviceId != null && deviceId.isNotEmpty) {
      await senseBleChannel.invokeMethod('startBleService', {'deviceId': deviceId});
    } else {
      await senseBleChannel.invokeMethod('startBleService'); // fixed line
    }
  } catch (_) {}
}

Future<void> _stopBleForegroundService() async {
  try {
    await senseBleChannel.invokeMethod('stopBleService');
  } catch (_) {}
}

/// PiDevicePage
/// A modularized version of the earlier inline page that:
///  - Connects to a selected device
///  - Discovers the SensePi service & INFO / CTL characteristics
///  - Reads INFO
///  - Sends CTL commands (PING / NAME / ENROLL / UNENROLL / RESET)
///  - Polls RSSI and INFO (light presence poller: stops when present==true)
///
/// Notes:
///  - Uses flutter_blue_plus (no read timeout argument).
///  - For Android background reconnection/notifications, wire your
///    platform service and call those methods where marked (optional).

class PiDevicePage extends StatefulWidget {
  const PiDevicePage({super.key, required this.device});
  final BluetoothDevice device;

  @override
  State<PiDevicePage> createState() => _PiDevicePageState();
}

class _PiDevicePageState extends State<PiDevicePage> with WidgetsBindingObserver {
  StreamSubscription<BluetoothConnectionState>? _connSub;
  BluetoothConnectionState _state = BluetoothConnectionState.disconnected;

  // GATT handles
  BluetoothCharacteristic? _infoCh;
  BluetoothCharacteristic? _ctlCh;

  // UI data
  Map<String, dynamic>? _info;
  int? _rssi;

  // timers
  Timer? _rssiTimer;
  Timer? _presenceTimer;

  // developer toggle for raw JSON in the info card
  bool _devDetails = false;

  // bond/connecting
  BluetoothBondState _bond = BluetoothBondState.none;
  bool _connecting = false;

  // GATT serialization guard
  bool _gattBusy = false;

  Future<T> _runGatt<T>(Future<T> Function() op) async {
    while (_gattBusy) {
      await Future.delayed(const Duration(milliseconds: 30));
    }
    _gattBusy = true;
    try {
      return await op();
    } finally {
      _gattBusy = false;
    }
  }

  Future<List<int>> _readWithRetry(BluetoothCharacteristic chr, {int retries = 1}) async {
    return _runGatt(() async {
      int attempt = 0;
      PlatformException? last;
      while (true) {
        try {
          final v = await chr.read();
          return v;
        } on PlatformException catch (e) {
          last = e;
          final msg = (e.message ?? '').toUpperCase();
          final codeStr = (e.code).toString();
          final isTransient = msg.contains('GATT_UNLIKELY') ||
              msg.contains('GATT_INTERNAL_ERROR') ||
              msg.contains('GATT_ERROR') ||
              codeStr == '133' || codeStr == '14';
          if (attempt < retries && isTransient) {
            attempt += 1;
            await Future.delayed(const Duration(milliseconds: 350));
            continue;
          }
          rethrow;
        }
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _connSub = widget.device.connectionState.listen((s) {
      setState(() => _state = s);
      if (s == BluetoothConnectionState.connected) {
        _postConnectSetup();
      } else {
        _stopRssiTimer();
        _stopPresenceTimer();
        setState(() {
          _info = null;
          _rssi = null;
          _infoCh = null;
          _ctlCh = null;
        });
      }
    });

    widget.device.bondState.listen((b) {
      setState(() => _bond = b);
    });

    // kick off connection if not already connected
    _connect();
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _stopRssiTimer();
    _stopPresenceTimer();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause periodic work when backgrounded to save battery & avoid surprises
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _stopRssiTimer();
      _stopPresenceTimer();
      return;
    }

    // Refresh presence when app returns to foreground
    if (state == AppLifecycleState.resumed) {
      if (_state == BluetoothConnectionState.connected) {
        _readInfo();           // pull latest INFO (present/user/since)
        _startRssiTimer();     // make sure RSSI polling resumes
        _startPresenceTimer(); // resume presence polling until present == true
      }
    }
  }

  Future<void> _repairPairing() async {
    if (!Platform.isAndroid) return;
    try {
      await widget.device.disconnect();
      await Future.delayed(const Duration(milliseconds: 200));
      try {
        await widget.device.removeBond();
        await widget.device.bondState
            .firstWhere((b) => b == BluetoothBondState.none)
            .timeout(const Duration(seconds: 6));
      } catch (_) {}
      try {
        await widget.device.clearGattCache();
      } catch (_) {}

      await widget.device.createBond();
      await widget.device.bondState
          .firstWhere((b) =>
              b == BluetoothBondState.bonded ||
              b == BluetoothBondState.none)
          .timeout(const Duration(seconds: 12));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Repair failed: $e')));
      }
    }
  }

  Future<void> _connectRobust() async {
    try {
      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.isScanning
          .firstWhere((s) => s == false)
          .timeout(const Duration(seconds: 2));
    } catch (_) {}

    String _err = '';
    for (int attempt = 1; attempt <= 2; attempt++) {
      final bool fallback = (attempt == 2);
      try {
        await widget.device.connect(
          timeout: fallback
              ? const Duration(seconds: 8)
              : const Duration(seconds: 20),
          autoConnect: fallback,
        );

        await widget.device.connectionState
            .firstWhere((s) => s == BluetoothConnectionState.connected)
            .timeout(const Duration(seconds: 4));

        await _postConnectSetup();
        return;
      } catch (e) {
        _err = e.toString();
        final msg = _err.toUpperCase();
        final isTransient = msg.contains('133') ||
            msg.contains('GATT_INTERNAL_ERROR') ||
            msg.contains('GATT_ERROR') ||
            msg.contains('GATT_CONN_') ||
            msg.contains('STATUS 8') ||
            msg.contains('STATUS 62') ||
            msg.contains('STATUS 34') ||
            msg.contains('TIME OUT');

        try { await widget.device.disconnect(); } catch (_) {}
        try { await widget.device.clearGattCache(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 500));

        if (!isTransient && !fallback) {
          break;
        }
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connect failed: $_err')),
      );
    }
  }

  Future<void> _connect() async {
    if (_connecting) return;
    _connecting = true;
    if (mounted) setState(() {});

    try {
      await _connectRobust();
    } finally {
      _connecting = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _disconnect() async {
    _stopRssiTimer();
    _stopPresenceTimer();
    // Stop Android foreground BLE service when explicitly disconnecting
    if (Platform.isAndroid) {
      await _stopBleForegroundService();
    }
    try {
      await widget.device.disconnect();
      // Optional: stop foreground BLE service on Android here (already requested above)
    } catch (_) {}
  }

  Future<void> _ensureBonded() async {
    if (!Platform.isAndroid) return; // iOS bonds implicitly
    try {
      final current = await widget.device.bondState.first;
      if (current == BluetoothBondState.bonded) {
        _bond = current;
        return;
      }
      await widget.device.createBond();
      _bond = await widget.device.bondState
          .firstWhere((s) => s == BluetoothBondState.bonded || s == BluetoothBondState.none)
          .timeout(const Duration(seconds: 12));
      // Optional: start Android foreground service after bonding
    } catch (_) {
      // ignore – we may retry on secure read
    }
  }

  void _startRssiTimer() {
    _rssiTimer?.cancel();
    _rssiTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final v = await _runGatt(() => widget.device.readRssi());
        if (mounted) setState(() => _rssi = v);
      } catch (_) {}
    });
  }

  void _stopRssiTimer() {
    _rssiTimer?.cancel();
    _rssiTimer = null;
  }

  void _startPresenceTimer() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted) return;
      if (_state != BluetoothConnectionState.connected) return;
      try {
        await _readInfo();
        if (_info != null && _info!['present'] == true) {
          _stopPresenceTimer();
        }
      } catch (_) {}
    });
  }

  void _stopPresenceTimer() {
    _presenceTimer?.cancel();
    _presenceTimer = null;
  }

Future<void> _postConnectSetup() async {
    try {
      await _ensureBonded();

      // Remember last device id for quick reconnects
      try {
        final sp = await SharedPreferences.getInstance();
        await sp.setString('last_device_id', widget.device.remoteId.str);
      } catch (_) {}

      // Maintain MRU list of known device IDs (limit 5, most-recent first)
      try {
        final sp = await SharedPreferences.getInstance();
        final id = widget.device.remoteId.str;
        final list = sp.getStringList('known_device_ids') ?? <String>[];
        final filtered = list.where((e) => e != id).toList(growable: true);
        filtered.insert(0, id);
        if (filtered.length > 5) {
          filtered.removeRange(5, filtered.length);
        }
        await sp.setStringList('known_device_ids', filtered);
      } catch (_) {}

      // Start Android foreground BLE service to keep background connection alive
      if (Platform.isAndroid) {
        await _startBleForegroundService(widget.device.remoteId.str);
      }

      // Raise MTU (best effort)
      try {
        await widget.device.requestMtu(247);
      } catch (_) {}

      // Android: request high priority (best effort)
      if (Platform.isAndroid) {
        try {
          await widget.device.requestConnectionPriority(
            connectionPriorityRequest: ConnectionPriority.high,
          );
        } catch (_) {}
      }

      // Optional: clear GATT cache (best effort)
      try {
        await widget.device.clearGattCache();
      } catch (_) {}

      // Discover services
      final services = await widget.device.discoverServices();
      BluetoothService? svc;
      try {
        svc = services.firstWhere(
          (s) => s.uuid.str.toLowerCase() == ids.serviceUuid.toLowerCase(),
        );
      } catch (_) {
        svc = null;
      }

      BluetoothCharacteristic? _findChr(String uuidLower) {
        if (svc == null) return null;
        try {
          return svc!.characteristics.firstWhere(
            (c) => c.uuid.str.toLowerCase() == uuidLower,
          );
        } catch (_) {
          return null;
        }
      }

      _infoCh  = _findChr(ids.infoCharUuid.toLowerCase());
      _ctlCh   = _findChr(ids.ctlCharUuid.toLowerCase());

      await _readInfo();
      _startPresenceTimer();
    } catch (_) {}
    _startRssiTimer();
  }

  Future<void> _readInfo() async {
    if (_infoCh == null) return;

    Future<void> _doRead() async {
      final data = await _readWithRetry(_infoCh!, retries: 2);
      final s = utf8.decode(data);
      final map = jsonDecode(s) as Map<String, dynamic>;
      if (mounted) setState(() => _info = map);
    }

    try {
      await _doRead();
    } catch (e) {
      final msg = e.toString();
      final needsAuth = msg.contains('GATT_AUTH_FAIL') ||
          msg.contains('fbp-code: 137') ||
          msg.contains('Unauthorized') ||
          msg.contains('auth');
      if (needsAuth) {
        await _ensureBonded();
        try {
          await _doRead();
          return;
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('INFO read failed: $e')),
        );
      }
    }
  }

  Future<void> _sendCtl(String cmd) async {
    if (_ctlCh == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('CTL characteristic not found')),
      );
      return;
    }
    try {
      await _runGatt(() => _ctlCh!.write(utf8.encode(cmd), withoutResponse: false));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sent: $cmd')));
      }
      if (cmd.startsWith('NAME:') || cmd.startsWith('ENROLL:') || cmd.startsWith('UNENROLL:') || cmd == 'RESET') {
        await Future.delayed(const Duration(milliseconds: 350));
        await _readInfo();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('CTL write failed: $e')));
      }
    }
  }

  String _rangeLabel(int? rssi) {
    if (rssi == null) return '—';
    if (rssi >= -60) return 'Near';
    if (rssi >= -75) return 'Medium';
    return 'Far';
  }

  Future<void> _promptAlias() async {
    final c = TextEditingController(
      text: _info != null && _info!['name'] is String ? (_info!['name'] as String) : '',
    );
    final alias = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Set device alias'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(hintText: 'SensePi-XXXX or any'),
          textInputAction: TextInputAction.done,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dctx, c.text), child: const Text('Apply')),
        ],
      ),
    );
    if (alias != null && alias.trim().isNotEmpty) {
      await _sendCtl('NAME:${alias.trim()}');
    }
  }

  String _formatSince(int? ts) {
    // `since` from the Pi is seconds since epoch
    if (ts == null || ts == 0) return '—';
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000; // seconds
    final delta = nowSec - ts;
    if (delta <= 0) return 'just now';
    final mins = (delta / 60).floor();
    if (mins < 1) return 'just now';
    if (mins < 60) return '$mins min${mins == 1 ? '' : 's'} ago';
    final hrs = (mins / 60).floor();
    if (hrs < 24) return '$hrs hr${hrs == 1 ? '' : 's'} ago';
    final days = (hrs / 24).floor();
    return '$days day${days == 1 ? '' : 's'} ago';
  }

  String _batteryString(Map<String, dynamic>? info) {
    if (info == null) return '—';
    final b = info['battery'];
    if (b is Map) {
      final v = b['pct'] ?? b['soc_pct'] ?? b['percent'];
      if (v is num) return '${v.toInt()} %';
    }
    final v2 = info['battery_pct'];
    if (v2 is num) return '${v2.toInt()} %';
    return '—';
  }

  Widget _kvRow(String label, String value) {
    return Row(
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            softWrap: false,
          ),
        ),
      ],
    );
  }

  Color _statusColor(bool on, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return on ? Colors.green.shade600 : cs.error;
  }

  Widget _presenceBadge(Map<String, dynamic>? info) {
    final present = info != null && info['present'] == true;
    final txt = present ? 'Present' : 'No user';
    final bg = present ? Colors.green.withOpacity(0.12) : Colors.grey.withOpacity(0.12);
    final bd = present ? Colors.green.withOpacity(0.5) : Colors.grey.withOpacity(0.5);
    final fg = present ? Colors.green.shade700 : Colors.grey.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: bd),
      ),
      child: Text(txt, style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final connected = _state == BluetoothConnectionState.connected;
    final info = _info;

    return Scaffold(
      appBar: AppBar(
        title: Text(d.platformName.isNotEmpty ? d.platformName : d.remoteId.str),
        actions: [
          IconButton(
            onPressed: _connecting ? null : (connected ? _disconnect : _connect),
            icon: _connecting
                ? const Icon(Icons.hourglass_top)
                : Icon(connected ? Icons.link_off : Icons.link),
            tooltip: _connecting ? 'Connecting…' : (connected ? 'Disconnect' : 'Connect'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- Header Card ---
          Card(
            elevation: 3,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Theme.of(context).colorScheme.primary.withOpacity(0.08),
                    Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.14),
                  ],
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(
                      Icons.bluetooth,
                      size: 28,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.platformName.isNotEmpty ? d.platformName : d.remoteId.str,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(
                              connected ? Icons.check_circle : Icons.cancel,
                              size: 18,
                              color: _statusColor(connected, context),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                connected ? 'Connected' : 'Disconnected',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: _statusColor(connected, context),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.05),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      _rssi == null ? 'RSSI —' : 'RSSI $_rssi dBm • ${_rangeLabel(_rssi)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    fit: FlexFit.loose,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: _presenceBadge(info),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // --- Pairing / Bonding ---
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock),
              title: const Text('Pairing'),
              subtitle: Text(_bond == BluetoothBondState.bonded
                  ? 'Paired'
                  : (_bond == BluetoothBondState.bonding ? 'Pairing…' : 'Not paired')),
              trailing: Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: (_bond == BluetoothBondState.bonded || _connecting) ? null : () async {
                      await _ensureBonded();
                    },
                    child: const Text('Pair'),
                  ),
                  OutlinedButton(
                    onPressed: _connecting ? null : () async {
                      await _repairPairing();
                    },
                    child: const Text('Repair'),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          // --- SensePi INFO (pretty) ---
          Card(
            elevation: 3,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                leading: Icon(Icons.info_outline, color: Theme.of(context).colorScheme.primary),
                title: const Text(
                  'SensePi info',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  info == null
                      ? '—'
                      : (info['present'] == true
                          ? 'User ${info['user'] ?? '—'} • since ${_formatSince(info['since'] is int ? info['since'] as int : 0)}'
                          : 'Presence not detected'),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                backgroundColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.15),
                children: [
                  if (info != null) ...[
                    const SizedBox(height: 8),
                    _kvRow('Name', '${info['name'] ?? '—'}'),
                    const SizedBox(height: 6),
                    _kvRow('MAC', '${info['mac'] ?? '—'}'),
                    const SizedBox(height: 6),
                    _kvRow('Token', '${info['token'] ?? '—'}'),
                    const SizedBox(height: 6),
                    _kvRow('Present', '${info['present'] == true ? 'Yes' : 'No'}'),
                    const SizedBox(height: 6),
                    _kvRow('Battery', _batteryString(info)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: _readInfo,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Refresh'),
                        ),
                        const SizedBox(width: 12),
                        TextButton.icon(
                          onPressed: () => setState(() => _devDetails = !_devDetails),
                          icon: Icon(_devDetails ? Icons.code_off : Icons.code),
                          label: Text(_devDetails ? 'Hide raw' : 'Show raw'),
                        ),
                      ],
                    ),
                    if (_devDetails) ...[
                      const Divider(height: 24),
                      SelectableText(
                        const JsonEncoder.withIndent('  ').convert(info),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                      ),
                    ],
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'No info yet — connect and refresh.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // --- Actions ---
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: !connected ? null : () => _sendCtl('PING'),
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Send PING'),
              ),
              OutlinedButton.icon(
                onPressed: !connected ? null : _promptAlias,
                icon: const Icon(Icons.edit),
                label: const Text('Set NAME'),
              ),
              OutlinedButton.icon(
                onPressed: !connected ? null : () => _sendCtl('RESET'),
                icon: const Icon(Icons.replay),
                label: const Text('RESET'),
              ),
              FilledButton.icon(
                onPressed: !connected
                    ? null
                    : () async {
                        final alias = await showDialog<String>(
                          context: context,
                          builder: (dctx) {
                            final c = TextEditingController(
                              text: (info != null && info['user'] is String) ? (info!['user'] as String) : '',
                            );
                            return AlertDialog(
                              title: const Text('Enroll user'),
                              content: TextField(
                                controller: c,
                                decoration: const InputDecoration(hintText: 'Enter user name'),
                                textInputAction: TextInputAction.done,
                              ),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('Cancel')),
                                FilledButton(onPressed: () => Navigator.pop(dctx, c.text), child: const Text('Enroll')),
                              ],
                            );
                          },
                        );
                        if (alias != null && alias.trim().isNotEmpty) {
                          await _sendCtl('ENROLL:${alias.trim()}');
                          await Future.delayed(const Duration(milliseconds: 400));
                          await _readInfo();
                        }
                      },
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Enroll'),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // --- Connect/Disconnect ---
          FilledButton.icon(
            onPressed: _connecting ? null : (connected ? _disconnect : _connect),
            icon: _connecting
                ? const Icon(Icons.hourglass_top)
                : Icon(connected ? Icons.link_off : Icons.link),
            label: Text(_connecting ? 'Connecting…' : (connected ? 'Disconnect' : 'Connect')),
          ),
        ],
      ),
    );
  }
}

/// Tiny extension (avoid external collection imports)
extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
