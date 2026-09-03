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
  bool isStreaming = false;

  String driveStatus = "VES 현장 맞춤형 MVP 관제 중";
  Color boxColor = Colors.greenAccent;
  String alertLevel = "SAFE"; 
  String targetZone = "정상 주행로";

  Rect? threatBoundingBox;
  int collisionAngle = 0;

  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  bool isAnalyzingFrame = false;
  int lastFrameTime = 0;

  final List<String> _driveLogSession = [];
  int eventSaveCount = 0;
  String saveStatusMsg = "대기 중";

  double baselineStructure = 0.0;
  double prevStructure = 0.0;
  double prevGlobalLuma = 128.0; 
  int hitCounter = 0;
  int safeReleaseCounter = 0;

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
    _driveLogSession.add("=== VES 현장 맞춤형 MVP EDR 관제 ===");
    _driveLogSession.add("기록 시작: ${now.toIso8601String()}");
    _driveLogSession.add("엔진: 중앙 ROI + 팽창 벡터 필터 + 야간 조도 노이즈 차단");
    _driveLogSession.add("저장소: 네이버 MYBOX 연동 (DCIM/Camera)");
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

        controller!.startImageStream((CameraImage image) {
          if (!isRunning) return;
          final int now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastFrameTime < 250) return; 
          
          if (isAnalyzingFrame) return;

          lastFrameTime = now;
          isAnalyzingFrame = true;
          
          try {
            processRealYuvFrame(image);
          } catch (e) {
            debugPrint("YUV Frame Error: $e");
          } finally {
            isAnalyzingFrame = false; 
          }
        });

        setState(() {
          isStreaming = true;
          saveStatusMsg = "야간 노이즈 차단 비전 엔진 가동 중";
        });

      } catch (e) {
        debugPrint("Camera Start Error: $e");
      }
    }
  }

  void processRealYuvFrame(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;
    final int width = image.width;
    final int height = image.height;
    final int rowStride = image.planes[0].bytesPerRow;

    int step = 16; 

    // 중앙 차선(38% ~ 62%) 집중 감지 영역
    int roiStartY = (height * 0.40).toInt();
    int roiEndY = (height * 0.85).toInt();
    int roiStartX = (width * 0.38).toInt();
    int roiEndX = (width * 0.62).toInt();

    int edgeSum = 0;
    int sampleCount = 0;
    int globalSum = 0;
    int globalCount = 0;

    for (int y = 0; y < height; y += step * 4) {
      for (int x = 0; x < width; x += step * 4) {
        int index = (y * rowStride) + x;
        if (index < yPlane.length) {
          globalSum += yPlane[index];
          globalCount++;
        }
      }
    }
    double globalLuma = globalCount > 0 ? globalSum / globalCount : 128.0;

    // 야간 조도 급변(헤드라이트 플래시) 필터링
    double lumaDelta = (globalLuma - prevGlobalLuma).abs();
    prevGlobalLuma = globalLuma;
    if (lumaDelta > 35.0) {
      return;
    }

    for (int y = roiStartY; y < roiEndY; y += step) {
      for (int x = roiStartX; x < roiEndX; x += step) {
        int currentIndex = (y * rowStride) + x;
        int nextYIndex = ((y + step) * rowStride) + x;

        if (nextYIndex < yPlane.length) {
          int diff = (yPlane[currentIndex] - yPlane[nextYIndex]).abs();
          edgeSum += diff;
          sampleCount++;
        }
      }
    }

    if (sampleCount == 0) return;

    double rawStructure = edgeSum / sampleCount;
    double normalizedStructure = (globalLuma < 60) 
        ? rawStructure * 1.5 
        : rawStructure * (120.0 / (globalLuma + 50.0));

    if (baselineStructure == 0.0) {
      baselineStructure = normalizedStructure;
      prevStructure = normalizedStructure;
      return;
    }

    double structureDelta = (normalizedStructure - baselineStructure).abs();
    double expansionSpeed = normalizedStructure - prevStructure;

    setState(() {
      if (expansionSpeed > 6.0 || (structureDelta > 13.0 && expansionSpeed > 2.5)) {
        hitCounter = 4;
        safeReleaseCounter = 0;
        alertLevel = "CRITICAL_CUTIN";
        boxColor = Colors.redAccent;
        collisionAngle = 45;
        targetZone = "전방 돌발 급접근";
        driveStatus = "돌발 위험 즉시 브레이크!";
        threatBoundingBox = Rect.fromCenter(
          center: Offset(MediaQuery.of(context).size.width * 0.50, MediaQuery.of(context).size.height * 0.52),
          width: MediaQuery.of(context).size.width * 0.38,
          height: MediaQuery.of(context).size.height * 0.32,
        );
        triggerAlert("위험 돌발 급접근 즉시 브레이크", "돌발 급접근", isUrgentOverride: true);
      }
      else if (structureDelta > 9.5 && expansionSpeed > 1.8) {
        hitCounter = max(hitCounter + 1, 3);
        safeReleaseCounter = 0;
        alertLevel = "DANGER_BRAKE";
        boxColor = Colors.red;
        collisionAngle = 5;
        targetZone = "정면 근거리 위험";
        driveStatus = "추돌 위험 즉시 브레이크!";
        threatBoundingBox = Rect.fromCenter(
          center: Offset(MediaQuery.of(context).size.width * 0.50, MediaQuery.of(context).size.height * 0.50),
          width: MediaQuery.of(context).size.width * 0.32,
          height: MediaQuery.of(context).size.height * 0.28,
        );
        triggerAlert("추돌 위험 즉시 브레이크", "3단계 위험 제동");
      }
      else if (structureDelta > 6.5 && expansionSpeed > 1.2) {
        hitCounter++;
        if (hitCounter >= 2) {
          safeReleaseCounter = 0;
          alertLevel = "WARNING_50";
          boxColor = Colors.orangeAccent;
          collisionAngle = 2;
          targetZone = "전방 접근 구간";
          driveStatus = "전방 간격 확인 감속";
          threatBoundingBox = Rect.fromCenter(
            center: Offset(MediaQuery.of(context).size.width * 0.50, MediaQuery.of(context).size.height * 0.45),
            width: MediaQuery.of(context).size.width * 0.25,
            height: MediaQuery.of(context).size.height * 0.22,
          );
          triggerAlert("전방 간격 확인 감속하십시오", "2단계 감속 권고");
        }
      }
      else {
        safeReleaseCounter++;
        if (safeReleaseCounter >= 4) {
          hitCounter = 0;
          alertLevel = "SAFE";
          boxColor = Colors.greenAccent;
          threatBoundingBox = null;
          targetZone = "정상 주행로";
          driveStatus = "VES 현장 맞춤형 MVP 관제 중";
          collisionAngle = 0;
          baselineStructure = (baselineStructure * 0.92) + (normalizedStructure * 0.08);
        }
      }
      prevStructure = normalizedStructure;
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
      final logEntry = "[EDR #$eventSaveCount] ${now.toIso8601String()} | 단계: $alertLevel | 각도: ${collisionAngle}° | $status";
      _driveLogSession.add(logEntry);
      Timer(Duration(seconds: cooldownSec), () {
        isSpeechLocked = false;
      });
    }
  }

  Future<void> stopAndSaveEDRLog() async {
    if (controller == null || !isStreaming) return;
    try {
      setState(() { saveStatusMsg = "EDR 텍스트 로그 저장 중..."; });
      
      try {
        await controller!.stopImageStream();
      } catch (e) {}
      
      setState(() { isStreaming = false; });

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final targetDir = Directory('/storage/emulated/0/DCIM/Camera');
      if (!await targetDir.exists()) await targetDir.create(recursive: true);

      final logFile = File('${targetDir.path}/VES_EDR_Report_$timestamp.txt');
      _driveLogSession.add("--------------------------------------------------");
      _driveLogSession.add("종료 시각: ${DateTime.now().toIso8601String()}");
      _driveLogSession.add("총 EDR 이벤트: $eventSaveCount건");
      await logFile.writeAsString(_driveLogSession.join('\n'));

      setState(() {
        saveStatusMsg = "EDR 마이박스 연동 경로 저장 완료";
        driveStatus = "관제 종료";
        boxColor = Colors.grey;
      });
    } catch (e) {
      debugPrint("Save error: $e");
    }
  }

  @override
  void dispose() {
    if (controller != null && isStreaming) {
      controller!.stopImageStream(); 
    }
    controller?.dispose();
    flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (controller == null || !controller!.value.isInitialized) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator(color: Colors.cyanAccent)));
    }
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SizedBox(width: size.width, height: size.height, child: CameraPreview(controller!)),
          Align(
            alignment: const Alignment(0, 0.35),
            child: Container(
              width: size.width * 0.24, height: size.height * 0.45,
              decoration: BoxDecoration(border: Border.all(color: boxColor.withOpacity(0.5), width: 2.0), color: boxColor.withOpacity(0.02)),
            ),
          ),
          if (threatBoundingBox != null)
            Positioned(
              left: threatBoundingBox!.left, top: threatBoundingBox!.top, width: threatBoundingBox!.width, height: threatBoundingBox!.height,
              child: Container(decoration: BoxDecoration(border: Border.all(color: boxColor, width: 3.5), color: boxColor.withOpacity(0.20))),
            ),
          Positioned(
            top: 40, left: 15, right: 15,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10), border: Border.all(color: boxColor, width: 1.5)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          if (isStreaming) Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 8), decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle)),
                          const Text("현장 맞춤형 MVP 비전 엔진", style: TextStyle(color: Colors.cyanAccent, fontSize: 14, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Text(driveStatus, style: TextStyle(color: boxColor, fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("경보단계: $alertLevel", style: TextStyle(color: boxColor, fontSize: 12, fontWeight: FontWeight.w600)),
                      Text("구역: $targetZone", style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text("상태: $saveStatusMsg", style: const TextStyle(color: Colors.white54, fontSize: 10)),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 30, left: 20, right: 20,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: isRunning ? Colors.redAccent : Colors.green, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              onPressed: () async {
                if (isRunning) {
                  setState(() { isRunning = false; });
                  await stopAndSaveEDRLog();
                } else {
                  setState(() {
                    isRunning = true;
                    driveStatus = "VES 현장 맞춤형 MVP 관제 중";
                    boxColor = Colors.greenAccent;
                  });
                  if (controller != null) {
                    controller!.startImageStream((CameraImage image) {
                      if (!isRunning) return;
                      final int now = DateTime.now().millisecondsSinceEpoch;
                      if (now - lastFrameTime < 250) return;
                      if (isAnalyzingFrame) return;
                      
                      lastFrameTime = now;
                      isAnalyzingFrame = true;
                      
                      try {
                        processRealYuvFrame(image);
                      } catch (e) {
                        debugPrint("Error: $e");
                      } finally {
                        isAnalyzingFrame = false;
                      }
                    });
                  }
                  setState(() { isStreaming = true; saveStatusMsg = "현장 맞춤형 비전 엔진 가동 중"; });
                }
              },
              child: Text(isRunning ? "■ 관제 종료 (EDR 마이박스 저장)" : "▶ 비전 관제 다시 시작", style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
