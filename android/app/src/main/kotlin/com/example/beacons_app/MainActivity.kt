package com.example.beacons_app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.elvishew.xlog.LogLevel
import com.elvishew.xlog.XLog
import com.moko.ble.lib.event.ConnectStatusEvent
import com.moko.ble.lib.event.OrderTaskResponseEvent
import com.moko.ble.lib.task.OrderTask
import com.moko.bxp.nordic.entity.BeaconXInfo
import com.moko.bxp.nordic.utils.BeaconXInfoParseableImpl
import com.moko.bxp.nordic.utils.BeaconXParser
import com.moko.support.nordic.MokoBleScanner
import com.moko.support.nordic.MokoSupport
import com.moko.support.nordic.OrderTaskAssembler
import com.moko.support.nordic.callback.MokoScanDeviceCallback
import com.moko.support.nordic.entity.DeviceInfo
import com.moko.support.nordic.entity.OrderCHAR
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.greenrobot.eventbus.EventBus
import org.greenrobot.eventbus.Subscribe
import org.greenrobot.eventbus.ThreadMode
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.example.beacons_app/ble"
        private const val EVENT_CHANNEL = "com.example.beacons_app/ble_scan"
        private const val REQUEST_CODE_PERMISSIONS = 100
        private const val BEACON_PASSWORD = "Moko4321"
        private const val UI_UPDATE_INTERVAL_MS = 500L
    }

    // BLE scanning
    private var mokoBleScanner: MokoBleScanner? = null
    private var beaconXInfoParser: BeaconXInfoParseableImpl? = null
    private var isScanning = false

    // Data storage (thread-safe)
    private val beaconInfoMap = ConcurrentHashMap<String, BeaconXInfo>()
    private val beaconFrames = ConcurrentHashMap<String, MutableMap<String, Any?>>()
    private val gattQueue = ConcurrentLinkedQueue<String>()

    // GATT connection
    private var connectingMac: String? = null

    // Flutter communication
    private var eventSink: EventChannel.EventSink? = null

    // Periodic updates
    private val handler = Handler(Looper.getMainLooper())
    private var updateRunnable: Runnable? = null

    // region Lifecycle

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        XLog.init(LogLevel.NONE)
        EventBus.getDefault().register(this)
        MokoSupport.getInstance().init(applicationContext)
    }

    override fun onDestroy() {
        super.onDestroy()
        EventBus.getDefault().unregister(this)
        stopScan()
    }

    // endregion

    // region Flutter Engine

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupMethodChannel(flutterEngine)
        setupEventChannel(flutterEngine)
    }

    private fun setupMethodChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startScan" -> handleStartScan(result)
                "stopScan" -> handleStopScan(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun setupEventChannel(flutterEngine: FlutterEngine) {
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

    private fun handleStartScan(result: MethodChannel.Result) {
        if (checkPermissions()) {
            startScan()
            result.success(true)
        } else {
            requestPermissions()
            result.error("PERMISSION_DENIED", "Bluetooth permissions required", null)
        }
    }

    private fun handleStopScan(result: MethodChannel.Result) {
        stopScan()
        result.success(true)
    }

    // endregion

    // region Permissions

    private fun checkPermissions(): Boolean {
        return getRequiredPermissions().all {
            ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestPermissions() {
        ActivityCompat.requestPermissions(this, getRequiredPermissions(), REQUEST_CODE_PERMISSIONS)
    }

    private fun getRequiredPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
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
    }

    // endregion

    // region Scanning

    private fun startScan() {
        if (isScanning) return

        beaconInfoMap.clear()
        beaconXInfoParser = BeaconXInfoParseableImpl()
        mokoBleScanner = MokoBleScanner(this)

        mokoBleScanner?.startScanDevice(object : MokoScanDeviceCallback {
            override fun onStartScan() {
                isScanning = true
                startPeriodicUpdates()
            }

            override fun onScanDevice(deviceInfo: DeviceInfo) {
                processDeviceInfo(deviceInfo)
            }

            override fun onStopScan() {
                isScanning = false
                stopPeriodicUpdates()
            }
        })
    }

    private fun stopScan() {
        if (!isScanning) return
        stopPeriodicUpdates()
        mokoBleScanner?.stopScanDevice()
        mokoBleScanner = null
        isScanning = false
    }

    private fun startPeriodicUpdates() {
        updateRunnable = object : Runnable {
            override fun run() {
                if (isScanning) {
                    sendBeaconsToFlutter()
                    processGattQueue()
                    handler.postDelayed(this, UI_UPDATE_INTERVAL_MS)
                }
            }
        }
        handler.postDelayed(updateRunnable!!, UI_UPDATE_INTERVAL_MS)
    }

    private fun stopPeriodicUpdates() {
        updateRunnable?.let { handler.removeCallbacks(it) }
        updateRunnable = null
    }

    private fun sendBeaconsToFlutter() {
        beaconFrames.forEach { (_, frames) ->
            eventSink?.success(frames.toMap())
        }
    }

    // endregion

    // region GATT Queue

    private fun processGattQueue() {
        if (connectingMac != null) return

        val nextMac = gattQueue.poll() ?: return
        val hasUid = beaconFrames[nextMac]?.containsKey("uid") == true

        if (!hasUid) {
            connectingMac = nextMac
            MokoSupport.getInstance().connDevice(nextMac)
        } else {
            processGattQueue()
        }
    }

    // endregion
    
    // region Device Processing

    private fun processDeviceInfo(deviceInfo: DeviceInfo) {
        try {
            val mac = deviceInfo.mac
            val rssi = deviceInfo.rssi
            val name = deviceInfo.name ?: ""

            val beaconXInfo = beaconXInfoParser?.parseDeviceInfo(deviceInfo) ?: return
            beaconInfoMap[mac] = beaconXInfo

            // Queue for GATT read if doesn't have namespace yet
            val hasNamespace = beaconFrames[mac]?.containsKey("uid") == true
            if (!hasNamespace && !gattQueue.contains(mac)) {
                gattQueue.offer(mac)
            }

            // Initialize or update frame cache
            val frames = beaconFrames.getOrPut(mac) {
                mutableMapOf("mac" to mac, "name" to name, "rssi" to rssi)
            }
            frames["rssi"] = rssi

            // Parse frame data
            beaconXInfo.validDataHashMap?.values?.forEach { validData ->
                parseFrameData(frames, beaconXInfo, validData)
            }
        } catch (e: Exception) {
            // Silent fail - don't spam logs
        }
    }

    private fun parseFrameData(
        frames: MutableMap<String, Any?>,
        beaconXInfo: BeaconXInfo,
        validData: BeaconXInfo.ValidData
    ) {
        when (validData.type) {
            BeaconXInfo.VALID_DATA_FRAME_TYPE_UID -> {
                val uid = BeaconXParser.getUID(validData.data)
                frames["uid"] = mapOf(
                    "namespace" to uid.namespace,
                    "instance" to uid.instanceId,
                    "rangingData" to uid.rangingData
                )
            }
            BeaconXInfo.VALID_DATA_FRAME_TYPE_TLM -> {
                val tlm = BeaconXParser.getTLM(validData.data)
                frames["tlm"] = mapOf(
                    "vbatt" to tlm.vbatt,
                    "temp" to tlm.temp,
                    "adv_cnt" to tlm.adv_cnt
                )
            }
            BeaconXInfo.VALID_DATA_FRAME_TYPE_AXIS -> {
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
            }
            BeaconXInfo.VALID_DATA_FRAME_TYPE_TH -> {
                val th = BeaconXParser.getTH(validData.data)
                frames["th"] = mapOf(
                    "temperature" to th.temperature,
                    "humidity" to th.humidity,
                    "rangingData" to th.rangingData
                )
            }
        }
    }

    // endregion

    // region GATT Events

    @Subscribe(threadMode = ThreadMode.MAIN)
    fun onConnectStatusEvent(event: ConnectStatusEvent) {
        when (event.action) {
            "ACTION_DISCOVER_SUCCESS" -> {
                handler.postDelayed({
                    MokoSupport.getInstance().sendOrder(OrderTaskAssembler.getUnLock())
                }, 500)
            }
            "ACTION_DISCONNECTED" -> {
                connectingMac = null
            }
        }
    }

    @Subscribe(threadMode = ThreadMode.MAIN)
    fun onOrderTaskResponseEvent(event: OrderTaskResponseEvent) {
        val response = event.response ?: return
        val mac = connectingMac ?: return

        when (response.orderCHAR) {
            OrderCHAR.CHAR_UNLOCK -> handleUnlockResponse(response)
            OrderCHAR.CHAR_LOCK_STATE -> handleLockStateResponse(response)
            OrderCHAR.CHAR_DEVICE_TYPE -> handleDeviceTypeResponse()
            OrderCHAR.CHAR_SLOT_TYPE -> handleSlotTypeResponse()
            OrderCHAR.CHAR_ADV_SLOT_DATA -> handleSlotDataResponse(mac, response)
            else -> disconnectGatt()
        }
    }

    private fun handleUnlockResponse(response: com.moko.ble.lib.task.OrderTaskResponse) {
        val data = response.responseValue ?: return

        when (response.responseType) {
            OrderTask.RESPONSE_TYPE_READ -> {
                OrderTaskAssembler.setUnLock(BEACON_PASSWORD, data)?.let {
                    MokoSupport.getInstance().sendOrder(it)
                }
            }
            OrderTask.RESPONSE_TYPE_WRITE -> {
                MokoSupport.getInstance().sendOrder(OrderTaskAssembler.getLockState())
            }
        }
    }

    private fun handleLockStateResponse(response: com.moko.ble.lib.task.OrderTaskResponse) {
        val data = response.responseValue
        val lockState = if (data != null && data.isNotEmpty()) data[0].toInt() and 0xFF else -1

        if (lockState != 0) {
            MokoSupport.getInstance().sendOrder(OrderTaskAssembler.getDeviceType())
        } else {
            disconnectGatt()
        }
    }

    private fun handleDeviceTypeResponse() {
        MokoSupport.getInstance().sendOrder(OrderTaskAssembler.getSlotType())
    }

    private fun handleSlotTypeResponse() {
        MokoSupport.getInstance().sendOrder(OrderTaskAssembler.getSlotData())
    }

    private fun handleSlotDataResponse(mac: String, response: com.moko.ble.lib.task.OrderTaskResponse) {
        response.responseValue?.let { parseSlotData(mac, it) }
        disconnectGatt()
    }

    private fun disconnectGatt() {
        MokoSupport.getInstance().disConnectBle()
        connectingMac = null
    }

    // endregion

    // region UID Parsing

    private fun parseSlotData(mac: String, data: ByteArray): Boolean {
        if (data.size < 18) return false

        val frameType = data[0].toInt() and 0xFF
        if (frameType != 0x00) return false

        val txPower = data[1].toInt()
        val namespace = data.copyOfRange(2, 12).joinToString("") { "%02X".format(it) }
        val instance = data.copyOfRange(12, 18).joinToString("") { "%02X".format(it) }

        val frames = beaconFrames.getOrPut(mac) { mutableMapOf("mac" to mac) }
        frames["uid"] = mapOf(
            "namespace" to namespace,
            "instance" to instance,
            "rangingData" to txPower
        )

        eventSink?.success(frames.toMap())
        return true
    }

    // endregion
}
