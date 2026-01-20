class BeaconData {
  final String beaconId;
  final int? batteryLevel;
  final AccelerometerData? accelerometer;
  final int rssi;
  final DateTime timestamp;
  final String? namespaceId;
  final String? instanceId;

  BeaconData({
    required this.beaconId,
    this.batteryLevel,
    this.accelerometer,
    required this.rssi,
    required this.timestamp,
    this.namespaceId,
    this.instanceId,
  });

  static BeaconData parse(String beaconId, List<int> rawData, int rssi) {
    AccelerometerData? accel;

    if (rawData.length >= 6) {
      accel = _parseAccelerometer(rawData);
    }

    return BeaconData(
      beaconId: beaconId,
      batteryLevel: null, // Battery only in advertisement, not in notifications
      accelerometer: accel,
      rssi: rssi,
      timestamp: DateTime.now(),
    );
  }
  
  static BeaconData parseFromAdvertisement(String beaconId, List<int> advData, int rssi) {
    int? battery;
    AccelerometerData? accel;
    String? namespaceId;
    String? instanceId;

    if (advData.isEmpty) {
      return BeaconData(
        beaconId: beaconId,
        rssi: rssi,
        timestamp: DateTime.now(),
      );
    }

    final frameType = advData[0];

    // Eddystone UID frame (0x00)
    if (frameType == 0x00 && advData.length >= 18) {
      // Byte 0: Frame type (0x00)
      // Byte 1: Ranging data (Calibrated Tx power at 0m)
      // Bytes 2-11: Namespace ID (10 bytes)
      // Bytes 12-17: Instance ID (6 bytes)
      namespaceId = advData.sublist(2, 12).map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
      instanceId = advData.sublist(12, 18).map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    }
    // BeaconX Pro 3-axis ACC frame (0x60)
    else if (frameType == 0x60 && advData.length >= 14) {
      // Byte 0: Frame type (0x60)
      // Byte 1: Ranging data
      // Byte 2: Adv interval
      // Byte 3: Sampling rate
      // Byte 4: Full-scale
      // Byte 5: Motion threshold
      // Byte 6-7: X-axis
      // Byte 8-9: Y-axis
      // Byte 10-11: Z-axis
      // Byte 12-13: Battery voltage (mV)
      battery = _parseBatteryFromAdv(advData);
      accel = _parseAccelFromAdv(advData);
    }

    return BeaconData(
      beaconId: beaconId,
      batteryLevel: battery,
      accelerometer: accel,
      rssi: rssi,
      timestamp: DateTime.now(),
      namespaceId: namespaceId,
      instanceId: instanceId,
    );
  }

  static int? _parseBatteryFromAdv(List<int> advData) {
    if (advData.length < 14) return null;
    // Bytes 12-13: Battery voltage in mV
    final voltageMillivolts = (advData[12] << 8) | advData[13];
    // Convert mV to percentage (rough estimate: 3000mV = 100%, 2000mV = 0%)
    final percentage = ((voltageMillivolts - 2000) / 10).clamp(0, 100).round();
    return percentage;
  }
  
  static AccelerometerData? _parseAccelFromAdv(List<int> advData) {
    if (advData.length < 12) return null;
    
    // Bytes 6-7: X-axis, 8-9: Y-axis, 10-11: Z-axis
    final xRaw = (advData[6] << 8) | advData[7];
    final yRaw = (advData[8] << 8) | advData[9];
    final zRaw = (advData[10] << 8) | advData[11];
    
    // Use same calculation as notifications (±2g default = 1mg/digit)
    final x = _calculate12BitAccel(xRaw, 1.0);
    final y = _calculate12BitAccel(yRaw, 1.0);
    final z = _calculate12BitAccel(zRaw, 1.0);

    return AccelerometerData(x: x, y: y, z: z);
  }

  static AccelerometerData? _parseAccelerometer(List<int> data) {
    if (data.length < 6) return null;

    // BeaconX Pro protocol: 12-bit signed integer raw data
    // Bytes: [0]=ranging, [1]=interval, [2]=sampling, [3]=fullscale, [4]=threshold, [5-6]=X, [7-8]=Y, [9-10]=Z
    // But characteristic might send different format, so try direct parsing
    
    final xRaw = (data[0] << 8) | data[1];
    final yRaw = (data[2] << 8) | data[3];
    final zRaw = (data[4] << 8) | data[5];
    
    // Calculate using BeaconX Pro algorithm (12-bit, ±2g default = 1mg/digit)
    final x = _calculate12BitAccel(xRaw, 1.0);
    final y = _calculate12BitAccel(yRaw, 1.0);
    final z = _calculate12BitAccel(zRaw, 1.0);

    return AccelerometerData(x: x, y: y, z: z);
  }
  
  static double _calculate12BitAccel(int raw, double factor) {
    int shifted;
    if (raw < 0x8000) {
      shifted = raw >> 4;
    } else {
      shifted = (raw >> 4) - 0x1000;
    }
    return shifted * factor / 1000.0; // Convert mg to g
  }

  String toDisplayString() {
    final buffer = StringBuffer();
    buffer.writeln('Beacon ID: $beaconId');
    
    if (namespaceId != null) {
      buffer.writeln('Namespace: $namespaceId');
    }
    
    if (instanceId != null) {
      buffer.writeln('Instance: $instanceId');
    }
    
    if (batteryLevel != null) {
      buffer.writeln('Battery: $batteryLevel%');
    }
    
    if (accelerometer != null) {
      buffer.writeln('Accelerometer:');
      buffer.writeln('  X: ${accelerometer!.x.toStringAsFixed(2)}');
      buffer.writeln('  Y: ${accelerometer!.y.toStringAsFixed(2)}');
      buffer.writeln('  Z: ${accelerometer!.z.toStringAsFixed(2)}');
    }
    
    buffer.writeln('RSSI: $rssi dBm');
    buffer.writeln('Time: ${timestamp.toString().substring(11, 19)}');
    
    return buffer.toString();
  }
}

class AccelerometerData {
  final double x;
  final double y;
  final double z;

  AccelerometerData({
    required this.x,
    required this.y,
    required this.z,
  });

  double get magnitude => (x * x + y * y + z * z);
}
