

/// Utility helpers for BLE UUID handling.
/// Converts between 16‑bit/32‑bit short forms and 128‑bit full UUIDs,
/// and provides some convenience functions.

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

/// Base Bluetooth SIG 128‑bit UUID suffix.
const String _bleBaseUuidSuffix = '-0000-1000-8000-00805f9b34fb';

/// Convert a 16‑bit assigned number (e.g. 0x2A37) to a full UUID string.
String uuidFrom16(int shortUuid) {
  final hex = shortUuid.toRadixString(16).padLeft(4, '0').toLowerCase();
  return '0000$hex$_bleBaseUuidSuffix';
}

/// Convert a 32‑bit assigned number to a full UUID string.
String uuidFrom32(int shortUuid) {
  final hex = shortUuid.toRadixString(16).padLeft(8, '0').toLowerCase();
  return '$hex$_bleBaseUuidSuffix';
}

/// Parse a [Uuid] object from a string.
Uuid uuidFromString(String uuid) => Uuid.parse(uuid);

/// Convenience: compare two UUID strings ignoring case.
bool uuidEquals(String a, String b) => a.toLowerCase() == b.toLowerCase();

/// Convenience: shorten a UUID for display (returns first 8 chars).
String shortUuid(String uuid) => uuid.length > 8 ? uuid.substring(0, 8) : uuid;