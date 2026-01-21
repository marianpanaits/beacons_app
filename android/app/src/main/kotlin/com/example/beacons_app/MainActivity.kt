package com.example.beacons_app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import com.moko.support.nordic.MokoSupport
import com.moko.support.nordic.entity.OrderCHAR
import com.moko.ble.lib.event.ConnectStatusEvent
import com.moko.ble.lib.event.OrderTaskResponseEvent
import org.greenrobot.eventbus.EventBus
import org.greenrobot.eventbus.Subscribe
import org.greenrobot.eventbus.ThreadMode
import com.elvishew.xlog.XLog
import com.elvishew.xlog.LogLevel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.beacons_app/ble"
    private val EVENT_CHANNEL = "com.example.beacons_app/ble_scan"
    private val REQUEST_CODE_PERMISSIONS = 100

    private var bluetoothLeScanner: BluetoothLeScanner? = null
    private var eventSink: EventChannel.EventSink? = null
    private var isScanning = false
    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            processScanResult(result)
        }
    }
    // MAC-based frame accumulation: last UID + last ACC per beacon
    private val beaconFrames = mutableMapOf<String, MutableMap<String, Any?>>()
    private var connectingMac: String? = null
    private val beaconPassword = "Moko4321"
    private var gattReadAttempted = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        XLog.init(LogLevel.ALL)
        EventBus.getDefault().register(this)
        MokoSupport.getInstance().init(applicationContext)
    }

    override fun onDestroy() {
        super.onDestroy()
        EventBus.getDefault().unregister(this)
        stopScan()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // MethodChannel for start/stop commands
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startScan" -> {
                    if (checkPermissions()) {
                        startScan()
                        result.success(true)
                    } else {
                        requestPermissions()
                        result.error("PERMISSION_DENIED", "Bluetooth permissions required", null)
                    }
                }
                "stopScan" -> {
                    stopScan()
                    result.success(true)
                }
                "testConnect" -> {
                    android.util.Log.d("BeaconX-GATT", "Manual GATT connect requested")
                    connectingMac = "D7:4F:4C:D2:4F:3B"
                    triggerGattRead()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // EventChannel for streaming scan results
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    stopScan()
                }
            }
        )
    }

    private fun checkPermissions(): Boolean {
        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.ACCESS_FINE_LOCATION
            )
        } else {
            arrayOf(
                Manifest.permission.BLUETOOTH,
                Manifest.permission.BLUETOOTH_ADMIN,
                Manifest.permission.ACCESS_FINE_LOCATION
            )
        }

        return permissions.all {
            ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestPermissions() {
        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.ACCESS_FINE_LOCATION
            )
        } else {
            arrayOf(
                Manifest.permission.BLUETOOTH,
                Manifest.permission.BLUETOOTH_ADMIN,
                Manifest.permission.ACCESS_FINE_LOCATION
            )
        }
        ActivityCompat.requestPermissions(this, permissions, REQUEST_CODE_PERMISSIONS)
    }

    private fun startScan() {
        if (isScanning) return
        
        val bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
        val bluetoothAdapter = bluetoothManager.adapter
        bluetoothLeScanner = bluetoothAdapter.bluetoothLeScanner
        
        // Pure Android BLE scanner with aggressive settings
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setLegacy(true)
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
            .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setReportDelay(0)
            .build()
        
        bluetoothLeScanner?.startScan(null, settings, scanCallback) // No filter!
        isScanning = true
        android.util.Log.d("BeaconX-PURE", "Pure Android BLE scan started")
    }
    
    private fun processScanResult(result: ScanResult) {
        try {
            val device = result.device
            val mac = device.address
            val scanRecord = result.scanRecord ?: return
            val rawBytes = scanRecord.bytes ?: return
            val rssi = result.rssi
            val name = scanRecord.deviceName ?: ""
            
            // Parse for FEAA/FEAB
            var logPos = 0
            var foundFEAA = false
            var foundFEAB = false
            while (logPos < rawBytes.size) {
                val length = rawBytes[logPos].toInt() and 0xFF
                if (length == 0) break
                if (logPos + 1 + length > rawBytes.size) break
                
                val type = rawBytes[logPos + 1].toInt() and 0xFF
                if (type == 0x16) {
                    val data = rawBytes.sliceArray((logPos + 2) until (logPos + 1 + length))
                    if (data.size >= 2) {
                        val uuid16 = ((data[1].toInt() and 0xFF) shl 8) or (data[0].toInt() and 0xFF)
                        if (uuid16 == 0xFEAA) {
                            foundFEAA = true
                        } else if (uuid16 == 0xFEAB) {
                            foundFEAB = true
                        }
                    }
                }
                logPos += 1 + length
            }
            
            // Try GATT with alternative readable characteristics (once only)
            if (mac == "D7:4F:4C:D2:4F:3B" && foundFEAB && !foundFEAA && beaconFrames[mac]?.containsKey("uid") != true && connectingMac == null && !gattReadAttempted) {
                android.util.Log.d("BeaconX-GATT", "D7:4F:4C:D2:4F:3B has ACC but no UID - trying GATT read (once)...")
                gattReadAttempted = true
                connectingMac = mac
                triggerGattRead()
            }
            
            // Initialize frame cache for this MAC if needed
            if (!beaconFrames.containsKey(mac)) {
                beaconFrames[mac] = mutableMapOf(
                    "mac" to mac,
                    "name" to name,
                    "rssi" to rssi
                )
            }
            
            val frames = beaconFrames[mac]!!
            frames["rssi"] = rssi
            
            // Parse raw bytes for FEAA/FEAB alternation
            var pos = 0
            while (pos < rawBytes.size) {
                val length = rawBytes[pos].toInt() and 0xFF
                if (length == 0) break
                if (pos + 1 + length > rawBytes.size) break
                
                val type = rawBytes[pos + 1].toInt() and 0xFF
                val adData = rawBytes.sliceArray((pos + 2) until (pos + 1 + length))
                
                // Type 0x16 = Service Data (16-bit UUID)
                if (type == 0x16 && adData.size >= 2) {
                    val uuidLow = adData[0].toInt() and 0xFF
                    val uuidHigh = adData[1].toInt() and 0xFF
                    val uuid16 = (uuidHigh shl 8) or uuidLow
                    val payload = adData.sliceArray(2 until adData.size)
                    
                    when (uuid16) {
                        0xFEAA -> {
                            // Eddystone UID (frame type 0x00)
                            if (payload.size >= 20 && payload[0].toInt() and 0xFF == 0x00) {
                                val txPower = payload[1].toInt()
                                val namespace = payload.sliceArray(2..11).joinToString("") { "%02X".format(it) }
                                val instance = payload.sliceArray(12..17).joinToString("") { "%02X".format(it) }
                                
                                // Store last UID for this MAC
                                frames["uid"] = mapOf(
                                    "namespace" to namespace,
                                    "instance" to instance,
                                    "rangingData" to txPower
                                )
                                android.util.Log.d("BeaconX-PURE", "[$mac] ✅ UID: namespace=$namespace, instance=$instance")
                            }
                        }
                        0xFEAB -> {
                            // BeaconX ACC (frame type 0x60)
                            if (payload.size >= 18 && payload[0].toInt() and 0xFF == 0x60) {
                                val rate = payload[2].toInt() and 0xFF
                                val scale = payload[3].toInt() and 0xFF
                                val sensitivity = payload[4].toInt() and 0xFF
                                
                                // X axis (2 bytes, little-endian, signed)
                                val xRaw = ((payload[6].toInt() and 0xFF) shl 8) or (payload[5].toInt() and 0xFF)
                                val x = if (xRaw > 32767) xRaw - 65536 else xRaw
                                
                                // Y axis
                                val yRaw = ((payload[8].toInt() and 0xFF) shl 8) or (payload[7].toInt() and 0xFF)
                                val y = if (yRaw > 32767) yRaw - 65536 else yRaw
                                
                                // Z axis
                                val zRaw = ((payload[10].toInt() and 0xFF) shl 8) or (payload[9].toInt() and 0xFF)
                                val z = if (zRaw > 32767) zRaw - 65536 else zRaw
                                
                                val scaleValue = when(scale) {
                                    0 -> 2
                                    1 -> 4
                                    2 -> 8
                                    3 -> 16
                                    else -> 2
                                }
                                
                                // Store last ACC for this MAC
                                frames["acc"] = mapOf(
                                    "x_data" to x.toString(),
                                    "y_data" to y.toString(),
                                    "z_data" to z.toString(),
                                    "rangingData" to "0",
                                    "dataRate" to rate.toString(),
                                    "scale" to scaleValue.toString(),
                                    "sensitivity" to sensitivity.toString()
                                )
                                android.util.Log.d("BeaconX-PURE", "[$mac] ✅ ACC: x=$x, y=$y, z=$z")
                            }
                        }
                    }
                }
                
                pos += 1 + length
            }
            
            // Send accumulated frames (last UID + last ACC) to Flutter
            eventSink?.success(frames.toMap())
        } catch (e: Exception) {
            android.util.Log.e("BeaconX-PURE", "Error processing scan result: ${e.message}")
            e.printStackTrace()
        }
    }

    private fun stopScan() {
        if (!isScanning) return
        bluetoothLeScanner?.stopScan(scanCallback)
        isScanning = false
        android.util.Log.d("BeaconX-PURE", "Pure Android BLE scan stopped")
    }

    private fun triggerGattRead() {
        val mac = connectingMac ?: return
        android.util.Log.d("BeaconX-GATT", "Connecting to $mac for UID read...")
        MokoSupport.getInstance().connDevice(mac)
    }

    @Subscribe(threadMode = ThreadMode.MAIN)
    fun onConnectStatusEvent(event: ConnectStatusEvent) {
        android.util.Log.d("BeaconX-GATT", "Connection status: ${event.action}")
        
        when (event.action) {
            "ACTION_DISCOVER_SUCCESS" -> {
                android.util.Log.d("BeaconX-GATT", "Connected! Sending unlock...")
                val unlockTask = com.moko.support.nordic.OrderTaskAssembler.setUnLock(
                    beaconPassword,
                    byteArrayOf(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                )
                if (unlockTask != null) {
                    MokoSupport.getInstance().sendOrder(unlockTask)
                }
            }
            "ACTION_DISCONNECTED" -> {
                android.util.Log.d("BeaconX-GATT", "Disconnected")
                connectingMac = null
            }
        }
    }

    @Subscribe(threadMode = ThreadMode.MAIN)
    fun onOrderTaskResponseEvent(event: OrderTaskResponseEvent) {
        val response = event.response ?: return
        val mac = connectingMac ?: return
        
        android.util.Log.d("BeaconX-GATT", "Task response: ${response.orderCHAR}")
        
        when (response.orderCHAR) {
            OrderCHAR.CHAR_UNLOCK -> {
                android.util.Log.d("BeaconX-GATT", "✅ Unlocked! Reading slot type via PARAMS notification protocol...")
                // Manually create ParamsTask for GET_SLOT_TYPE (0x61)
                // Format: EA + ParamsKey + 0000 → triggers notification on CHAR_LOCKED_NOTIFY
                val slotTypeTask = com.moko.support.nordic.task.ParamsTask()
                slotTypeTask.data = byteArrayOf(0xEA.toByte(), 0x61, 0x00, 0x00)
                MokoSupport.getInstance().sendOrder(slotTypeTask)
            }
            OrderCHAR.CHAR_PARAMS -> {
                // MokoSupport routes notification responses here
                val data = response.responseValue ?: return
                android.util.Log.d("BeaconX-GATT", "📡 PARAMS NOTIFICATION: ${data.joinToString("") { "%02x".format(it) }}")
                
                if (data.size < 2) return
                
                // Format: EB + ParamsKey + Length + Data
                if (data[0].toInt() and 0xFF == 0xEB) {
                    val paramsKey = data[1].toInt() and 0xFF
                    val dataLen = if (data.size > 2) (data[2].toInt() and 0xFF) else 0
                    android.util.Log.d("BeaconX-GATT", "ParamsKey: 0x${paramsKey.toString(16)}, Length: $dataLen")
                    
                    when (paramsKey) {
                        0x0D -> { // Some response type
                            android.util.Log.d("BeaconX-GATT", "Response 0x0D - unexpected, trying different approach")
                            // Try reading device MAC to confirm PARAMS works
                            val macTask = com.moko.support.nordic.task.ParamsTask()
                            macTask.data = byteArrayOf(0xEA.toByte(), 0x20, 0x00, 0x00)
                            MokoSupport.getInstance().sendOrder(macTask)
                        }
                        0x20 -> { // GET_DEVICE_MAC response
                            val macData = if (data.size >= 9) data.sliceArray(4..9) else byteArrayOf()
                            android.util.Log.d("BeaconX-GATT", "✅ Device MAC via PARAMS: ${macData.joinToString(":") { "%02X".format(it) }}")
                            // PARAMS protocol confirmed working - now disconnect
                            android.util.Log.d("BeaconX-GATT", "✅ PARAMS protocol works!")
                            android.util.Log.d("BeaconX-GATT", "❌ GET_SLOT_TYPE returned unexpected 0x0D")
                            android.util.Log.d("BeaconX-GATT", "CONCLUSION: Need to find correct PARAMS command for reading slot UID data")
                            MokoSupport.getInstance().disConnectBle()
                            connectingMac = null
                        }
                    }
                }
            }
        }
    }

    private fun parseSlotData(mac: String, data: ByteArray) {
        if (data.size < 3) return
        
        val frameType = data[1].toInt() and 0xFF
        android.util.Log.d("BeaconX-GATT", "Slot data frame type: 0x${frameType.toString(16)}")
        
        // Frame type 0x00 = UID
        if (frameType == 0x00 && data.size >= 22) {
            val txPower = data[2].toInt()
            val namespace = data.copyOfRange(3, 13).joinToString("") { "%02X".format(it) }
            val instance = data.copyOfRange(13, 19).joinToString("") { "%02X".format(it) }
            
            android.util.Log.d("BeaconX-GATT", "✅ UID via GATT: namespace=$namespace, instance=$instance")
            
            // Store in frame cache
            if (!beaconFrames.containsKey(mac)) {
                beaconFrames[mac] = mutableMapOf("mac" to mac)
            }
            beaconFrames[mac]!!["uid"] = mapOf(
                "namespace" to namespace,
                "instance" to instance,
                "rangingData" to txPower
            )
            
            // Send updated data to Flutter
            eventSink?.success(beaconFrames[mac]!!.toMap())
            
            // Disconnect after reading
            MokoSupport.getInstance().disConnectBle()
            connectingMac = null
        }
    }

}
