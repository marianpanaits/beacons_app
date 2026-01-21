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
  static const _platform = MethodChannel('com.example.beacons_app/ble');
  static const _eventChannel = EventChannel('com.example.beacons_app/ble_scan');
  static const _targetNamespaceId = '60657774606074726163';

  final Map<String, BeaconData> _beacons = {};
  bool _isScanning = false;
  StreamSubscription? _scanSubscription;

  List<String> get _filteredDevices => _beacons.entries
      .where((e) => e.value.namespaceId == _targetNamespaceId)
      .map((e) => e.key)
      .toList();

  @override
  void initState() {
    super.initState();
    // Delay to ensure native side is initialized
    Future.delayed(const Duration(milliseconds: 500), _startScan);
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (_isScanning) return;

    // Set up listener BEFORE starting scan
    _scanSubscription?.cancel();
    _scanSubscription = _eventChannel.receiveBroadcastStream().listen(_handleScanData);

    try {
      await _platform.invokeMethod('startScan');
      setState(() => _isScanning = true);
    } catch (e) {
      // Permission denied - retry after delay
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) _startScan();
    }
  }

  Future<void> _stopScan() async {
    try {
      await _platform.invokeMethod('stopScan');
      setState(() => _isScanning = false);
    } catch (e) {
      // Silent fail
    }
  }

  void _handleScanData(dynamic data) {
    final scanData = Map<String, dynamic>.from(data);
    final mac = scanData['mac'] as String;
    final name = scanData['name'] as String? ?? '';
    final rssi = scanData['rssi'] as int;

    final beacon = _beacons.putIfAbsent(mac, () => BeaconData(mac));
    beacon
      ..name = name
      ..rssi = rssi
      ..lastSeen = DateTime.now();

    if (scanData.containsKey('uid')) {
      final uid = Map<String, dynamic>.from(scanData['uid']);
      beacon.namespaceId = uid['namespace'] as String?;
      beacon.instanceId = uid['instance'] as String?;
    }

    if (scanData.containsKey('tlm')) {
      final tlm = Map<String, dynamic>.from(scanData['tlm']);
      beacon.batteryVoltage = int.tryParse(tlm['vbatt'] as String? ?? '');
      final tempStr = tlm['temp'] as String?;
      if (tempStr != null) {
        beacon.temperature = double.tryParse(tempStr.replaceAll('°C', ''));
      }
      beacon.advCount = int.tryParse(tlm['adv_cnt'] as String? ?? '');
    }

    if (scanData.containsKey('acc')) {
      final acc = Map<String, dynamic>.from(scanData['acc']);
      beacon.accelX = double.tryParse(acc['x_data'] as String? ?? '');
      beacon.accelY = double.tryParse(acc['y_data'] as String? ?? '');
      beacon.accelZ = double.tryParse(acc['z_data'] as String? ?? '');
      final batteryVal = acc['battery'];
      if (batteryVal != null) {
        beacon.batteryVoltage = batteryVal is int ? batteryVal : int.tryParse(batteryVal.toString());
      }
    }

    if (scanData.containsKey('th')) {
      final th = Map<String, dynamic>.from(scanData['th']);
      beacon.temperature = double.tryParse(th['temperature'] as String? ?? '');
      beacon.humidity = double.tryParse(th['humidity'] as String? ?? '');
    }

    setState(() {});
  }

  int _batteryPercentage(int? voltage) {
    if (voltage == null) return 0;
    const minV = 2800, maxV = 4200;
    return ((voltage - minV) / (maxV - minV) * 100).round().clamp(0, 100);
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
            child: _filteredDevices.isEmpty
                ? const Center(child: Text('Scanning for beacons...'))
                : ListView.builder(
                    itemCount: _filteredDevices.length,
                    itemBuilder: (context, index) {
                      final mac = _filteredDevices[index];
                      final beacon = _beacons[mac]!;
                      return _BeaconCard(beacon: beacon, batteryPercentage: _batteryPercentage);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _BeaconCard extends StatelessWidget {
  final BeaconData beacon;
  final int Function(int?) batteryPercentage;

  const _BeaconCard({required this.beacon, required this.batteryPercentage});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: ExpansionTile(
        leading: Icon(
          Icons.bluetooth,
          color: beacon.rssi > -70 ? Colors.green : Colors.orange,
        ),
        title: Text(
          beacon.name.isEmpty ? 'BeaconX Pro' : beacon.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MAC: ${beacon.mac}', style: const TextStyle(fontSize: 11)),
            Text('RSSI: ${beacon.rssi} dBm', style: const TextStyle(fontSize: 11)),
            if (beacon.batteryVoltage != null)
              Text(
                'Battery: ${batteryPercentage(beacon.batteryVoltage)}% (${beacon.batteryVoltage} mV)',
                style: const TextStyle(fontSize: 11),
              ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (beacon.namespaceId != null) ...[
                  const Text('UID', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  _InfoRow(label: 'Namespace ID', value: '0x${beacon.namespaceId}'),
                  _InfoRow(label: 'Instance ID', value: '0x${beacon.instanceId ?? "N/A"}'),
                  const Divider(),
                ],
                if (beacon.accelX != null) ...[
                  const Text('Accelerometer', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  _InfoRow(
                    label: 'Battery',
                    value: '${batteryPercentage(beacon.batteryVoltage)}% (${beacon.batteryVoltage} mV)',
                  ),
                  _InfoRow(
                    label: 'Acceleration',
                    value: 'X:${beacon.accelX?.toStringAsFixed(0)} Y:${beacon.accelY?.toStringAsFixed(0)} Z:${beacon.accelZ?.toStringAsFixed(0)} mg',
                  ),
                  const Divider(),
                ],
                _InfoRow(label: 'RSSI', value: '${beacon.rssi} dBm'),
                _InfoRow(label: 'Last seen', value: _formatTime(beacon.lastSeen)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime? time) {
    if (time == null) return 'N/A';
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    return '${diff.inMinutes}m ago';
  }
}
class BeaconData {
  final String mac;
  String name = '';
  int rssi = 0;
  DateTime lastSeen = DateTime.now();

  // UID
  String? namespaceId;
  String? instanceId;

  // TLM
  int? batteryVoltage;
  double? temperature;
  int? advCount;

  // ACC
  double? accelX;
  double? accelY;
  double? accelZ;

  // T&H
  double? humidity;

  BeaconData(this.mac);
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
