package com.buseye.safety

import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.*
import android.os.IBinder
import java.net.Socket

class BusEyeVisionService : Service() {

    private lateinit var connectivityManager: ConnectivityManager
    private var blackboxSocket: Socket? = null

    override fun onCreate() {
        super.onCreate()
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        bindBlackboxStreamPrioritized("BUS_DASHCAM_WIFI_SSID")
    }

    private fun bindBlackboxStreamPrioritized(targetSSID: String) {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(
                WifiNetworkSpecifier.Builder()
                    .setSsid(targetSSID)
                    .build()
            )
            .build()

        connectivityManager.requestNetwork(request, object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                super.onAvailable(network)
                Thread {
                    try {
                        blackboxSocket = Socket()
                        // 버스아이 비디오 소켓만 블박 Wi-Fi에 바인딩 (티맵/카톡은 LTE 유지)
                        network.bindSocket(blackboxSocket)
                        startVideoStreamProcessing(blackboxSocket)
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                }.start()
            }

            override fun onLost(network: Network) {
                super.onLost(network)
                blackboxSocket?.close()
            }
        })
    }

    private fun startVideoStreamProcessing(socket: Socket?) {
        // 영상 스트림 수신 및 AI 분석 엔진 구동부
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
