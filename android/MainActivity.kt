package com.buseye.app

import android.content.Context
import android.media.AudioAttributes
import android.net.Uri
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.util.Log
import android.view.WindowManager
import android.widget.TextView
import android.widget.VideoView
import androidx.appcompat.app.AppCompatActivity
import java.util.Locale

class MainActivity : AppCompatActivity(), TextToSpeech.OnInitListener {

    private val TAG = "BusEye_Main"
    private var tts: TextToSpeech? = null
    private lateinit var videoView: VideoView
    private lateinit var statusText: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // 화면 꺼짐 방지
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)

        statusText = findViewById(R.id.statusText)
        videoView = findViewById(R.id.videoView)

        // 스마트폰 내장 스피커 음성 초기화
        tts = TextToSpeech(this, this)

        // 실시간 블랙박스 화면 출력 시작
        startDashcamLiveView()
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            tts?.language = Locale.KOREAN
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            tts?.setAudioAttributes(audioAttributes)
            
            speakOut("블랙박스 영상을 연결합니다. 폰 화면과 소리를 확인하세요.")
        }
    }

    private fun speakOut(text: String) {
        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "BusEyeTTS")
    }

    private fun startDashcamLiveView() {
        val streamUrl = "rtsp://192.168.1.1:554/live/ch0" // 캐치온 전방 메인 채널
        statusText.text = "캐치온 실시간 연결 중..."

        try {
            val uri = Uri.parse(streamUrl)
            videoView.setVideoURI(uri)
            videoView.setOnPreparedListener { mediaPlayer ->
                mediaPlayer.start()
                statusText.text = "정상주행 모니터링중 (영상 수신 완료)"
                speakOut("영상이 정상 연결되었습니다. 녹화를 시작합니다.")
            }
            videoView.setOnErrorListener { _, what, extra ->
                Log.e(TAG, "RTSP 수신 대기: what=$what, extra=$extra")
                statusText.text = "영상 신호 탐색 중..."
                videoView.postDelayed({ startDashcamLiveView() }, 2000)
                true
            }
        } catch (e: Exception) {
            Log.e(TAG, "비디오 뷰 에러", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        tts?.stop()
        tts?.shutdown()
    }
}
