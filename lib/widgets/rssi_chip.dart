// lib/widgets/rssi_chip.dart
import 'package:flutter/material.dart';

class RssiChip extends StatelessWidget {
  final int rssi;
  final EdgeInsetsGeometry padding;

  const RssiChip({
    super.key,
    required this.rssi,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  });

  Color _colorForRssi(int rssi) {
    if (rssi >= -60) return Colors.green;
    if (rssi >= -75) return Colors.orange;
    return Colors.red;
  }

  String _labelForRssi(int rssi) {
    if (rssi >= -60) return "Strong";
    if (rssi >= -75) return "Medium";
    return "Weak";
  }

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(
        "${_labelForRssi(rssi)} ($rssi dBm)",
        style: TextStyle(fontSize: 12, color: _colorForRssi(rssi), fontWeight: FontWeight.bold),
      ),
      backgroundColor: _colorForRssi(rssi).withOpacity(0.15),
      labelPadding: padding,
    );
  }
}