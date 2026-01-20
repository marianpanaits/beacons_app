import 'package:flutter/services.dart';

class BeaconXScannerService {
  static const MethodChannel _channel = MethodChannel('com.example.beacons_app/beaconx');

  /// Scan for beacons using BeaconX SDK
  /// Returns list of beacon data with all frame types parsed
  static Future<List<Map<String, dynamic>>> scanBeacons() async {
    try {
      final List<dynamic> result = await _channel.invokeMethod('scanBeacons');
      return result.map((e) => Map<String, dynamic>.from(e)).toList();
    } on PlatformException catch (e) {
      print('BeaconX scan error: ${e.message}');
      return [];
    }
  }
  
  /// Stop scanning
  static Future<void> stopScan() async {
    try {
      await _channel.invokeMethod('stopScan');
    } on PlatformException catch (e) {
      print('Stop scan error: ${e.message}');
    }
  }
}
