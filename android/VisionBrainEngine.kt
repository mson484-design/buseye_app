package com.buseye.safety

import android.graphics.Bitmap

/**
 * BusEye AI 두뇌 엔진
 * - 스마트폰 카메라는 완전히 배제
 * - 차량 블랙박스에서 수신된 실내/우측 사각지대 RTSP 스트림만 집중 분석
 */
class VisionBrainEngine(private val audioPriorityManager: AudioPriorityManager) {

    private var isWarningCooldown = false

    // 블랙박스 사각지대 전용 채널 분석
    fun processBlackboxFrame(frameBitmap: Bitmap, channelId: Int) {
        when (channelId) {
            // 채널 1: 실내 승객석 사각지대 (미착석, 이동, 넘어짐)
            1 -> analyzePassengerSafety(frameBitmap)
            
            // 채널 2: 우측 및 하차문 사각지대 (우회전 보행자, 문 끼임)
            2 -> analyzeBlindSpotHazard(frameBitmap)
        }
    }

    // 1. 실내 승객석 사각지대 판별
    private fun analyzePassengerSafety(bitmap: Bitmap) {
        val isStanding = detectUnseatedPassenger(bitmap)
        if (isStanding && !isWarningCooldown) {
            triggerVoiceWarning("승객이 아직 착석하지 않았습니다. 서행하세요.")
        }
    }

    // 2. 우측 사각지대 위험 판별
    private fun analyzeBlindSpotHazard(bitmap: Bitmap) {
        val hasPedestrian = detectBlindSpotObstacle(bitmap)
        if (hasPedestrian && !isWarningCooldown) {
            triggerVoiceWarning("우측 사각지대에 보행자가 있습니다. 주의하세요.")
        }
    }

    private fun detectUnseatedPassenger(bitmap: Bitmap): Boolean {
        // 온디바이스 NPU 추론: 관절(Pose) 및 기립 객체 감지
        return true 
    }

    private fun detectBlindSpotObstacle(bitmap: Bitmap): Boolean {
        // 온디바이스 NPU 추론: 우측 사각지대 보행자/이륜차 감지
        return false
    }

    private fun triggerVoiceWarning(message: String) {
        isWarningCooldown = true
        audioPriorityManager.speakCriticalWarning(0)
        
        // 중복 경고 방지 쿨다운 (3초)
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            isWarningCooldown = false
        }, 3000)
    }
}
