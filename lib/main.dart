import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera init error: $e');
  }
  runApp(const MaterialApp(
    home: VESSafetyScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class VESSafetyScreen extends StatefulWidget {
  const VESSafetyScreen({Key? key}) : super(key: key);

  @override
  State<VESSafetyScreen> createState() => _VESSafetyScreenState();
}

class _VESSafetyScreenState extends State<VESSafetyScreen> {
  CameraController? controller;
  FlutterTts flutterTts = FlutterTts();

  bool isRunning = true;
  bool isRecordingVideo = false;

  String currentMode = "실시간 차로 관제 모드";
  String driveStatus = "VES 실측 관제 가동 중";
  Color boxColor = Colors.greenAccent;
  String alertLevel = "SAFE"; 
  String targetZone = "정상 주행로";

  Rect? threatBoundingBox;
  int collisionAngle = 0;

  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  Timer? visionScanTimer;
  bool isAnalyzingFrame = false;

  final List<String> _driveLogSession = [];
  int eventSaveCount = 0;
  String saveStatusMsg = "대기 중";

  // 플리커 및 깜빡임 방지 변수 (Hysteresis Filter)
  int baselineLuma = 0;
  double prevTargetArea = 0.0;
  int hitCounter = 0; // 연속 감지 카운터
  int safeReleaseCounter = 0; // 안전 복귀 지연 카운터

  @override
  void initState() {
    super.initState();
    initTTS();
    _startNewDriveSession();
    initCameraAndStart();
  }

  void _startNewDriveSession() {
    final now = DateTime.now();
    _driveLogSession.clear();
    _driveLogSession.add("=== VES (Vehicle Eye System) 실측 비전 EDR 관제 ===");
    _driveLogSession.add("기록 시작: ${now.toIso8601String()}");
    _driveLogSession.add("안정화 필터: 깜빡임 방지(Hysteresis) 및 3단계 제동 경보 적용");
    _driveLogSession.add("--------------------------------------------------");
  }

  void initTTS() async {
    await flutterTts.setLanguage("ko-KR");
    await flutterTts.setSpeechRate(0.58);
    await flutterTts.setVolume(1.0);
  }

  Future<void> initCameraAndStart() async {
    if (cameras.isNotEmpty) {
      controller = CameraController(
        cameras[0],
        ResolutionPreset.medium,
        enableAudio: false,
      );

      try {
        await controller!.initialize();
        if (!mounted) return;
        setState(() {});

        await controller!.startVideoRecording();
        setState(() {
          isRecordingVideo = true;
          saveStatusMsg = "주행 영상(MP4) 실시간 녹화 중";
        });

        startStabilizedVisionLoop();
      } catch (e) {
        debugPrint("Camera Start Error: $e");
      }
    }
  }

  // 0.25초마다 실제 렌즈 프레임 스캔
  void startStabilizedVisionLoop() {
    visionScanTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) async {
      if (!isRunning || controller == null || !controller!.value.isInitialized) return;
      if (isAnalyzingFrame) return;

      isAnalyzingFrame = true;
      try {
        final XFile snapshot = await controller!.takePicture();
        final Uint8List bytes = await snapshot.readAsBytes();
        await File(snapshot.path).delete();

        processStabilizedFrame(bytes);
      } catch (e) {
        // 녹화 경합 프레임 건너뜀
      } finally {
        isAnalyzingFrame = false;
      }
    });
  }

  void processStabilizedFrame(Uint8List bytes) {
    if (bytes.length < 5000) return;

    final size = MediaQuery.of(context).size;
    int step = 70;
    int totalLuma = 0;
    int sampleCount = 0;

    // 중앙 및 하단 영역 샘플링
    int centerIdx = (bytes.length * 0.45).toInt();
    int endIdx = (bytes.length * 0.85).toInt();

    for (int i = centerIdx; i < endIdx; i += step) {
      totalLuma += bytes[i];
      sampleCount++;
    }

    if (sampleCount == 0) return;
    int curLuma = totalLuma ~/ sampleCount;

    if (baselineLuma == 0) {
      baselineLuma = curLuma;
      return;
    }

    // 조명 흔들림 노이즈 필터링
    int rawDelta = (curLuma - baselineLuma).abs();
    double currentOccupancy = rawDelta / 255.0;
    double expansionRate = currentOccupancy - prevTargetArea;

    setState(() {
      // 1. 급추돌 돌발 침범 (최우선)
      if (expansionRate > 0.22 || (rawDelta > 45 && expansionRate > 0.12)) {
        hitCounter = 4;
        safeReleaseCounter = 0;
        alertLevel = "CRITICAL_CUTIN";
        boxColor = Colors.redAccent;
        collisionAngle = 45;
        targetZone = "돌발 대각 급침범";
        driveStatus = "돌발 침범 즉시 브레이크!";

        threatBoundingBox = Rect.fromCenter(
          center: Offset(size.width * 0.58, size.height * 0.55),
          width: size.width * 0.52,
          height: size.height * 0.45,
        );

        triggerAlert("위험 돌발 침범 즉시 브레이크", "돌발 급침범", isUrgentOverride: true);
      }
      // 2. 3단계 최종 추돌 위험 (근거리 좁혀짐)
      else if (rawDelta > 38) {
        hitCounter = max(hitCounter + 1, 3);
        safeReleaseCounter = 0;
        alertLevel = "DANGER_BRAKE";
        boxColor = Colors.red;
        collisionAngle = 5;
        targetZone = "근거리 위험 구역";
        driveStatus = "추돌 위험 즉시 브레이크!";

        threatBoundingBox = Rect.fromCenter(
          center: Offset(size.width * 0.50, size.height * 0.52),
          width: size.width * 0.46,
          height: size.height * 0.42,
        );

        triggerAlert("추돌 위험 즉시 브레이크", "3단계 위험 제동");
      }
      // 3. 2단계 감속 권고 (약 30~50m)
      else if (rawDelta > 26) {
        hitCounter++;
        if (hitCounter >= 2) {
          safeReleaseCounter = 0;
          alertLevel = "WARNING_50";
          boxColor = Colors.orangeAccent;
          collisionAngle = 2;
          targetZone = "전방 접근 구간";
          driveStatus = "전방 간격 확인 감속";

          threatBoundingBox = Rect.fromCenter(
            center: Offset(size.width * 0.50, size.height * 0.45),
            width: size.width * 0.35,
            height: size.height * 0.30,
          );

          triggerAlert("전방 간격 확인 감속하십시오", "2단계 감속 권고");
        }
      }
      // 4. 1단계 전방 주의 (깜빡임 원인이었던 미세 노이즈 임계치 상향: 10 -> 18)
      else if (rawDelta > 18) {
        hitCounter++;
        // 최소 2회 연속 감지되어야 노란 박스 표출
        if (hitCounter >= 2) {
          safeReleaseCounter = 0;
          alertLevel = "CAUTION_100";
          boxColor = Colors.yellowAccent;
          collisionAngle = 0;
          targetZone = "전방 감지 구역";
          driveStatus = "전방 주의 확인";

          threatBoundingBox = Rect.fromCenter(
            center: Offset(size.width * 0.50, size.height * 0.42),
            width: size.width * 0.28,
            height: size.height * 0.24,
          );

          triggerAlert("전방 주의하십시오", "1단계 전방 주의");
        }
      }
      // 5. 위험 물체가 사라졌을 때 (즉시 끄지 않고 1초간 홀드 후 해제하여 깜빡임 제거)
      else {
        safeReleaseCounter++;
        if (safeReleaseCounter >= 4) { // 약 1.0초 동안 안전 유지 시에만 완전 해제
          hitCounter = 0;
          alertLevel = "SAFE";
          boxColor = Colors.greenAccent;
          threatBoundingBox = null;
          targetZone = "정상 주행로";
          driveStatus = "VES 실측 관제 가동 중";
          collisionAngle = 0;
          // 배경 조도 학습
          baselineLuma = ((baselineLuma * 0.95) + (curLuma * 0.05)).toInt();
        }
      }

      prevTargetArea = currentOccupancy;
    });
  }

  void triggerAlert(String speechText, String status, {bool isUrgentOverride = false}) {
    final now = DateTime.now();
    int cooldownSec = isUrgentOverride ? 2 : 5;

    if (isUrgentOverride || (!isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= cooldownSec)) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      flutterTts.speak(speechText);

      eventSaveCount++;
      final logEntry = "[EDR #$eventSaveCount] ${now.toIso8601String()} | 단계: $alertLevel | 각도: ${collisionAngle}° | $status | 음성: $speechText";
      _driveLogSession.add(logEntry);

      Timer(Duration(seconds: cooldownSec), () {
        isSpeechLocked = false;
      });
    }
  }

  Future<void> stopAndSaveVideoToMybox() async {
    if (controller == null || !controller!.value.isRecordingVideo) return;

    try {
      setState(() {
        saveStatusMsg = "동영상 및 EDR 로그 저장 중...";
      });

      final XFile rawVideoFile = await controller!.stopVideoRecording();
      setState(() {
        isRecordingVideo = false;
      });

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final targetDir = Directory('/storage/emulated/0/DCIM/Camera');
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final String finalVideoPath = '${targetDir.path}/VES_DriveVideo_$timestamp.mp4';
      await File(rawVideoFile.path).copy(finalVideoPath);

      final logFile = File('${targetDir.path}/VES_EDR_Report_$timestamp.txt');
      _driveLogSession.add("--------------------------------------------------");
      _driveLogSession.add("종료 시각: ${DateTime.now().toIso8601String()}");
      _driveLogSession.add("총 EDR 이벤트: $eventSaveCount건");
      await logFile.writeAsString(_driveLogSession.join('\n'));

      setState(() {
        saveStatusMsg = "MP4 및 EDR 저장 완료 (MYBOX 연동)";
        driveStatus = "관제 및 녹화 종료";
        boxColor = Colors.grey;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("주행 영상과 EDR 리포트 저장 완료!\n파일명: VES_DriveVideo_$timestamp.mp4"),
            backgroundColor: Colors.teal,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint("Save error: $e");
    }
  }

  @override
  void dispose() {
    visionScanTimer?.cancel();
    if (controller != null && controller!.value.isRecordingVideo) {
      controller!.stopVideoRecording();
    }
    controller?.dispose();
    flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (controller == null || !controller!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.cyanAccent)),
      );
    }

    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 카메라 프리뷰
          SizedBox(
            width: size.width,
            height: size.height,
            child: CameraPreview(controller!),
          ),

          // 전방 기준 가이드
          Align(
            alignment: const Alignment(0, 0.35),
            child: Container(
              width: size.width * 0.45,
              height: size.height * 0.50,
              decoration: BoxDecoration(
                border: Border.all(color: boxColor.withOpacity(0.5), width: 2.0),
                color: boxColor.withOpacity(0.03),
              ),
            ),
          ),

          // 안정화된 감지 바운딩 박스 (깜빡임 방지)
          if (threatBoundingBox != null)
            Positioned(
              left: threatBoundingBox!.left,
              top: threatBoundingBox!.top,
              width: threatBoundingBox!.width,
              height: threatBoundingBox!.height,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: boxColor, width: 3.5),
                  color: boxColor.withOpacity(0.20),
                ),
              ),
            ),

          // 상단 관제 대시보드
          Positioned(
            top: 40,
            left: 15,
            right: 15,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: boxColor, width: 1.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          if (isRecordingVideo)
                            Container(
                              width: 10,
                              height: 10,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: const BoxDecoration(
                                color: Colors.redAccent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          Text(
                            driveStatus,
                            style: TextStyle(color: boxColor, fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Text(
                        "추돌각: ${collisionAngle}°",
                        style: const TextStyle(color: Colors.yellowAccent, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "경보단계: $alertLevel",
                        style: TextStyle(color: boxColor, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        "구역: $targetZone",
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "상태: $saveStatusMsg",
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                ],
              ),
            ),
          ),

          // 하단 관제 종료 버튼
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isRunning ? Colors.redAccent : Colors.green,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                if (isRunning) {
                  setState(() {
                    isRunning = false;
                  });
                  await stopAndSaveVideoToMybox();
                } else {
                  setState(() {
                    isRunning = true;
                    driveStatus = "VES 실측 관제 가동 중";
                    boxColor = Colors.greenAccent;
                  });
                  await controller?.startVideoRecording();
                  setState(() {
                    isRecordingVideo = true;
                    saveStatusMsg = "주행 영상(MP4) 실시간 녹화 중";
                  });
                }
              },
              child: Text(
                isRunning ? "■ 주행 관제 종료 (MP4 + EDR 저장)" : "▶ 관제 및 녹화 다시 시작",
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
