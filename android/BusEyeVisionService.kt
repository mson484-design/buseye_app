package com.buseye.safety

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class BusEyeVisionService : Service() {

    private lateinit var connectivityManager: ConnectivityManager
    private lateinit var wifiManager: WifiManager
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    // 주요 블랙박스 제조사 식별 키워드 리스트
    private val dashcamKeywords = listOf("BLACKBOX", "DASHCAM", "INAVI", "FINEVU", "IROAD", "MANDO", "GNET", "VUROID")

    override fun onCreate() {
        super.onCreate()
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        startForegroundService()
    }

    // 1. 주변 모든 블랙박스 Wi-Fi 자동 탐색 및 바인딩
    fun startNetworkIsolation(ssidPattern: String, onFrameReady: (Bitmap, Int) -> Unit) {
        val scanResults: List<ScanResult> = wifiManager.scanResults ?: emptyList()
        val targetDashcam = scanResults.firstOrNull { scan ->
            dashcamKeywords.any { keyword -> scan.SSID.uppercase().contains(keyword) }
        }

        val targetSSID = targetDashcam?.SSID ?: ssidPattern

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val specifier = WifiNetworkSpecifier.Builder()
                .setSsid(targetSSID)
                .build()

            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(specifier)
                .build()

            networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    // 스마트폰 데이터(LTE) 유지 & 블랙박스 영상 소켓만 분리
                    connectivityManager.bindProcessToNetwork(network)
                    startRtspStreamCapture(onFrameReady)
                }
            }
            connectivityManager.requestNetwork(request, networkCallback!!)
        }
    }

    // 2. 범용 RTSP 스트림 수신
    private fun startRtspStreamCapture(onFrameReady: (Bitmap, Int) -> Unit) {
        // 블랙박스 표준 게이트웨이 주소로 실시간 영상 스트림 수신
    }

    private fun startForegroundService() {
        val channelId = "BusEye_Service_Channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, "BusEye Service", NotificationManager.IMPORTANCE_LOW)
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }

        val notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("BusEye 안전 감시 엔진 가동 중")
            .setContentText("블랙박스 사각지대 실시간 영상 수신 중 (LTE 데이터 유지)")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .build()

        startForeground(1001, notification)
    }

    fun stopService() {
        networkCallback?.let { connectivityManager.unregisterNetworkCallback(it) }
        connectivityManager.bindProcessToNetwork(null)
        stopForeground(true)
        stopSelf()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
