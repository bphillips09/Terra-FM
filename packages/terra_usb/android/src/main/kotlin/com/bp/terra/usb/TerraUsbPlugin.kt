package com.bp.terra.usb

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.xmlpull.v1.XmlPullParser

/**
 * Finds USB tuners, obtains USB permission and hands Dart the file
 * descriptor of an open [UsbDeviceConnection]; libterra_core wraps it with
 * libusb (Android apps cannot enumerate /dev/bus/usb themselves).
 *
 * Lives as long as its Flutter engine, which audio_service may start without
 * an activity (media resumption, head units resuming playback at boot). The
 * connection stays open until Dart calls `close` (after the engine has
 * stopped using it) or the engine goes away.
 */
class TerraUsbPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.NewIntentListener {

    private companion object {
        const val ACTION_USB_PERMISSION = "com.bp.terra.USB_PERMISSION"
    }

    private lateinit var context: Context
    private lateinit var usb: UsbManager
    private lateinit var supported: Set<Pair<Int, Int>>
    private var methods: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var events: EventChannel.EventSink? = null
    private var activity: ActivityPluginBinding? = null
    private var connection: UsbDeviceConnection? = null
    private var launchDevice: UsbDevice? = null
    private var pendingPermission: MethodChannel.Result? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val device = intent.usbDevice()
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    val result = pendingPermission ?: return
                    pendingPermission = null
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    if (granted && device != null) open(device, result) else result.success(null)
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED ->
                    if (device != null && isSdr(device)) emit("attached", device)
                UsbManager.ACTION_USB_DEVICE_DETACHED ->
                    if (device != null && isSdr(device)) emit("detached", device)
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        usb = context.getSystemService(Context.USB_SERVICE) as UsbManager
        supported = loadDeviceFilter()
        methods = MethodChannel(binding.binaryMessenger, "com.bp.terra/usb").also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(binding.binaryMessenger, "com.bp.terra/usb_events").also { it.setStreamHandler(this) }

        val own = IntentFilter(ACTION_USB_PERMISSION)
        val system = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, own, Context.RECEIVER_NOT_EXPORTED)
            context.registerReceiver(receiver, system, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, own)
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, system)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        runCatching { context.unregisterReceiver(receiver) }
        methods?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methods = null
        eventChannel = null
        events = null
        pendingPermission = null
        connection?.close()
        connection = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addOnNewIntentListener(this)
        // USB attach launches the activity with the device in its intent.
        handleIntent(binding.activity.intent)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding
        binding.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        activity?.removeOnNewIntentListener(this)
        activity = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        handleIntent(intent)
        return false
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) return
        val device = intent.usbDevice() ?: return
        if (!isSdr(device)) return
        launchDevice = device
        emit("attached", device)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> result.success(usb.deviceList.values.filter(::isSdr).map(::describe))
            "open" -> {
                val id = call.argument<String>("id")
                val device = usb.deviceList[id]
                when {
                    device == null -> result.success(mapOf("fd" to -1, "error" to "Device is no longer connected"))
                    usb.hasPermission(device) -> open(device, result)
                    else -> requestPermission(device, result)
                }
            }
            "close" -> {
                connection?.close()
                connection = null
                result.success(null)
            }
            "takeLaunchDevice" -> {
                val device = launchDevice?.takeIf { usb.deviceList.containsKey(it.deviceName) }
                launchDevice = null
                result.success(device?.let(::describe))
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private fun open(device: UsbDevice, result: MethodChannel.Result) {
        connection?.close()
        val conn = usb.openDevice(device)
        if (conn == null) {
            connection = null
            result.success(mapOf("fd" to -1, "error" to "Android could not open ${device.productName ?: "the tuner"}"))
            return
        }
        connection = conn
        result.success(mapOf("fd" to conn.fileDescriptor))
    }

    private fun requestPermission(device: UsbDevice, result: MethodChannel.Result) {
        pendingPermission?.success(null)
        pendingPermission = result
        // The system fills in EXTRA_DEVICE / EXTRA_PERMISSION_GRANTED, so the
        // PendingIntent must be mutable; setPackage keeps it explicit.
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(context.packageName)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        usb.requestPermission(device, PendingIntent.getBroadcast(context, 0, intent, flags))
    }

    private fun emit(type: String, device: UsbDevice) {
        events?.success(mapOf("type" to type, "device" to describe(device)))
    }

    private fun isSdr(device: UsbDevice) = (device.vendorId to device.productId) in supported

    private fun describe(device: UsbDevice): Map<String, Any?> {
        val permitted = usb.hasPermission(device)
        val name = listOfNotNull(device.manufacturerName, device.productName)
            .joinToString(" ")
            .ifBlank { "Tuner" }
        return mapOf(
            "id" to device.deviceName,
            "name" to name,
            "permission" to permitted,
            "serial" to if (permitted) runCatching { device.serialNumber }.getOrNull() else null,
        )
    }

    private fun loadDeviceFilter(): Set<Pair<Int, Int>> {
        val ids = mutableSetOf<Pair<Int, Int>>()
        context.resources.getXml(R.xml.device_filter).use { xml ->
            while (xml.next() != XmlPullParser.END_DOCUMENT) {
                if (xml.eventType == XmlPullParser.START_TAG && xml.name == "usb-device") {
                    val vid = xml.getAttributeValue(null, "vendor-id")?.toIntOrNull() ?: continue
                    val pid = xml.getAttributeValue(null, "product-id")?.toIntOrNull() ?: continue
                    ids += vid to pid
                }
            }
        }
        return ids
    }

    private fun Intent.usbDevice(): UsbDevice? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }
}
