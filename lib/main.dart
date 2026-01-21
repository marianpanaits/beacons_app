import 'dart:async';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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
  static const _targetNamespaceId = '60657774606074726163';

  final Map<String, BeaconData> _beacons = {};
  bool _isScanning = false;
  StreamSubscription? _scanSubscription;
  String? _connectingMac;

  List<String> get _filteredDevices =>
      _beacons.entries.where((e) => e.value.namespaceId == _targetNamespaceId).map((e) => e.key).toList();

  @override
  void initState() {
    super.initState();
    _initBluetooth();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _initBluetooth() async {
    await FlutterBluePlus.adapterState.where((s) => s == BluetoothAdapterState.on).first;
    _startScan();
  }

  void _startScan() {
    if (_isScanning) return;

    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.onScanResults.listen(_handleScanResults);

    FlutterBluePlus.startScan(androidUsesFineLocation: true);
    setState(() => _isScanning = true);
  }

  void _handleScanResults(List<ScanResult> results) {
    for (final result in results) {
      for (final entry in result.advertisementData.serviceData.entries) {
        final uuid = entry.key.str.toLowerCase();
        if (!uuid.contains('feab') && !uuid.contains('feaa')) continue;

        final mac = result.device.remoteId.str;
        final beacon = _beacons.putIfAbsent(mac, () => BeaconData(mac));
        final data = Uint8List.fromList(entry.value);

        beacon
          ..name = result.advertisementData.advName
          ..rssi = result.rssi
          ..lastSeen = DateTime.now();

        if (uuid.contains('feab')) {
          _parseBeaconXFrame(beacon, data);
        } else if (uuid.contains('feaa')) {
          _parseEddystoneFrame(beacon, data);
        }

        if (beacon.namespaceId == null && _connectingMac == null) {
          _readNamespaceViaGatt(result.device, beacon);
        }
      }
    }
    setState(() {});
  }

  void _parseBeaconXFrame(BeaconData beacon, Uint8List data) {
    if (data.isEmpty) return;
    final frameType = data[0];

    if (frameType == 0x60 && data.length >= 14) {
      // Get scale from byte 4 (like native SDK)
      final scaleIndex = data[4];
      final scale = scaleIndex == 3 ? 12.0 : (1 << scaleIndex).toDouble(); // 1, 2, 4, or 12

      // Parse X, Y, Z (bytes 6-11) - right shift by 4 like native SDK
      final xRaw = _toSigned16((data[6] << 8) | data[7]) >> 4;
      final yRaw = _toSigned16((data[8] << 8) | data[9]) >> 4;
      final zRaw = _toSigned16((data[10] << 8) | data[11]) >> 4;

      // Convert to mg using scale factor
      beacon.accelX = (xRaw * scale).roundToDouble();
      beacon.accelY = (yRaw * scale).roundToDouble();
      beacon.accelZ = (zRaw * scale).roundToDouble();
      beacon.batteryVoltage = (data[12] << 8) | data[13];
    }
  }

  void _parseEddystoneFrame(BeaconData beacon, Uint8List data) {
    if (data.isEmpty) return;
    final frameType = data[0];

    if (frameType == 0x00 && data.length >= 18) {
      beacon.namespaceId = _toHex(data.sublist(2, 12));
      beacon.instanceId = _toHex(data.sublist(12, 18));
    }

    if (frameType == 0x20 && data.length >= 14) {
      beacon.batteryVoltage = (data[2] << 8) | data[3];
      beacon.temperature = _toSigned16((data[4] << 8) | data[5]) / 256.0;
    }
  }

  int _toSigned16(int val) => val > 32767 ? val - 65536 : val;
  String _toHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _readNamespaceViaGatt(BluetoothDevice device, BeaconData beacon) async {
    _connectingMac = beacon.mac;
    const password = 'Moko4321';

    try {
      await device.connect(timeout: const Duration(seconds: 10), license: License.commercial, autoConnect: false);
      final services = await device.discoverServices();

      BluetoothCharacteristic? unlockChar;
      BluetoothCharacteristic? lockStateChar;
      BluetoothCharacteristic? slotDataChar;

      // Find characteristics in BeaconX service
      for (final service in services) {
        for (final char in service.characteristics) {
          final uuid = char.uuid.str.toLowerCase();
          if (uuid.contains('a3c87507')) unlockChar = char; // CHAR_UNLOCK
          if (uuid.contains('a3c87506')) lockStateChar = char; // CHAR_LOCK_STATE
          if (uuid.contains('a3c8750a')) slotDataChar = char; // CHAR_ADV_SLOT_DATA
        }
      }

      if (unlockChar == null || lockStateChar == null || slotDataChar == null) return;

      // Step 1: Read challenge from CHAR_UNLOCK (16 bytes)
      final challenge = await unlockChar.read();
      if (challenge.length < 16) return;

      // Step 2: Create AES key from password (padded to 16 bytes with 0xFF like native SDK)
      final passwordBytes = Uint8List(16);
      final pwCodeUnits = password.codeUnits;
      for (int i = 0; i < 16; i++) {
        passwordBytes[i] = i < pwCodeUnits.length ? pwCodeUnits[i] : 0xFF;
      }

      // Step 3: Encrypt challenge with AES-128-ECB
      final key = encrypt.Key(passwordBytes);
      final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.ecb, padding: null));
      final challengeBytes = Uint8List.fromList(challenge.take(16).toList());
      final encrypted = encrypter.encryptBytes(challengeBytes);

      // Step 4: Write encrypted data to CHAR_UNLOCK
      await unlockChar.write(encrypted.bytes, withoutResponse: false);
      await Future.delayed(const Duration(milliseconds: 300));

      // Step 5: Read lock state to verify unlock (0x00 = locked, 0x01+ = unlocked)
      final lockState = await lockStateChar.read();
      if (lockState.isEmpty || lockState[0] == 0) {
        // 0x00 means still locked - password incorrect
        return;
      }

      // Step 6: Read slot data (now unlocked)
      final data = await slotDataChar.read();
      if (data.isNotEmpty && data[0] == 0x00 && data.length >= 18) {
        beacon.namespaceId = _toHex(data.sublist(2, 12));
        beacon.instanceId = _toHex(data.sublist(12, 18));
        setState(() {});
      }
    } catch (_) {
    } finally {
      try {
        await device.disconnect();
      } catch (_) {}
      _connectingMac = null;
    }
  }

  int _batteryPercentage(int? voltage) {
    if (voltage == null) return 0;
    return ((voltage - 2800) / 1400 * 100).round().clamp(0, 100);
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
                    label: 'Acceleration',
                    value:
                        'X:${beacon.accelX?.toStringAsFixed(0)} Y:${beacon.accelY?.toStringAsFixed(0)} Z:${beacon.accelZ?.toStringAsFixed(0)} mg',
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

  String? namespaceId;
  String? instanceId;

  int? batteryVoltage;
  double? temperature;

  double? accelX;
  double? accelY;
  double? accelZ;

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
