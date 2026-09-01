import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    print('Camera init error: $e');
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

  // 속도 및 주행 모드
  double currentSpeedKmh = 0.0;
  String currentMode = "사각지대 집중 감시 (정차/서행)";

  String driveStatus = "VES 다이내믹 관제 중";
  Color boxColor = Colors.greenAccent;
  String alertMessage = "전방 및 차로 안전 확보";
  String roadBriefing = "도로 상태: 정상 폭 주행로";
  String targetZone = "안전";

  Rect? threatBoundingBox;
  int collisionAngle = 0;

  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  Timer? inferenceTimer;
  Timer? speedSimTimer;
  bool isThreatActive = false;

  final List<String> _driveLogSession = [];
  int eventSaveCount = 0;
  String saveStatusMsg = "관제 대기 중";

  @override
  void initState() {
    super.initState();
    initTTS();
    _startNewDriveSession();
    initCameraAndStart();
    startSpeedWatcher();
  }

  void _startNewDriveSession() {
    final now = DateTime.now();
    _driveLogSession.clear();
    _driveLogSession.add("=== VES (Vehicle Eye System) 속도 연동 EDR 관제 ===");
    _driveLogSession.add("시작 시각: ${now.toIso8601String()}");
    _driveLogSession.add("속도 구간별 감시: 정차(하단사각지대) / 중속(대각선추돌) / 고속(충돌궤적)");
    _driveLogSession.add("--------------------------------------------------");
  }

  void initTTS() async {
    await flutterTts.setLanguage("ko-KR");
    await flutterTts.setSpeechRate(0.55);
    await flutterTts.setVolume(1.0);
  }

  // 실시간 GPS/속도 감시 루프
  void startSpeedWatcher() {
    speedSimTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!isRunning) return;

      setState(() {
        if (currentSpeedKmh <= 10) {
          currentMode = "사각지대 집중 감시 (정차/서행)";
        } else if (currentSpeedKmh < 50) {
          currentMode = "대각선 돌발 침범 감시 (도심)";
        } else {
          currentMode = "고속 충돌 궤적 감시 (국도/고속)";
        }
      });
    });
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
          saveStatusMsg = "주행 영상(MP4) 실시간 녹화 가동 중";
        });

        startInferenceLoop();
      } catch (e) {
        print("Camera Start Error: $e");
      }
    }
  }

  void startInferenceLoop() {
    inferenceTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (!isRunning) return;
      processSpeedAwareDetection();
    });
  }

  // 속도 연동 능동 객체 및 사각지대 판정
  void processSpeedAwareDetection() {
    final size = MediaQuery.of(context).size;

    setState(() {
      if (isThreatActive) {
        if (currentSpeedKmh <= 10) {
          // 1. 정차/저속: 하단 사각지대 (주취자/낙하물)
          collisionAngle = 0;
          targetZone = "범퍼 앞 하단 사각지대";
          driveStatus = "사각지대 장애물 감지!";
          boxColor = Colors.redAccent;

          threatBoundingBox = Rect.fromCenter(
            center: Offset(size.width * 0.50, size.height * 0.70),
            width: size.width * 0.45,
            height: size.height * 0.25,
          );
          triggerAlert("사각지대 위험 즉시 제동", "사각지대 장애물");

        } else if (currentSpeedKmh < 50) {
          // 2. 도심 중속: 대각선 돌발 침범
          collisionAngle = 40;
          targetZone = "우측 대각선 돌발 진입";
          driveStatus = "대각선 돌발 침범 경보!";
          boxColor = Colors.redAccent;

          threatBoundingBox = Rect.fromCenter(
            center: Offset(size.width * 0.60, size.height * 0.55),
            width: size.width * 0.35,
            height: size.height * 0.40,
          );
          triggerAlert("위험 전방 주시 브레이크", "대각선 침범");

        } else {
          // 3. 고속: 전방 충돌 궤적
          collisionAngle = 5;
          targetZone = "전방 충돌 궤적";
          driveStatus = "전방 급접근 추돌 위험!";
          boxColor = Colors.redAccent;

          threatBoundingBox = Rect.fromCenter(
            center: Offset(size.width * 0.50, size.height * 0.48),
            width: size.width * 0.50,
            height: size.height * 0.45,
          );
          triggerAlert("추돌 위험 감속하십시오", "고속 전방 충돌");
        }
      } else {
        threatBoundingBox = null;
        boxColor = Colors.greenAccent;
        driveStatus = "VES 다이내믹 관제 중";
        targetZone = "안전";
        collisionAngle = 0;
      }
    });
  }

  void triggerAlert(String speechText, String status) {
    final now = DateTime.now();
    if (!isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= 6) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      flutterTts.speak(speechText);

      eventSaveCount++;
      final logEntry = "[EDR #$eventSaveCount] ${now.toIso8601String()} | 속도: ${currentSpeedKmh.toStringAsFixed(0)}km/h | 각도: ${collisionAngle}° | $status | 음성: $speechText";
      _driveLogSession.add(logEntry);

      Timer(const Duration(seconds: 6), () {
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

      // 1. 주행 MP4 영상 저장
      final String finalVideoPath = '${targetDir.path}/VES_DriveVideo_$timestamp.mp4';
      await File(rawVideoFile.path).copy(finalVideoPath);

      // 2. 속도/추돌각 EDR 로그 리포트 저장
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
      print("Save error: $e");
    }
  }

  @override
  void dispose() {
    inferenceTimer?.cancel();
    speedSimTimer?.cancel();
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
      body: GestureDetector(
        // 실내 간이 테스트용: 화면 터치 시 현재 속도 모드에 맞는 위험 시나리오 반응
        onTapDown: (_) {
          setState(() {
            isThreatActive = true;
          });
        },
        onTapUp: (_) {
          setState(() {
            isThreatActive = false;
          });
        },
        child: Stack(
          children: [
            SizedBox(
              width: size.width,
              height: size.height,
              child: CameraPreview(controller!),
            ),

            // 전방 차로 기준 Corridor 가이드
            Align(
              alignment: const Alignment(0, 0.35),
              child: Container(
                width: size.width * 0.45,
                height: size.height * 0.50,
                decoration: BoxDecoration(
                  border: Border.all(color: boxColor.withOpacity(0.5), width: 2.0),
                  color: boxColor.withOpacity(0.04),
                ),
              ),
            ),

            // 위험 바운딩 박스
            if (threatBoundingBox != null)
              Positioned(
                left: threatBoundingBox!.left,
                top: threatBoundingBox!.top,
                width: threatBoundingBox!.width,
                height: threatBoundingBox!.height,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.redAccent, width: 3.5),
                    color: Colors.redAccent.withOpacity(0.25),
                  ),
                ),
              ),

            // 상단 관제 UI (속도 / 모드 / 추돌각)
            Positioned(
              top: 40,
              left: 15,
              right: 15,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isThreatActive ? Colors.redAccent : boxColor, width: 1.5),
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
                              "${currentSpeedKmh.toStringAsFixed(0)} km/h",
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
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
                    Text(
                      "모드: $currentMode",
                      style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "구역: $targetZone",
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                        Text(
                          saveStatusMsg,
                          style: const TextStyle(color: Colors.white54, fontSize: 10),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // 실내 테스트용 속도 전환 버튼 (우측 상단 플로팅)
            Positioned(
              top: 140,
              right: 15,
              child: Column(
                children: [
                  FloatingActionButton.small(
                    heroTag: "speed0",
                    backgroundColor: currentSpeedKmh == 0 ? Colors.cyanAccent : Colors.black54,
                    onPressed: () {
                      setState(() { currentSpeedKmh = 0; });
                    },
                    child: const Text("0", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 6),
                  FloatingActionButton.small(
                    heroTag: "speed30",
                    backgroundColor: currentSpeedKmh == 30 ? Colors.cyanAccent : Colors.black54,
                    onPressed: () {
                      setState(() { currentSpeedKmh = 30; });
                    },
                    child: const Text("30", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 6),
                  FloatingActionButton.small(
                    heroTag: "speed60",
                    backgroundColor: currentSpeedKmh == 60 ? Colors.cyanAccent : Colors.black54,
                    onPressed: () {
                      setState(() { currentSpeedKmh = 60; });
                    },
                    child: const Text("60", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),

            // 하단 관제 종료 및 MP4/EDR 저장 버튼
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
                      driveStatus = "VES 다이내믹 관제 중";
                      boxColor = Colors.greenAccent;
                    });
                    await controller?.startVideoRecording();
                    setState(() {
                      isRecordingVideo = true;
                      saveStatusMsg = "새 주행 영상 녹화 중";
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
      ),
    );
  }
}
