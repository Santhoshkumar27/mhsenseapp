// lib/widgets/device_avatar.dart
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../widgets/rssi_chip.dart';
import '../core/ble_ids.dart';
import '../core/uuid_helpers.dart';

/// A reusable card to display a BLE ScanResult with a friendly layout.
///
/// Shows:
///  - Device name (or fallback)
///  - ID and RSSI
///  - A colored RSSI chip
///  - A SensePi badge when it advertises the Sense service
/// Tapping the card triggers [onTap].
class DeviceAvatarCard extends StatelessWidget {
  final ScanResult result;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;
  final IconData icon;

  const DeviceAvatarCard({
    super.key,
    required this.result,
    this.onTap,
    this.margin = const EdgeInsets.symmetric(vertical: 6),
    this.padding = const EdgeInsets.all(12),
    this.icon = Icons.devices_other,
  });

  bool _isSensePi(ScanResult r) {
    try {
      final adv = r.advertisementData;
      final hasServiceDataKey =
          adv.serviceData.containsKey(senseGuid) ||
          adv.serviceData.containsKey(senseGuidAlt);
      if (hasServiceDataKey) return true;

      if (adv.serviceUuids.any((g) => g.str.toLowerCase() == serviceUuid.toLowerCase())) {
        return true;
      }
      return (r.device.name).startsWith('SensePi');
    } catch (_) {
      return (r.device.name).startsWith('SensePi');
    }
  }

  String _token4FromResult(ScanResult r) {
    try {
      final sd = r.advertisementData.serviceData;
      final bytes = sd[senseGuid] ?? sd[senseGuidAlt];
      if (bytes == null || bytes.isEmpty) return '';
      final n = bytes.length < 2 ? bytes.length : 2; // show first 2 bytes
      return bytes.take(n).map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    } catch (_) {
      return '';
    }
  }

  String _displayName(ScanResult r) {
    final adv = r.advertisementData.localName;
    final platform = r.device.platformName;
    final id = r.device.remoteId.str;
    final fallback = 'Device ${id.substring(id.length - 5)}';
    if (adv.isNotEmpty) return adv;
    if (platform.isNotEmpty) return platform;
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final looksLikePi = _isSensePi(result);
    final token4 = _token4FromResult(result);
    final id = result.device.remoteId.str;
    final display = _displayName(result);

    return Card(
      margin: margin,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: padding,
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: Colors.lightBlue.shade100,
                child: const Icon(Icons.devices_other, color: Colors.pinkAccent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // If this looks like the Pi and the adv name is empty, show a friendly label
                      (looksLikePi && result.advertisementData.localName.isEmpty)
                          ? 'SensePi (BLE)'
                          : display,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$id  •  RSSI: ${result.rssi} dBm',
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              RssiChip(rssi: result.rssi),
              if (looksLikePi) ...[
                const SizedBox(width: 8),
                Chip(label: Text('SensePi${token4.isNotEmpty ? " $token4" : ""}')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}