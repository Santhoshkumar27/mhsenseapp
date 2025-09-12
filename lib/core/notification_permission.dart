import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

class NotificationPermission {
  /// Ensures notification permission is granted on Android 13+.
  /// On lower versions or non-Android platforms, it no-ops.
  static Future<bool> ensure() async {
    if (!Platform.isAndroid) {
      return true;
    }
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt < 33) {
      return true;
    }
    final status = await Permission.notification.status;
    if (status.isGranted) {
      return true;
    }
    final result = await Permission.notification.request();
    return result.isGranted;
  }
}