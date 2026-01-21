import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  static const platform = MethodChannel('com.example.beacons_app/ble');
  static const eventChannel = EventChannel('com.example.beacons_app/ble_scan');
  static const Set<String> _serviceUuids = {'feab', 'feaa'};

  final Map<String, NativeScanResult> _scanResults = {};
  final Map<String, BeaconFrames> _beaconFrames = {};
  bool _isScanning = false;
  StreamSubscription? _scanSubscription;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (_isScanning) return;

    try {
      await platform.invokeMethod('startScan');
      setState(() => _isScanning = true);

      _scanSubscription = eventChannel.receiveBroadcastStream().listen((data) {
        final scanData = Map<String, dynamic>.from(data);
        final mac = scanData['mac'] as String;
        final name = scanData['name'] as String? ?? '';
        final rssi = scanData['rssi'] as int;

        // Store scan result
        _scanResults[mac] = NativeScanResult(
          deviceId: mac,
          name: name,
          rssi: rssi,
          serviceUuids: [],
          serviceData: {},
        );

        _beaconFrames[mac] ??= BeaconFrames(mac);
        final frames = _beaconFrames[mac]!;
        frames.rssi = rssi;
        frames.lastSeen = DateTime.now();

        // Parse BeaconX frames from native (all values are Strings from BeaconX SDK)
        if (scanData.containsKey('uid')) {
          final uid = Map<String, dynamic>.from(scanData['uid']);
          frames.namespaceId = uid['namespace'] as String?;
          frames.instanceId = uid['instance'] as String?;
          debugPrint('🆔 UID: NS=${frames.namespaceId}, INST=${frames.instanceId}');
        }

        if (scanData.containsKey('tlm')) {
          final tlm = Map<String, dynamic>.from(scanData['tlm']);
          frames.batteryVoltage = int.tryParse(tlm['vbatt'] as String? ?? '');
          // temp comes as "22.5°C", parse the number
          final tempStr = tlm['temp'] as String?;
          if (tempStr != null) {
            frames.temperature = double.tryParse(tempStr.replaceAll('°C', ''));
          }
          frames.advCount = int.tryParse(tlm['adv_cnt'] as String? ?? '');
          debugPrint('📊 TLM: Battery=${frames.batteryVoltage}mV, Temp=${frames.temperature}°C');
        }

        if (scanData.containsKey('acc')) {
          final acc = Map<String, dynamic>.from(scanData['acc']);
          // x_data, y_data, z_data are in milligrams as strings
          frames.accelX = double.tryParse(acc['x_data'] as String? ?? '');
          frames.accelY = double.tryParse(acc['y_data'] as String? ?? '');
          frames.accelZ = double.tryParse(acc['z_data'] as String? ?? '');
          debugPrint('📐 ACC: X=${frames.accelX}mg, Y=${frames.accelY}mg, Z=${frames.accelZ}mg');
          debugPrint('    Rate: ${acc['dataRate']}, Scale: ${acc['scale']}, Sensitivity: ${acc['sensitivity']}');
        }

        if (scanData.containsKey('th')) {
          final th = Map<String, dynamic>.from(scanData['th']);
          // temperature and humidity come as formatted strings
          frames.temperature = double.tryParse(th['temperature'] as String? ?? '');
          frames.humidity = double.tryParse(th['humidity'] as String? ?? '');
          debugPrint('🌡️ T&H: Temp=${frames.temperature}°C, Humidity=${frames.humidity}%');
        }

        setState(() {});
      });
    } catch (e) {
      debugPrint('❌ Start scan error: $e');
      setState(() => _isScanning = false);
    }
  }

  Future<void> _stopScan() async {
    try {
      await platform.invokeMethod('stopScan');
      setState(() => _isScanning = false);
    } catch (e) {
      debugPrint('❌ Stop scan error: $e');
    }
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
                      final deviceId = _scanResults.keys.elementAt(index);
                      final result = _scanResults[deviceId]!;
                      final frames = _beaconFrames[deviceId];

                      return Card(
                        margin: const EdgeInsets.all(8),
                        child: ExpansionTile(
                          leading: Icon(
                            Icons.bluetooth,
                            color: result.rssi > -70 ? Colors.green : Colors.orange,
                          ),
                          title: Text(
                            result.name.isEmpty ? 'N/A' : result.name,
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
                                  _InfoRow(label: 'RSSI', value: '${result.rssi} dBm'),
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

class NativeScanResult {
  final String deviceId;
  final String name;
  final int rssi;
  final List<String> serviceUuids;
  final Map<String, List<int>> serviceData;

  NativeScanResult({
    required this.deviceId,
    required this.name,
    required this.rssi,
    required this.serviceUuids,
    required this.serviceData,
  });
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

  // T&H frame
  double? humidity;

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
