/// BLE UUIDs used by the app. Must match the Raspberry Pi peripheral.
///
/// If you change these, also update the Pi script (pible.py) to the same values.
library ble_ids;

/// Primary service UUID (SensePi)
const String serviceUuid   = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";

/// Characteristics:
/// - helloCharUuid : plain READ — small "Hello" string (sanity check)
/// - infoCharUuid  : ENCRYPT-READ — JSON blob with {name, mac, token, present, user, since}
/// - ctlCharUuid   : ENCRYPT-WRITE (with response) — ASCII commands (PING, NAME:<alias>, ENROLL:<name>, UNENROLL:<mac>, RESET)
const String helloCharUuid = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
const String infoCharUuid  = "6e400004-b5a3-f393-e0a9-e50e24dcca9e";
const String ctlCharUuid   = "6e400005-b5a3-f393-e0a9-e50e24dcca9e";

/// Optional: lock to one specific Pi MAC ('' means accept any)
/// Example: 'B8:27:EB:AB:6F:A3'
const String kLockToPiMac = '';