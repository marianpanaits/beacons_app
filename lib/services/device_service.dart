import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DeviceService {
  static const String _deviceIdKey = 'device_id';
  
  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString(_deviceIdKey);
    
    if (deviceId == null) {
      deviceId = await _generateDeviceId();
      await prefs.setString(_deviceIdKey, deviceId);
    }
    
    return deviceId;
  }
  
  static Future<String> _generateDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    String imei = '';
    
    try {
      final androidInfo = await deviceInfo.androidInfo;
      imei = androidInfo.id;
    } catch (e) {
      imei = 'UNKNOWN';
    }
    
    final randomId = const Uuid().v4().substring(0, 8);
    return '$imei-$randomId';
  }
  
  static Future<void> resetDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_deviceIdKey);
  }
}
