import 'dart:async';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// =============================================================================
// App Entry Point
// =============================================================================

void main() => runApp(const BeaconApp());

class BeaconApp extends StatelessWidget {
  const BeaconApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BeaconX Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ScanScreen(),
    );
  }
}

// =============================================================================
// Scan Screen
// =============================================================================

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  static const _targetNamespaceId = '60657774606074726163';
  static const _beaconPassword = 'Moko4321';

  final Map<String, BeaconData> _beacons = {};
  StreamSubscription? _scanSubscription;
  String? _connectingMac;
  bool _isScanning = false;

  List<String> get _filteredMacs =>
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
    _scanSubscription = FlutterBluePlus.onScanResults.listen(_onScanResults);
    FlutterBluePlus.startScan(androidUsesFineLocation: true);
    setState(() => _isScanning = true);
  }

  void _onScanResults(List<ScanResult> results) {
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
        } else {
          _parseEddystoneFrame(beacon, data);
        }

        if (beacon.namespaceId == null && _connectingMac == null) {
          _readNamespaceViaGatt(result.device, beacon);
        }
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BeaconX Scanner'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          if (_isScanning) const LinearProgressIndicator(),
          Expanded(
            child: _filteredMacs.isEmpty
                ? const Center(child: Text('Scanning for beacons...'))
                : ListView.builder(
                    itemCount: _filteredMacs.length,
                    itemBuilder: (_, i) => BeaconCard(
                      beacon: _beacons[_filteredMacs[i]]!,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Frame Parsing (extension on _ScanScreenState)
// =============================================================================

extension _FrameParsing on _ScanScreenState {
  void _parseBeaconXFrame(BeaconData beacon, Uint8List data) {
    if (data.isEmpty || data[0] != 0x60 || data.length < 14) return;

    final scaleIndex = data[4];
    final scale = scaleIndex == 3 ? 12.0 : (1 << scaleIndex).toDouble();

    beacon
      ..accelX = (_toSigned16((data[6] << 8) | data[7]) >> 4) * scale
      ..accelY = (_toSigned16((data[8] << 8) | data[9]) >> 4) * scale
      ..accelZ = (_toSigned16((data[10] << 8) | data[11]) >> 4) * scale
      ..batteryVoltage = (data[12] << 8) | data[13];
  }

  void _parseEddystoneFrame(BeaconData beacon, Uint8List data) {
    if (data.isEmpty) return;

    if (data[0] == 0x00 && data.length >= 18) {
      beacon
        ..namespaceId = _toHex(data.sublist(2, 12))
        ..instanceId = _toHex(data.sublist(12, 18));
    }

    if (data[0] == 0x20 && data.length >= 14) {
      beacon
        ..batteryVoltage = (data[2] << 8) | data[3]
        ..temperature = _toSigned16((data[4] << 8) | data[5]) / 256.0;
    }
  }

  int _toSigned16(int val) => val > 32767 ? val - 65536 : val;
  String _toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

// =============================================================================
// GATT Operations (extension on _ScanScreenState)
// =============================================================================

extension _GattOperations on _ScanScreenState {
  Future<void> _readNamespaceViaGatt(BluetoothDevice device, BeaconData beacon) async {
    _connectingMac = beacon.mac;

    try {
      await device.connect(timeout: const Duration(seconds: 10), license: License.commercial, autoConnect: false);
      final services = await device.discoverServices();

      final chars = _findCharacteristics(services);
      if (chars == null) return;

      final (unlockChar, lockStateChar, slotDataChar) = chars;

      // Read challenge & unlock
      final challenge = await unlockChar.read();
      if (challenge.length < 16) return;

      final encrypted = _encryptChallenge(challenge);
      await unlockChar.write(encrypted, withoutResponse: false);
      await Future.delayed(const Duration(milliseconds: 300));

      // Verify unlock
      final lockState = await lockStateChar.read();
      if (lockState.isEmpty || lockState[0] == 0) return;

      // Read namespace
      final data = await slotDataChar.read();
      if (data.isNotEmpty && data[0] == 0x00 && data.length >= 18) {
        beacon
          ..namespaceId = _toHex(data.sublist(2, 12))
          ..instanceId = _toHex(data.sublist(12, 18));
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

  (BluetoothCharacteristic, BluetoothCharacteristic, BluetoothCharacteristic)? _findCharacteristics(
    List<BluetoothService> services,
  ) {
    BluetoothCharacteristic? unlock, lockState, slotData;

    for (final service in services) {
      for (final char in service.characteristics) {
        final uuid = char.uuid.str.toLowerCase();
        if (uuid.contains('a3c87507')) unlock = char;
        if (uuid.contains('a3c87506')) lockState = char;
        if (uuid.contains('a3c8750a')) slotData = char;
      }
    }

    if (unlock == null || lockState == null || slotData == null) return null;
    return (unlock, lockState, slotData);
  }

  List<int> _encryptChallenge(List<int> challenge) {
    final passwordBytes = Uint8List(16);
    final pw = _ScanScreenState._beaconPassword.codeUnits;
    for (int i = 0; i < 16; i++) {
      passwordBytes[i] = i < pw.length ? pw[i] : 0xFF;
    }

    final key = encrypt.Key(passwordBytes);
    final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.ecb, padding: null));
    return encrypter.encryptBytes(Uint8List.fromList(challenge.take(16).toList())).bytes;
  }

  String _toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

// =============================================================================
// Beacon Card Widget
// =============================================================================

class BeaconCard extends StatelessWidget {
  final BeaconData beacon;

  const BeaconCard({super.key, required this.beacon});

  int _batteryPercent(int? mV) => mV == null ? 0 : ((mV - 2800) / 1400 * 100).round().clamp(0, 100);

  String _timeAgo(DateTime? t) {
    if (t == null) return 'N/A';
    final s = DateTime.now().difference(t).inSeconds;
    return s < 60 ? '${s}s ago' : '${s ~/ 60}m ago';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: ExpansionTile(
        leading: Icon(Icons.bluetooth, color: beacon.rssi > -70 ? Colors.green : Colors.orange),
        title: Text(beacon.name.isEmpty ? 'BeaconX Pro' : beacon.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MAC: ${beacon.mac}', style: const TextStyle(fontSize: 11)),
            Text('RSSI: ${beacon.rssi} dBm', style: const TextStyle(fontSize: 11)),
            if (beacon.batteryVoltage != null)
              Text('Battery: ${_batteryPercent(beacon.batteryVoltage)}% (${beacon.batteryVoltage} mV)',
                  style: const TextStyle(fontSize: 11)),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (beacon.namespaceId != null) ...[
                  const Text('UID', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  _Row('Namespace', '0x${beacon.namespaceId}'),
                  _Row('Instance', '0x${beacon.instanceId ?? "N/A"}'),
                  const Divider(),
                ],
                if (beacon.accelX != null) ...[
                  const Text('Accelerometer', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  _Row('Acceleration',
                      'X:${beacon.accelX?.round()} Y:${beacon.accelY?.round()} Z:${beacon.accelZ?.round()} mg'),
                  const Divider(),
                ],
                _Row('RSSI', '${beacon.rssi} dBm'),
                _Row('Last seen', _timeAgo(beacon.lastSeen)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label, value;
  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(flex: 2, child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12))),
        Expanded(flex: 3, child: Text(value, style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))),
      ]),
    );
  }
}

// =============================================================================
// Data Model
// =============================================================================

class BeaconData {
  final String mac;
  String name = '';
  int rssi = 0;
  DateTime lastSeen = DateTime.now();

  String? namespaceId;
  String? instanceId;
  int? batteryVoltage;
  double? temperature;
  double? accelX, accelY, accelZ;

  BeaconData(this.mac);
}
