import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Beacon Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ScanScreen(),
    );
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  static const String _beaconServiceUuid = 'feab';

  List<ScanResult> _scanResults = [];
  final Map<String, BeaconFrames> _beaconFrames = {};
  bool _isScanning = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  @override
  void initState() {
    super.initState();
    FlutterBluePlus.setLogLevel(LogLevel.info);
    _initBluetooth();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _initBluetooth() async {
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.location.request();
    _startScan();
  }

  Future<void> _startScan() async {
    if (_isScanning) return;
    setState(() => _isScanning = true);

    try {
      await FlutterBluePlus.startScan();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          if (_isBeacon(result)) {
            final deviceId = result.device.remoteId.toString();
            _beaconFrames[deviceId] ??= BeaconFrames(deviceId);

            final ad = result.advertisementData;

            debugPrint('--- ${result.device.remoteId} RSSI=${result.rssi}');
            debugPrint('serviceUuids: ${ad.serviceUuids.map((g) => g.str).toList()}');
            debugPrint('serviceData keys: ${ad.serviceData.keys.map((g) => g.str).toList()}');
            debugPrint('manufacturerData keys: ${ad.manufacturerData.keys.toList()}');

            for (final entry in result.advertisementData.serviceData.entries) {
              if (entry.key.toString().toLowerCase().contains(_beaconServiceUuid)) {
                _parseFrame(deviceId, entry.value, result.rssi);
              }
            }
          }
        }
        setState(() => _scanResults = results.where(_isBeacon).toList());
      });
    } catch (e) {
      debugPrint('Scan error: $e');
    }
  }

  void _parseFrame(String deviceId, List<int> data, int rssi) {
    if (data.isEmpty) return;
    final frames = _beaconFrames[deviceId]!;
    frames.rssi = rssi;
    frames.lastSeen = DateTime.now();

    // Debug logging
    debugPrint('📊 Frame type: 0x${data[0].toRadixString(16).padLeft(2, '0')}');
    debugPrint('📊 Raw data (${data.length} bytes): ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');

    switch (data[0]) {
      case 0x00: // UID
        if (data.length >= 18) {
          frames.namespaceId = data.sublist(2, 12).map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
          frames.instanceId = data.sublist(12, 18).map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
        }
        break;
      case 0x20: // TLM
        if (data.length >= 14) {
          frames.batteryVoltage = (data[2] << 8) | data[3];
          final tempInt = (data[4] << 16) | (data[5] << 8);
          frames.temperature = tempInt.toSigned(24) / 256.0;
          frames.advCount = (data[6] << 24) | (data[7] << 16) | (data[8] << 8) | data[9];
          frames.runningTime = (data[10] << 24) | (data[11] << 16) | (data[12] << 8) | data[13];
        }
        break;
      case 0x60: // Accelerometer (BeaconX custom frame)
        if (data.length >= 21) {
          // Per BeaconX doc Table 9: Customized-3-axis ACC advertisement
          // Byte 1: Ranging data (Tx power at specific distance)
          // Byte 2: Adv interval (unit: 100ms/digit)
          // Byte 3: Sampling rate (0x01=10Hz, 0x02=25Hz, etc.)
          // Byte 4: Full-scale (0x00=±2g, 0x01=±4g, etc.)
          // Byte 5: Motion threshold (unit: 0.1g/digit)
          // Bytes 6-7: X-axis raw data
          // Bytes 8-9: Y-axis raw data
          // Bytes 10-11: Z-axis raw data
          // Bytes 12-13: Battery voltage
          // Byte 14: RFU (Reserved)
          // Bytes 15-20: MAC address

          frames.rangingData = data[1].toSigned(8);
          frames.advInterval = data[2] * 100; // Convert to milliseconds
          frames.samplingRate = data[3];
          frames.fullScale = data[4];
          frames.motionThreshold = data[5] * 0.1; // Convert to g

          final xRaw = (data[6] << 8) | data[7];
          final yRaw = (data[8] << 8) | data[9];
          final zRaw = (data[10] << 8) | data[11];
          frames.batteryVoltage = (data[12] << 8) | data[13];

          frames.accelX = _decode12BitSignedMg(xRaw);
          frames.accelY = _decode12BitSignedMg(yRaw);
          frames.accelZ = _decode12BitSignedMg(zRaw);

          // Parse MAC address (bytes 15-20)
          if (data.length >= 21) {
            frames.beaconMac =
                data.sublist(15, 21).map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');
          }

          debugPrint(
              '🔋 Battery: ${frames.batteryVoltage} mV (${_calculateBatteryPercentage(frames.batteryVoltage)}%)');
          debugPrint('📐 ACC: X=${frames.accelX} mg, Y=${frames.accelY} mg, Z=${frames.accelZ} mg');
          debugPrint(
              '⚙️ Ranging: ${frames.rangingData} dBm, Interval: ${frames.advInterval} ms, Rate: ${_getSamplingRateHz(frames.samplingRate)} Hz');
          debugPrint('📏 Full-scale: ${_getFullScaleG(frames.fullScale)}g, Threshold: ${frames.motionThreshold}g');
          debugPrint('📍 Beacon MAC: ${frames.beaconMac}');
        }
        break;
      default:
        debugPrint('data[0]:: ${data[0]}');
    }
  }

  double _decode12BitSignedMg(int raw16) {
    final v12 = (raw16 >> 4) & 0x0FFF;
    final signed = (v12 & 0x800) != 0 ? v12 - 0x1000 : v12;
    return signed.toDouble();
  }

  int _calculateBatteryPercentage(int? voltage) {
    if (voltage == null) return 0;
    // Li-ion battery: 4200mV=100%, 2800mV=0% (realistic discharge curve)
    const minVoltage = 2800;
    const maxVoltage = 4200;
    int percentage = ((voltage - minVoltage) / (maxVoltage - minVoltage) * 100).round();
    return percentage.clamp(0, 100);
  }

  String _getSamplingRateHz(int? code) {
    if (code == null) return 'N/A';
    // Per BeaconX Table 13: Sampling rate comparison table
    switch (code) {
      case 0x00:
        return '1';
      case 0x01:
        return '10';
      case 0x02:
        return '25';
      case 0x03:
        return '50';
      case 0x04:
        return '100';
      default:
        return code.toString();
    }
  }

  String _getFullScaleG(int? code) {
    if (code == null) return 'N/A';
    // Per BeaconX Table 14: Full-scale comparison table
    switch (code) {
      case 0x00:
        return '±2';
      case 0x01:
        return '±4';
      case 0x02:
        return '±8';
      case 0x03:
        return '±16';
      default:
        return '±${code}';
    }
  }

  bool _isBeacon(ScanResult result) {
    // Filter to show only target beacons
    final mac = result.device.remoteId.toString().toUpperCase();
    return mac == 'D7:4F:4C:D2:4F:3B' || mac == 'ED:CF:19:48:B0:D5';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Beacon Scanner'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          if (_isScanning) const LinearProgressIndicator(),
          Expanded(
            child: _scanResults.isEmpty
                ? const Center(child: Text('Scanning for beacons...'))
                : ListView.builder(
                    itemCount: _scanResults.length,
                    itemBuilder: (context, index) {
                      final result = _scanResults[index];
                      final deviceId = result.device.remoteId.toString();
                      final frames = _beaconFrames[deviceId];

                      return Card(
                        margin: const EdgeInsets.all(8),
                        child: ExpansionTile(
                          leading: Icon(
                            Icons.bluetooth,
                            color: result.rssi > -70 ? Colors.green : Colors.orange,
                          ),
                          title: Text(
                            result.device.platformName.isEmpty ? 'N/A' : result.device.platformName,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('MAC: $deviceId', style: const TextStyle(fontSize: 11)),
                              Text('RSSI: ${result.rssi} dBm', style: const TextStyle(fontSize: 11)),
                              if (frames?.batteryVoltage != null)
                                Text(
                                    'Battery: ${_calculateBatteryPercentage(frames!.batteryVoltage)}% (${frames.batteryVoltage} mV)',
                                    style: const TextStyle(fontSize: 11)),
                            ],
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (frames?.namespaceId != null) ...[
                                    const Text('UID', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                    const SizedBox(height: 8),
                                    _InfoRow(label: 'Namespace ID', value: '0x${frames!.namespaceId}'),
                                    _InfoRow(label: 'Instance ID', value: '0x${frames.instanceId ?? "N/A"}'),
                                    const Divider(),
                                  ],
                                  if (frames?.temperature != null) ...[
                                    const Text('Unencrypted TLM',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                    const SizedBox(height: 8),
                                    _InfoRow(
                                        label: 'Battery',
                                        value:
                                            '${_calculateBatteryPercentage(frames!.batteryVoltage)}% (${frames.batteryVoltage} mV)'),
                                    _InfoRow(
                                        label: 'Chip temperature',
                                        value: '${frames.temperature?.toStringAsFixed(1)} °C'),
                                    _InfoRow(label: 'ADV count', value: '${frames.advCount}'),
                                    _InfoRow(label: 'Running time', value: _formatRunningTime(frames.runningTime)),
                                    const Divider(),
                                  ],
                                  if (frames?.accelX != null) ...[
                                    const Text('3-axis accelerometer',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                    const SizedBox(height: 8),
                                    _InfoRow(
                                        label: 'Battery',
                                        value:
                                            '${_calculateBatteryPercentage(frames?.batteryVoltage)}% (${frames?.batteryVoltage} mV)'),
                                    _InfoRow(
                                        label: 'Acceleration',
                                        value:
                                            'X:${frames?.accelX!.toStringAsFixed(0)} mg, Y:${frames?.accelY!.toStringAsFixed(0)} mg, Z:${frames?.accelZ!.toStringAsFixed(0)} mg'),
                                    if (frames?.samplingRate != null)
                                      _InfoRow(
                                          label: 'Sampling rate',
                                          value: '${_getSamplingRateHz(frames?.samplingRate)} Hz'),
                                    if (frames?.fullScale != null)
                                      _InfoRow(label: 'Full-scale', value: '${_getFullScaleG(frames?.fullScale)}g'),
                                    if (frames?.motionThreshold != null)
                                      _InfoRow(label: 'Motion threshold', value: '${frames?.motionThreshold}g'),
                                    if (frames?.advInterval != null)
                                      _InfoRow(label: 'Adv interval', value: '${frames?.advInterval} ms'),
                                    if (frames?.rangingData != null)
                                      _InfoRow(label: 'Ranging data', value: '${frames?.rangingData} dBm'),
                                    if (frames?.beaconMac != null)
                                      _InfoRow(label: 'Beacon MAC', value: '${frames?.beaconMac}'),
                                    const Divider(),
                                  ],
                                  _InfoRow(label: 'RSSI', value: '${frames?.rssi ?? result.rssi} dBm'),
                                  _InfoRow(label: 'Last seen', value: _formatTime(frames?.lastSeen)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _formatRunningTime(int? seconds) {
    if (seconds == null) return 'N/A';
    final duration = Duration(milliseconds: seconds * 100);
    final days = duration.inDays;
    final hours = duration.inHours % 24;
    final minutes = duration.inMinutes % 60;
    final secs = duration.inSeconds % 60;
    return '${days}d${hours}h${minutes}m${secs}.${(duration.inMilliseconds % 1000) ~/ 100}s';
  }

  String _formatTime(DateTime? time) {
    if (time == null) return 'N/A';
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inSeconds < 60) return '<${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '<${diff.inMinutes}min';
    return time.toString().substring(11, 19);
  }
}

class BeaconFrames {
  final String deviceId;
  int rssi = 0;
  DateTime lastSeen = DateTime.now();

  // UID frame
  String? namespaceId;
  String? instanceId;

  // TLM frame
  int? batteryVoltage;
  double? temperature;
  int? advCount;
  int? runningTime;

  // ACC frame
  double? accelX;
  double? accelY;
  double? accelZ;

  // ACC frame additional fields (per BeaconX Table 9)
  int? rangingData;
  int? advInterval;
  int? samplingRate;
  int? fullScale;
  double? motionThreshold;
  String? beaconMac;

  // GATT connection state
  bool hasReadGattData = false;
  bool isConnecting = false;

  BeaconFrames(this.deviceId);
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ),
          Expanded(
            flex: 3,
            child: Text(value, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}
