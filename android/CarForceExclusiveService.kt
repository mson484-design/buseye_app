package com.buseye.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.*
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.text.format.Formatter
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

class CarForceExclusiveService : Service(), TextToSpeech.OnInitListener {

    private val TAG = "BusEye_CarForce"
    private lateinit var connectivityManager: ConnectivityManager
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val serviceScope = CoroutineScope(Dispatchers.IO + Job())
    private val handler = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null

    private val ONE_HOUR_MS = 60 * 60 * 1000L // 1시간 무인 타이머

    override fun onCreate() {
        super.onCreate()
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        tts = TextToSpeech(this, this)
        startForegroundNotification()
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            tts?.language = Locale.KOREAN
            speak("승용차 안전 감시를 시작합니다.")
        }
    }

    private fun speak(text: String) {
        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, null)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val ssid = intent?.getStringExtra("EXTRA_SSID") ?: "DASHCAM_WIFI"
        val pass = intent?.getStringExtra("EXTRA_PASS") ?: ""

        startOneTouchPipeline(ssid, pass)
        return START_STICKY // 화면 전환 시 강제 종료 방지
    }

    private fun startOneTouchPipeline(ssid: String, pass: String) {
        val specifierBuilder = WifiNetworkSpecifier.Builder().setSsid(ssid)
        if (pass.isNotEmpty()) specifierBuilder.setWpa2Passphrase(pass)

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) // 팝업 차단
            .setNetworkSpecifier(specifierBuilder.build())
            .build()

        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                super.onAvailable(network)
                connectivityManager.bindProcessToNetwork(network)
                Log.d(TAG, "블랙박스 Wi-Fi 점유 완료")

                serviceScope.launch {
                    val gatewayIp = getGatewayIp()
                    robustWakeUpLoop(gatewayIp)
                    speak("블랙박스 연결 완료. 1시간 자동 녹화를 시작합니다.")
                }

                // 1시간 타이머
                handler.postDelayed({
                    stopAndUploadSequence()
                }, ONE_HOUR_MS)
            }
        }

        connectivityManager.requestNetwork(request, networkCallback!!)
    }

    private suspend fun robustWakeUpLoop(gatewayIp: String) = withContext(Dispatchers.IO) {
        val triggerUrls = listOf(
            "http://$gatewayIp/cgi-bin/start_stream.cgi",
            "http://$gatewayIp/?action=command&command=start_live",
            "http://$gatewayIp/api/v1/live/start"
        )
        // 3회 반복 전송
        repeat(3) {
            for (urlStr in triggerUrls) {
                try {
                    val conn = URL(urlStr).openConnection() as HttpURLConnection
                    conn.connectTimeout = 800
                    conn.requestMethod = "GET"
                    conn.responseCode
                } catch (e: Exception) {}
            }
            delay(1000)
        }
    }

    private fun stopAndUploadSequence() {
        speak("1시간 주행이 완료되어 영상을 전송하고 앱을 종료합니다.")
        connectivityManager.bindProcessToNetwork(null)
        networkCallback?.let {
            try { connectivityManager.unregisterNetworkCallback(it) } catch (e: Exception) {}
        }

        serviceScope.launch {
            delay(3000) // 마이박스 업로드 루틴
            withContext(Dispatchers.Main) {
                tts?.shutdown()
                stopForeground(true)
                stopSelf()
                android.os.Process.killProcess(android.os.Process.myPid())
            }
        }
    }

    private fun getGatewayIp(): String {
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        return Formatter.formatIpAddress(wifiManager.dhcpInfo.gateway).takeIf { it != "0.0.0.0" } ?: "192.168.1.1"
    }

    private fun startForegroundNotification() {
        val channelId = "buseye_car_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, "BusEye Service", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }

        val notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("BusEye 승용차 독점 관제 중")
            .setContentText("1시간 무인 녹화 및 위험 감시 중 (종료 후 자동 업로드)")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .build()

        startForeground(1001, notification)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        serviceScope.cancel()
        tts?.shutdown()
    }
}
