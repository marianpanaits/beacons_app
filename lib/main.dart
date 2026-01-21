import 'dart:async';
import 'dart:typed_data';

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
  // FEAA = Eddystone service
  static const String _eddystone16 = 'feaa';
  // FEAB = BeaconX custom service (as you mentioned)
  static const String _beaconx16 = 'feab';

  List<ScanResult> _scanResults = [];
  final Map<String, BeaconFrames> _beaconFrames = {};
  bool _isScanning = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  // GATT UUIDs (from BeaconX protocol)
  static final Guid _serviceUuid = Guid('a3c87500-8ed3-4bdf-8a39-a01bebede295');
  static final Guid _unlockCharUuid = Guid('a3c87507-8ed3-4bdf-8a39-a01bebede295');
  static final Guid _advSlotDataCharUuid = Guid('a3c8750a-8ed3-4bdf-8a39-a01bebede295');
  static const String _beaconPassword = 'Moko4321';

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
    // Android 12+ needs these
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    // Still needed on many devices for scan results
    await Permission.location.request();

    _startScan();
  }

  Future<void> _startScan() async {
    if (_isScanning) return;

    setState(() => _isScanning = true);

    try {
      // Optional: you can filter to reduce noise.
      // Caveat: some beacons advertise FEAB only and might not match FEAA filter.
      // So we include both services here.
      await FlutterBluePlus.startScan(
        androidUsesFineLocation: true,
        continuousUpdates: true,
      );

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        final filtered = <ScanResult>[];

        for (final result in results) {
          if (!_isBeacon(result)) continue;

          final deviceId = result.device.remoteId.toString();
          final isNewBeacon = !_beaconFrames.containsKey(deviceId);
          _beaconFrames.putIfAbsent(deviceId, () => BeaconFrames(deviceId));

          final frames = _beaconFrames[deviceId]!;
          frames.rssi = result.rssi;
          frames.lastSeen = DateTime.now();

          // Automatically try to read UID via GATT for new beacons
          if (isNewBeacon && !frames.hasReadGattData && !frames.isConnecting) {
            _tryReadUidViaGatt(result.device);
          }

          final ad = result.advertisementData;

          debugPrint('--- $deviceId RSSI=${result.rssi}');
          debugPrint('serviceUuids: ${ad.serviceUuids.map((g) => g.str).toList()}');
          debugPrint('serviceData keys: ${ad.serviceData.keys.map((g) => g.str).toList()}');
          debugPrint('manufacturerData keys: ${ad.manufacturerData.keys.toList()}');

          // Parse FEAA/FEAB serviceData
          for (final entry in ad.serviceData.entries) {
            final isFeaa = _matches16Or128(entry.key, 'feaa');
            final isFeab = _matches16Or128(entry.key, 'feab');

            if (isFeaa || isFeab) {
              _parseFrame(deviceId, entry.value, result.rssi, service: isFeaa ? _eddystone16 : _beaconx16);
            }
          }

          filtered.add(result);
        }

        setState(() => _scanResults = filtered);
      });
    } catch (e) {
      debugPrint('Scan error: $e');
      setState(() => _isScanning = false);
    }
  }

  // Robust UUID matching that handles both 16-bit and 128-bit formats
  bool _matches16Or128(Guid g, String short16) {
    final s = g.str.toLowerCase();
    final t = short16.toLowerCase();
    return s == t || s.endsWith('0000$t-0000-1000-8000-00805f9b34fb');
  }

  void _parseFrame(
    String deviceId,
    List<int> data,
    int rssi, {
    required String service,
  }) {
    if (data.isEmpty) return;

    final frames = _beaconFrames[deviceId]!;
    frames.rssi = rssi;
    frames.lastSeen = DateTime.now();

    debugPrint('📦 Service=$service  FrameType=0x${data[0].toRadixString(16).padLeft(2, '0')}');
    debugPrint('📊 Raw (${data.length} bytes): ${_hexSpaced(data)}');

    switch (data[0]) {
      case 0x00: // Eddystone UID
        // FEAA service data layout:
        // 0: frame type (0x00)
        // 1: tx power
        // 2..11: namespace (10 bytes)
        // 12..17: instance (6 bytes)
        if (data.length >= 18) {
          frames.namespaceId = _hexCompact(data.sublist(2, 12));
          frames.instanceId = _hexCompact(data.sublist(12, 18));
        }
        break;

      case 0x20: // Eddystone TLM (unencrypted)
        // FEAA service data layout:
        // 0: frame type (0x20)
        // 1: version
        // 2..3: battery voltage (mV)
        // 4..5: temperature (signed 8.8 fixed point); 0x8000 = not supported
        // 6..9: adv count (uint32)
        // 10..13: time since boot in 0.1s (uint32)
        if (data.length >= 14) {
          frames.batteryVoltage = (data[2] << 8) | data[3];

          final t0 = data[4];
          final t1 = data[5];
          final tempRaw = (t0 << 8) | t1;
          if (tempRaw == 0x8000) {
            frames.temperature = null;
          } else {
            final signedInt8 = (t0 & 0x80) != 0 ? t0 - 256 : t0;
            frames.temperature = signedInt8 + (t1 / 256.0);
          }

          frames.advCount = (data[6] << 24) | (data[7] << 16) | (data[8] << 8) | data[9];
          frames.runningTime01s = (data[10] << 24) | (data[11] << 16) | (data[12] << 8) | data[13]; // 0.1s units
        }
        break;

      case 0x60: // BeaconX custom 3-axis ACC frame (as you described)
        // Your parsing is kept, plus both MAC endian views for sanity.
        if (data.length >= 21) {
          frames.rangingData = data[1].toSigned(8);
          frames.advInterval = data[2] * 100; // ms
          frames.samplingRate = data[3];
          frames.fullScale = data[4];
          frames.motionThreshold = data[5] * 0.1;

          final xRaw = (data[6] << 8) | data[7];
          final yRaw = (data[8] << 8) | data[9];
          final zRaw = (data[10] << 8) | data[11];

          frames.batteryVoltage = (data[12] << 8) | data[13];

          frames.accelX = _decode12BitSignedMg(xRaw);
          frames.accelY = _decode12BitSignedMg(yRaw);
          frames.accelZ = _decode12BitSignedMg(zRaw);

          final macBytes = Uint8List.fromList(data.sublist(15, 21));
          frames.beaconMac = _hexMac(macBytes);
          frames.beaconMacReversed = _hexMac(Uint8List.fromList(macBytes.reversed.toList()));

          debugPrint(
              '🔋 Battery: ${frames.batteryVoltage} mV (${_calculateBatteryPercentage(frames.batteryVoltage)}%)');
          debugPrint('📐 ACC: X=${frames.accelX} mg, Y=${frames.accelY} mg, Z=${frames.accelZ} mg');
          debugPrint(
              '⚙️ Ranging: ${frames.rangingData} dBm, Interval: ${frames.advInterval} ms, Rate: ${_getSamplingRateHz(frames.samplingRate)} Hz');
          debugPrint('📏 Full-scale: ${_getFullScaleG(frames.fullScale)}g, Threshold: ${frames.motionThreshold}g');
          debugPrint('📍 Beacon MAC: ${frames.beaconMac}  (rev: ${frames.beaconMacReversed})');
        }
        break;

      default:
        // If you see other frame types, we can add them (0x10 URL, etc.)
        debugPrint('🤷 Unhandled frame type: 0x${data[0].toRadixString(16)}');
        break;
    }
  }

  String _hexSpaced(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  String _hexCompact(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String _hexMac(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');

  double _decode12BitSignedMg(int raw16) {
    final v12 = (raw16 >> 4) & 0x0FFF;
    final signed = (v12 & 0x800) != 0 ? v12 - 0x1000 : v12;
    return signed.toDouble();
  }

  int _calculateBatteryPercentage(int? voltage) {
    if (voltage == null) return 0;
    const minVoltage = 2800;
    const maxVoltage = 4200;
    final percentage = ((voltage - minVoltage) / (maxVoltage - minVoltage) * 100).round();
    return percentage.clamp(0, 100);
  }

  String _getSamplingRateHz(int? code) {
    if (code == null) return 'N/A';
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
        return '±$code';
    }
  }

  bool _isBeacon(ScanResult result) {
    // Your original filter
    final mac = result.device.remoteId.toString().toUpperCase();
    return mac == 'D7:4F:4C:D2:4F:3B' || mac == 'ED:CF:19:48:B0:D5';
  }

  Future<void> _tryReadUidViaGatt(BluetoothDevice device) async {
    final deviceId = device.remoteId.toString();
    final frames = _beaconFrames[deviceId];
    if (frames == null) return;

    if (frames.isConnecting) {
      debugPrint('⏳ Already connecting to $deviceId');
      return;
    }

    try {
      setState(() => frames.isConnecting = true);
      debugPrint('🔗 Connecting to $deviceId for UID read...');

      await device.connect(timeout: const Duration(seconds: 15), license: License.commercial);
      debugPrint('✅ Connected to $deviceId');

      final services = await device.discoverServices();
      debugPrint('🔍 Services discovered: ${services.length} services');
      
      // Log all services and characteristics
      for (final service in services) {
        debugPrint('  📋 Service: ${service.uuid}');
        for (final char in service.characteristics) {
          debugPrint('    📌 Char: ${char.uuid} (${char.properties})');
        }
      }

      final service = services.firstWhere(
        (s) => s.uuid == _serviceUuid,
        orElse: () => throw Exception('BeaconX service not found'),
      );
      
      final unlockChar = service.characteristics.firstWhere(
        (c) => c.uuid == _unlockCharUuid,
        orElse: () => throw Exception('Unlock characteristic not found'),
      );
      final slotDataChar = service.characteristics.firstWhere(
        (c) => c.uuid == _advSlotDataCharUuid,
        orElse: () => throw Exception('Slot data characteristic not found'),
      );

      // Unlock beacon with password
      debugPrint('🔓 Unlocking with password...');
      final passwordBytes = _beaconPassword.codeUnits;
      final unlockData = List<int>.filled(16, 0xFF);
      for (int i = 0; i < passwordBytes.length && i < 16; i++) {
        unlockData[i] = passwordBytes[i];
      }
      await unlockChar.write(unlockData, withoutResponse: false);
      
      // Wait and verify unlock by reading unlock characteristic
      await Future.delayed(const Duration(milliseconds: 1000));
      final unlockStatus = await unlockChar.read();
      debugPrint('🔐 Unlock status: ${unlockStatus.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      debugPrint('✅ Unlocked');

      // Read ADV Slot Data
      debugPrint('📖 Reading ADV Slot Data...');
      final slotData = await slotDataChar.read();
      debugPrint('📊 Slot data: ${slotData.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');

      // Parse UID from slot data
      if (slotData.isNotEmpty && slotData[0] == 0x00 && slotData.length >= 18) {
        final namespace =
            slotData.sublist(2, 12).map((b) => b.toRadixString(16).padLeft(2, '0')).join('').toUpperCase();
        final instance =
            slotData.sublist(12, 18).map((b) => b.toRadixString(16).padLeft(2, '0')).join('').toUpperCase();

        debugPrint('✅ UID via GATT: namespace=$namespace, instance=$instance');

        setState(() {
          frames.namespaceId = namespace;
          frames.instanceId = instance;
          frames.hasReadGattData = true;
        });
      } else {
        debugPrint('⚠️ Slot data frame type: 0x${slotData.isNotEmpty ? slotData[0].toRadixString(16) : 'empty'}');
        debugPrint('ℹ️ This slot may not contain UID data');
      }

      await device.disconnect();
      debugPrint('🔌 Disconnected from $deviceId');
    } catch (e, stackTrace) {
      debugPrint('❌ GATT error for $deviceId: $e');
      debugPrint('Stack trace: $stackTrace');
      try {
        await device.disconnect();
      } catch (disconnectError) {
        debugPrint('⚠️ Disconnect error: $disconnectError');
      }
    } finally {
      debugPrint('🏁 GATT operation finished for $deviceId');
      setState(() => frames.isConnecting = false);
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
                                  if (frames?.namespaceId != null) ...[
                                    const Text('Eddystone UID',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                    const SizedBox(height: 8),
                                    _InfoRow(label: 'Namespace ID', value: '0x${frames!.namespaceId}'),
                                    _InfoRow(label: 'Instance ID', value: '0x${frames.instanceId ?? "N/A"}'),
                                    const Divider(),
                                  ],
                                  if (frames?.temperature != null || frames?.advCount != null) ...[
                                    const Text('Eddystone TLM',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                    const SizedBox(height: 8),
                                    if (frames?.batteryVoltage != null)
                                      _InfoRow(
                                        label: 'Battery',
                                        value:
                                            '${_calculateBatteryPercentage(frames!.batteryVoltage)}% (${frames.batteryVoltage} mV)',
                                      ),
                                    _InfoRow(
                                      label: 'Chip temperature',
                                      value: frames?.temperature == null
                                          ? 'N/A'
                                          : '${frames!.temperature!.toStringAsFixed(2)} °C',
                                    ),
                                    _InfoRow(label: 'ADV count', value: '${frames?.advCount ?? "N/A"}'),
                                    _InfoRow(
                                      label: 'Running time',
                                      value: _formatRunningTime01s(frames?.runningTime01s),
                                    ),
                                    const Divider(),
                                  ],
                                  if (frames?.accelX != null) ...[
                                    const Text('BeaconX 3-axis ACC',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                    const SizedBox(height: 8),
                                    if (frames?.batteryVoltage != null)
                                      _InfoRow(
                                        label: 'Battery',
                                        value:
                                            '${_calculateBatteryPercentage(frames!.batteryVoltage)}% (${frames.batteryVoltage} mV)',
                                      ),
                                    _InfoRow(
                                      label: 'Acceleration',
                                      value:
                                          'X:${frames!.accelX!.toStringAsFixed(0)} mg, Y:${frames.accelY!.toStringAsFixed(0)} mg, Z:${frames.accelZ!.toStringAsFixed(0)} mg',
                                    ),
                                    if (frames?.samplingRate != null)
                                      _InfoRow(
                                        label: 'Sampling rate',
                                        value: '${_getSamplingRateHz(frames!.samplingRate)} Hz',
                                      ),
                                    if (frames?.fullScale != null)
                                      _InfoRow(label: 'Full-scale', value: '${_getFullScaleG(frames!.fullScale)}g'),
                                    if (frames?.motionThreshold != null)
                                      _InfoRow(label: 'Motion threshold', value: '${frames!.motionThreshold}g'),
                                    if (frames?.advInterval != null)
                                      _InfoRow(label: 'Adv interval', value: '${frames!.advInterval} ms'),
                                    if (frames?.rangingData != null)
                                      _InfoRow(label: 'Ranging data', value: '${frames!.rangingData} dBm'),
                                    if (frames?.beaconMac != null)
                                      _InfoRow(label: 'Beacon MAC', value: frames!.beaconMac!),
                                    if (frames?.beaconMacReversed != null)
                                      _InfoRow(label: 'Beacon MAC (rev)', value: frames!.beaconMacReversed!),
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

  String _formatRunningTime01s(int? time01s) {
    if (time01s == null) return 'N/A';
    final duration = Duration(milliseconds: time01s * 100); // 0.1s units => *100ms
    final days = duration.inDays;
    final hours = duration.inHours % 24;
    final minutes = duration.inMinutes % 60;
    final secs = duration.inSeconds % 60;
    final deci = (duration.inMilliseconds % 1000) ~/ 100;
    return '${days}d${hours}h${minutes}m${secs}.${deci}s';
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

  // Eddystone UID frame
  String? namespaceId;
  String? instanceId;

  // Eddystone TLM frame
  int? batteryVoltage;
  double? temperature;
  int? advCount;
  int? runningTime01s; // 0.1s units (per Eddystone)

  // BeaconX ACC frame
  double? accelX;
  double? accelY;
  double? accelZ;

  int? rangingData;
  int? advInterval;
  int? samplingRate;
  int? fullScale;
  double? motionThreshold;

  String? beaconMac;
  String? beaconMacReversed;

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
