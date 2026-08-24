package com.buseye.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*

class CarForceExclusiveService : Service() {

    private val TAG = "BusEye_CarForce"
    private lateinit var connectivityManager: ConnectivityManager
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val serviceScope = CoroutineScope(Dispatchers.IO + Job())
    private val handler = Handler(Looper.getMainLooper())

    private val ONE_HOUR_MS = 60 * 60 * 1000L // 1시간 무인 타이머

    override fun onCreate() {
        super.onCreate()
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        startForegroundServiceNotification()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val targetSsid = intent?.getStringExtra("EXTRA_SSID") ?: "DASHCAM_WIFI"
        val targetPassword = intent?.getStringExtra("EXTRA_PASS") ?: ""

        startCarExclusivePipeline(targetSsid, targetPassword)
        return START_NOT_STICKY
    }

    private fun startCarExclusivePipeline(ssid: String, pass: String) {
        val specifierBuilder = WifiNetworkSpecifier.Builder().setSsid(ssid)
        if (pass.isNotEmpty()) {
            specifierBuilder.setWpa2Passphrase(pass)
        }

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifierBuilder.build())
            .build()

        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                super.onAvailable(network)
                connectivityManager.bindProcessToNetwork(network)
                Log.d(TAG, "블랙박스 Wi-Fi 강제 독점 완료")

                // 1시간 타이머 가동
                handler.postDelayed({
                    stopAndUploadSequence()
                }, ONE_HOUR_MS)
            }
        }

        connectivityManager.requestNetwork(request, networkCallback!!)
    }

    private fun stopAndUploadSequence() {
        // Wi-Fi 해제 -> LTE 복구
        connectivityManager.bindProcessToNetwork(null)
        networkCallback?.let {
            try {
                connectivityManager.unregisterNetworkCallback(it)
            } catch (e: Exception) {
                Log.e(TAG, "Callback error: ${e.message}")
            }
        }

        serviceScope.launch {
            delay(3000) // 마이박스 백그라운드 전송 파이프라인
            withContext(Dispatchers.Main) {
                stopForeground(true)
                stopSelf()
                android.os.Process.killProcess(android.os.Process.myPid())
            }
        }
    }

    private fun startForegroundServiceNotification() {
        val channelId = "buseye_car_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "BusEye Car Exclusive Service",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }

        val notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("BusEye 승용차 독점 관제 중")
            .setContentText("블랙박스 Wi-Fi 독점 및 1시간 무인 녹화 중")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .build()

        startForeground(1001, notification)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        serviceScope.cancel()
    }
}
