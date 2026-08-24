package com.buseye.safety

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.buseye.safety/engine"
    private lateinit var controller: BusEyeController

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        controller = BusEyeController(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startSafetySystem" -> {
                    val ssid = call.argument<String>("ssid") ?: "BUS_DASHCAM_WIFI"
                    controller.startBusEyeSystem(ssid)
                    result.success("BusEye System Started")
                }
                "stopSafetySystem" -> {
                    controller.stopBusEyeSystem()
                    result.success("BusEye System Stopped")
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}
