package com.buseye.app

import android.app.Activity
import android.media.AudioAttributes
import android.net.Uri
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.util.Log
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.VideoView
import java.util.Locale

class MainActivity : Activity(), TextToSpeech.OnInitListener {

    private val TAG = "BusEye_LiveDirect"
    private var tts: TextToSpeech? = null
    private lateinit var videoView: VideoView
    private lateinit var statusOverlay: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // 화면 꺼짐 방지
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // UI 레이아웃 동적 강제 생성 (플러터 가림막 우회)
        val rootLayout = FrameLayout(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            setBackgroundColor(android.graphics.Color.BLACK)
        }

        videoView = VideoView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        }

        statusOverlay = TextView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = 60
                leftMargin = 40
            }
            text = "캐치온 실시간 영상 연결 시도 중..."
            setTextColor(android.graphics.Color.CYAN)
            textSize = 18f
        }

        rootLayout.addView(videoView)
        rootLayout.addView(statusOverlay)
        setContentView(rootLayout)

        tts = TextToSpeech(this, this)
        playDirectStream()
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            tts?.language = Locale.KOREAN
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            tts?.setAudioAttributes(audioAttributes)
            speakOut("캐치온 영상을 직접 연결합니다.")
        }
    }

    private fun speakOut(text: String) {
        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "BusEyeTTS")
    }

    private fun playDirectStream() {
        val streamUrl = "rtsp://192.168.1.1:554/live/ch0" // 캐치온 메인 채널
        
        try {
            val uri = Uri.parse(streamUrl)
            videoView.setVideoURI(uri)
            videoView.setOnPreparedListener { mp ->
                mp.start()
                statusOverlay.text = "● BusEye 실시간 관제 중 (캐치온 3CH)"
                statusOverlay.setTextColor(android.graphics.Color.GREEN)
                speakOut("영상이 정상 출력됩니다.")
            }
            videoView.setOnErrorListener { _, what, extra ->
                Log.e(TAG, "RTSP 수신 대기 (재시도 중): what=$what, extra=$extra")
                statusOverlay.text = "영상 신호 대기 중... (재연결 시도)"
                statusOverlay.setTextColor(android.graphics.Color.YELLOW)
                videoView.postDelayed({ playDirectStream() }, 2500)
                true
            }
        } catch (e: Exception) {
            Log.e(TAG, "스트림 에러", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        tts?.stop()
        tts?.shutdown()
    }
}
