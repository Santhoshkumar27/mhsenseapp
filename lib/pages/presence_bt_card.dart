import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PresenceBtCard extends StatefulWidget {
  const PresenceBtCard({
    Key? key,
    required this.isPresent,
    this.batteryPct,
    this.onOpenDevice,
  }) : super(key: key);

  /// Presence snapshot from HomePage (e.g., last known SharedPreferences).
  final bool isPresent;

  /// Battery % snapshot from HomePage (nullable until first read).
  final int? batteryPct;

  /// Optional tap handler to open/connect to the device from the card.
  final VoidCallback? onOpenDevice;

  @override
  State<PresenceBtCard> createState() => _PresenceBtCardState();
}

class _PresenceBtCardState extends State<PresenceBtCard> {
  static const MethodChannel _channel = MethodChannel('sense/ble');

  Timer? _timer;
  bool? _isPresent;     // null until first fetch
  int? _batteryPercent; // null until first fetch
  String? _batteryState;

  @override
  void initState() {
    super.initState();
    // seed from parent so the card renders immediately
    _isPresent = widget.isPresent;
    _batteryPercent = widget.batteryPct;
    _fetchOnce();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _fetchOnce());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PresenceBtCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPresent != widget.isPresent ||
        oldWidget.batteryPct != widget.batteryPct) {
      setState(() {
        _isPresent = widget.isPresent;
        _batteryPercent = widget.batteryPct;
      });
    }
  }

  Future<void> _fetchOnce() async {
    try {
      // 1) Fast path: ask native layer for cached values so UI can update instantly after reboot.
      int? cachedPct;
      bool? cachedPresent;
      try {
        cachedPresent = await _channel.invokeMethod<bool>('getPresence');
      } catch (_) {}
      try {
        cachedPct = await _channel.invokeMethod<int>('getBatteryPct');
        if (cachedPct != null && cachedPct < 0) {
          cachedPct = null; // normalize unknown sentinel
        }
      } catch (_) {}

      if (mounted && (cachedPresent != null || cachedPct != null)) {
        setState(() {
          if (cachedPresent != null) _isPresent = cachedPresent;
          if (cachedPct != null) _batteryPercent = cachedPct;
        });
      }

      // 2) Full path: fetch the latest INFO payload and override cached values if newer fields exist.
      final String jsonStr =
          await _channel.invokeMethod<String>('getBatteryInfo') ?? '{}';
      final Map<String, dynamic> obj = json.decode(jsonStr);

      // Presence: new schema has top-level `present`; legacy uses presence.present/state.
      bool? present;
      if (obj['present'] is bool) {
        present = obj['present'] as bool;
      } else if (obj['presence'] is Map) {
        final p = obj['presence'] as Map;
        if (p['present'] is bool) {
          present = p['present'] as bool;
        } else if (p['state'] is String) {
          final s = (p['state'] as String).toLowerCase();
          present = (s.contains('sit') || s.contains('occup') || s.contains('present') || s == '1' || s == 'true');
        }
      }
      // If presence still unknown, keep the cached value we already applied.

      // Battery
      int? percent;
      String? bstate;
      if (obj['battery'] is Map) {
        final b = obj['battery'] as Map;
        if (b['percent'] is num) percent = (b['percent'] as num).toInt();
        if (b['pct'] is num) percent = (b['pct'] as num).toInt();
        if (b['soc_pct'] is num) percent = (b['soc_pct'] as num).toInt();
        if (b['state'] is String) bstate = b['state'] as String;
      }
      // Backward compat: sometimes we might store at root level
      if (percent == null && obj['battery_pct'] is num) {
        percent = (obj['battery_pct'] as num).toInt();
      }

      if (!mounted) return;
      setState(() {
        if (present != null) _isPresent = present;
        if (percent != null) _batteryPercent = percent;
        if (bstate != null) _batteryState = bstate;
      });
    } catch (_) {
      // ignore; keep last known values
    }
  }

  Color _presenceColor(bool present) => present ? Colors.green : Colors.red;
  String _presenceText(bool present) => present ? 'Present' : 'Absent';

  IconData _batteryIcon(int pct) {
    if (pct >= 90) return Icons.battery_full;
    if (pct >= 80) return Icons.battery_6_bar;
    if (pct >= 60) return Icons.battery_5_bar;
    if (pct >= 40) return Icons.battery_4_bar;
    if (pct >= 20) return Icons.battery_3_bar;
    if (pct >= 10) return Icons.battery_2_bar;
    return Icons.battery_alert;
  }

  Color _batteryColor(int pct) {
    if (pct >= 80) return Colors.blue;
    if (pct >= 50) return Colors.green;
    if (pct >= 30) return Colors.amber[700]!;
    if (pct >= 10) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final present = _isPresent ?? false;
    final hasBattery = _batteryPercent != null;
    final pct = _batteryPercent ?? 0;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      elevation: 2,
      child: InkWell(
        onTap: widget.onOpenDevice,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.bluetooth, color: Theme.of(context).primaryColor),
                  const SizedBox(width: 8),
                  const Text(
                    'Presence & Battery',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  // Small live dot to hint background BLE is active
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Colors.greenAccent[400],
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _presenceColor(present),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _presenceText(present),
                    style: TextStyle(
                      color: _presenceColor(present),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (hasBattery) ...[
                    Icon(_batteryIcon(pct), color: _batteryColor(pct)),
                    const SizedBox(width: 8),
                    Text(
                      '$pct%',
                      style: TextStyle(
                        color: _batteryColor(pct),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ] else ...[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Battery …',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                  if (_batteryState != null) ...[
                    const SizedBox(width: 10),
                    Text(
                      '(${_batteryState!})',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                  if (hasBattery && pct < 10) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.warning, color: Colors.red, size: 20),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}