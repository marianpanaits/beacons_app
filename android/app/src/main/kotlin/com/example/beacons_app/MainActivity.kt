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
import com.moko.support.nordic.MokoSupport
import com.moko.support.nordic.MokoBleScanner
import com.moko.support.nordic.callback.MokoScanDeviceCallback
import com.moko.support.nordic.entity.OrderCHAR
import com.moko.support.nordic.entity.DeviceInfo
import com.moko.bxp.nordic.utils.BeaconXInfoParseableImpl
import com.moko.bxp.nordic.utils.BeaconXParser
import com.moko.bxp.nordic.entity.BeaconXInfo
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

    private var mokoBleScanner: MokoBleScanner? = null
    private var eventSink: EventChannel.EventSink? = null
    private var isScanning = false
    // MAC-based frame accumulation: last UID + last ACC per beacon
    private val beaconFrames = mutableMapOf<String, MutableMap<String, Any?>>()
    private var connectingMac: String? = null
    private val beaconPassword = "Moko4321"
    private var gattReadAttempted = false
    private var lockStateChallenge: ByteArray? = null
    // Single parser instance to accumulate frames across scan results
    private val beaconXInfoParser = BeaconXInfoParseableImpl()

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
                "readUidGatt" -> {
                    val mac = call.argument<String>("mac")
                    if (mac != null) {
                        android.util.Log.d("BeaconX-GATT", "GATT UID read requested for $mac")
                        connectingMac = mac
                        triggerGattRead()
                        result.success(true)
                    } else {
                        result.error("INVALID_MAC", "MAC address required", null)
                    }
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
        
        // Use MokoBleScanner (Nordic library) for proper ScanResult type
        mokoBleScanner = MokoBleScanner(this)
        mokoBleScanner?.startScanDevice(object : MokoScanDeviceCallback {
            override fun onStartScan() {
                isScanning = true
                android.util.Log.d("BeaconX-SDK", "MokoBleScanner started")
            }
            
            override fun onScanDevice(deviceInfo: DeviceInfo) {
                processDeviceInfo(deviceInfo)
            }
            
            override fun onStopScan() {
                isScanning = false
                android.util.Log.d("BeaconX-SDK", "MokoBleScanner stopped")
            }
        })
    }
    
    private fun processDeviceInfo(deviceInfo: DeviceInfo) {
        try {
            val mac = deviceInfo.mac
            val rssi = deviceInfo.rssi
            val name = deviceInfo.name ?: ""
            
            // === BeaconX SDK 2-step parsing approach ===
            // DeviceInfo already has scanResult from MokoBleScanner
            // Use shared parser instance to accumulate frames across advertisements
            
            val beaconXInfo = beaconXInfoParser.parseDeviceInfo(deviceInfo)
            if (beaconXInfo == null) {
                // Not a BeaconX Pro device, skip
                return
            }
            
            android.util.Log.d("BeaconX-SDK", "[$mac] BeaconX Pro detected!")
            
            // Auto-trigger GATT read for new BeaconX beacons to get namespace ID
            val existingFrames = beaconFrames[mac]
            val hasNamespace = existingFrames?.containsKey("uid") == true
            if (!hasNamespace && connectingMac == null) {
                android.util.Log.d("BeaconX-SDK", "[$mac] New BeaconX beacon, triggering GATT read for namespace...")
                connectingMac = mac
                MokoSupport.getInstance().connDevice(mac)
            }
            
            android.util.Log.d("BeaconX-SDK", "[$mac] Parsed BeaconXInfo, validDataHashMap size=${beaconXInfo.validDataHashMap?.size ?: 0}")
            
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
            
            // Step 2: Extract and parse frame data
            beaconXInfo.validDataHashMap?.values?.forEach { validData ->
                android.util.Log.d("BeaconX-SDK", "[$mac] Frame type=0x${Integer.toHexString(validData.type)}, data=${validData.data}")
                
                when (validData.type) {
                    BeaconXInfo.VALID_DATA_FRAME_TYPE_UID -> {
                        // Parse UID frame
                        val uid = BeaconXParser.getUID(validData.data)
                        frames["uid"] = mapOf(
                            "namespace" to uid.namespace,
                            "instance" to uid.instanceId,
                            "rangingData" to uid.rangingData
                        )
                        android.util.Log.d("BeaconX-SDK", "[$mac] ✅ UID: namespace=${uid.namespace}, instance=${uid.instanceId}")
                    }
                    BeaconXInfo.VALID_DATA_FRAME_TYPE_TLM -> {
                        // Parse TLM frame
                        val tlm = BeaconXParser.getTLM(validData.data)
                        frames["tlm"] = mapOf(
                            "vbatt" to tlm.vbatt,
                            "temp" to tlm.temp,
                            "adv_cnt" to tlm.adv_cnt
                        )
                        android.util.Log.d("BeaconX-SDK", "[$mac] 📊 TLM: battery=${tlm.vbatt}mV, temp=${tlm.temp}")
                    }
                    BeaconXInfo.VALID_DATA_FRAME_TYPE_AXIS -> {
                        // Parse ACC frame
                        val axis = BeaconXParser.getAxis(beaconXInfo.needParseData, validData.data)
                        frames["acc"] = mapOf(
                            "x_data" to axis.x_data,
                            "y_data" to axis.y_data,
                            "z_data" to axis.z_data,
                            "rangingData" to axis.rangingData,
                            "dataRate" to axis.dataRate,
                            "scale" to axis.scale,
                            "sensitivity" to axis.sensitivity,
                            "battery" to beaconXInfo.battery
                        )
                        android.util.Log.d("BeaconX-SDK", "[$mac] ✅ ACC: x=${axis.x_data}mg, y=${axis.y_data}mg, z=${axis.z_data}mg, battery=${beaconXInfo.battery}mV")
                    }
                    BeaconXInfo.VALID_DATA_FRAME_TYPE_TH -> {
                        // Parse T&H frame
                        val th = BeaconXParser.getTH(validData.data)
                        frames["th"] = mapOf(
                            "temperature" to th.temperature,
                            "humidity" to th.humidity,
                            "rangingData" to th.rangingData
                        )
                        android.util.Log.d("BeaconX-SDK", "[$mac] 🌡️ T&H: temp=${th.temperature}°C, humidity=${th.humidity}%")
                    }
                }
            }
            
            // Send accumulated frames to Flutter
            eventSink?.success(frames.toMap())
        } catch (e: Exception) {
            android.util.Log.e("BeaconX-SDK", "Error processing scan result: ${e.message}")
            e.printStackTrace()
        }
    }

    private fun stopScan() {
        if (!isScanning) return
        mokoBleScanner?.stopScanDevice()
        mokoBleScanner = null
        isScanning = false
        android.util.Log.d("BeaconX-SDK", "MokoBleScanner stopped")
    }
    
    private fun tryConnectNextBeacon() {
        if (connectingMac != null) return
        
        // Find a beacon that doesn't have namespace yet
        val beaconWithoutNamespace = beaconFrames.entries.firstOrNull { (_, frames) ->
            !frames.containsKey("uid")
        }
        
        if (beaconWithoutNamespace != null) {
            val mac = beaconWithoutNamespace.key
            android.util.Log.d("BeaconX-SDK", "[$mac] Found beacon without namespace, triggering GATT read...")
            connectingMac = mac
            MokoSupport.getInstance().connDevice(mac)
        } else {
            android.util.Log.d("BeaconX-SDK", "All beacons have namespace, no more GATT reads needed")
        }
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
                android.util.Log.d("BeaconX-GATT", "Connected! Getting unlock challenge first (like official app)...")
                // Step 1: Read CHAR_UNLOCK to get the 16-byte challenge
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    val getUnlockTask = com.moko.support.nordic.OrderTaskAssembler.getUnLock()
                    MokoSupport.getInstance().sendOrder(getUnlockTask)
                }, 500)
            }
            "ACTION_DISCONNECTED" -> {
                android.util.Log.d("BeaconX-GATT", "Disconnected")
                connectingMac = null
                
                // Check if there are other beacons that need namespace reading
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    tryConnectNextBeacon()
                }, 1000)
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
                val data = response.responseValue
                android.util.Log.d("BeaconX-GATT", "🔐 CHAR_UNLOCK response: ${data?.joinToString("") { "%02x".format(it) }}")
                
                if (response.responseType == com.moko.ble.lib.task.OrderTask.RESPONSE_TYPE_READ) {
                    // Step 2: Got challenge, now send unlock with password
                    if (data != null && data.isNotEmpty()) {
                        android.util.Log.d("BeaconX-GATT", "Got challenge, sending unlock with password...")
                        val unlockTask = com.moko.support.nordic.OrderTaskAssembler.setUnLock(beaconPassword, data)
                        if (unlockTask != null) {
                            MokoSupport.getInstance().sendOrder(unlockTask)
                        }
                    }
                } else if (response.responseType == com.moko.ble.lib.task.OrderTask.RESPONSE_TYPE_WRITE) {
                    // Step 3: Unlock written, now verify by reading lock state
                    android.util.Log.d("BeaconX-GATT", "Unlock sent, verifying lock state...")
                    val getLockStateTask = com.moko.support.nordic.OrderTaskAssembler.getLockState()
                    MokoSupport.getInstance().sendOrder(getLockStateTask)
                }
            }
            OrderCHAR.CHAR_LOCK_STATE -> {
                val data = response.responseValue
                val lockState = if (data != null && data.isNotEmpty()) data[0].toInt() and 0xFF else -1
                android.util.Log.d("BeaconX-GATT", "🔓 Lock state: ${data?.joinToString("") { "%02x".format(it) }} (${if (lockState == 0) "LOCKED" else if (lockState == 2) "NO_PASSWORD" else "UNLOCKED"})")
                
                // Step 4: Now unlocked, read device type then slot types
                if (lockState != 0) {
                    android.util.Log.d("BeaconX-GATT", "✅ Unlocked! Now reading device type...")
                    val getDeviceTypeTask = com.moko.support.nordic.OrderTaskAssembler.getDeviceType()
                    MokoSupport.getInstance().sendOrder(getDeviceTypeTask)
                } else {
                    android.util.Log.d("BeaconX-GATT", "❌ Still locked! Password may be wrong.")
                    MokoSupport.getInstance().disConnectBle()
                    connectingMac = null
                }
            }
            OrderCHAR.CHAR_DEVICE_TYPE -> {
                val data = response.responseValue
                android.util.Log.d("BeaconX-GATT", "📱 Device type: ${data?.joinToString("") { "%02x".format(it) }}")
                
                // Step 5: Now read slot types
                android.util.Log.d("BeaconX-GATT", "Reading slot types...")
                val getSlotTypeTask = com.moko.support.nordic.OrderTaskAssembler.getSlotType()
                MokoSupport.getInstance().sendOrder(getSlotTypeTask)
            }
            OrderCHAR.CHAR_SLOT_TYPE -> {
                val data = response.responseValue ?: return
                android.util.Log.d("BeaconX-GATT", "📊 Slot types: ${data.joinToString("") { "%02x".format(it) }}")
                
                // Parse slot types: value[0]=SLOT1, value[1]=SLOT2, etc.
                // Type 0x00 = UID, 0x10 = URL, 0x20 = TLM, 0x50 = iBeacon, 0x60 = ACC, 0x70 = T&H
                for (i in data.indices) {
                    val slotType = data[i].toInt() and 0xFF
                    android.util.Log.d("BeaconX-GATT", "  Slot ${i + 1}: type=0x${slotType.toString(16)}")
                    
                    if (slotType == 0x00) {
                        android.util.Log.d("BeaconX-GATT", "  → Slot ${i + 1} is UID!")
                    }
                }
                
                // Now read the slot data for slot 1 (default active slot)
                android.util.Log.d("BeaconX-GATT", "Reading slot data...")
                val getSlotDataTask = com.moko.support.nordic.OrderTaskAssembler.getSlotData()
                MokoSupport.getInstance().sendOrder(getSlotDataTask)
            }
            OrderCHAR.CHAR_ADV_SLOT_DATA -> {
                val data = response.responseValue ?: return
                android.util.Log.d("BeaconX-GATT", "📊 Slot data: ${data.joinToString("") { "%02x".format(it) }}")
                
                // Parse slot data (check if UID)
                val foundUid = parseSlotData(mac, data)
                
                android.util.Log.d("BeaconX-GATT", "Slot data parsed, foundUid=$foundUid. Disconnecting...")
                MokoSupport.getInstance().disConnectBle()
                connectingMac = null
            }
            OrderCHAR.CHAR_PARAMS -> {
                val data = response.responseValue
                android.util.Log.d("BeaconX-GATT", "📊 CHAR_PARAMS response: ${data?.joinToString("") { "%02x".format(it) }}")
                
                // CHAR_PARAMS works! Parse the response
                // Format: EB [cmd] 00 [len] [data...]
                // cmd 0x20 = device MAC, cmd 0x21 = axis params
                if (data != null && data.size >= 4) {
                    val cmd = data[1].toInt() and 0xFF
                    val len = data[3].toInt() and 0xFF
                    
                    when (cmd) {
                        0x20 -> {
                            // Device MAC response
                            if (data.size >= 4 + len) {
                                val macBytes = data.copyOfRange(4, 4 + len)
                                val macStr = macBytes.joinToString(":") { "%02X".format(it) }
                                android.util.Log.d("BeaconX-GATT", "✅ Device MAC: $macStr")
                            }
                        }
                        0x21 -> {
                            // Axis params response
                            android.util.Log.d("BeaconX-GATT", "✅ Axis params received")
                        }
                    }
                }
                
                // Disconnect after getting response
                android.util.Log.d("BeaconX-GATT", "GATT communication verified. Disconnecting...")
                MokoSupport.getInstance().disConnectBle()
                connectingMac = null
            }
            else -> {
                android.util.Log.d("BeaconX-GATT", "Unhandled characteristic: ${response.orderCHAR}, data=${response.responseValue?.joinToString("") { "%02x".format(it) }}")
                
                // If we got any response, disconnect after logging
                if (response.responseValue != null) {
                    android.util.Log.d("BeaconX-GATT", "Got response, disconnecting...")
                    MokoSupport.getInstance().disConnectBle()
                    connectingMac = null
                }
            }
        }
    }

    private fun parseSlotData(mac: String, data: ByteArray): Boolean {
        if (data.size < 2) return false
        
        val frameType = data[0].toInt() and 0xFF
        android.util.Log.d("BeaconX-GATT", "Slot data frame type: 0x${frameType.toString(16)}")
        
        // Frame type 0x00 = UID (Eddystone UID frame)
        if (frameType == 0x00 && data.size >= 18) {
            val txPower = data[1].toInt()
            val namespace = data.copyOfRange(2, 12).joinToString("") { "%02X".format(it) }
            val instance = data.copyOfRange(12, 18).joinToString("") { "%02X".format(it) }
            
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
            return true
        }
        return false
    }

}
