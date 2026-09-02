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

  String driveStatus = "VES 실측 비전(YUV) 가동 중";
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
    _driveLogSession.add("=== VES 실내/실차 비전 EDR 관제 ===");
    _driveLogSession.add("기록 시작: ${now.toIso8601String()}");
    _driveLogSession.add("엔진: 1D Flat Array 무중단 YUV 픽셀 스트리밍");
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
          saveStatusMsg = "실시간 YUV 픽셀 분석 가동 중";
        });

      } catch (e) {
        debugPrint("Camera Start Error: $e");
      }
    }
  }

  void processRealYuvFrame(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;
    if (yPlane.length < 5000) return;

    int step = 32; 
    
    int globalSum = 0;
    int globalCount = 0;
    for (int i = 0; i < yPlane.length; i += step * 4) {
      globalSum += yPlane[i];
      globalCount++;
    }
    double globalLuma = globalCount > 0 ? globalSum / globalCount : 128.0;

    int roiStart = (yPlane.length * 0.40).toInt();
    int roiEnd = (yPlane.length * 0.90).toInt();
    
    int edgeSum = 0;
    int sampleCount = 0;

    for (int i = roiStart; i < roiEnd - step; i += step) {
      int diff = (yPlane[i] - yPlane[i + step]).abs();
      edgeSum += diff;
      sampleCount++;
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
      if (expansionSpeed > 5.0 || (structureDelta > 10.0 && expansionSpeed > 2.5)) {
        hitCounter = 4;
        safeReleaseCounter = 0;
        alertLevel = "CRITICAL_CUTIN";
        boxColor = Colors.redAccent;
        collisionAngle = 45;
        targetZone = "돌발 대각 급침범";
        driveStatus = "돌발 침범 즉시 브레이크!";
        threatBoundingBox = Rect.fromCenter(
          center: Offset(MediaQuery.of(context).size.width * 0.58, MediaQuery.of(context).size.height * 0.55),
          width: MediaQuery.of(context).size.width * 0.52,
          height: MediaQuery.of(context).size.height * 0.45,
        );
        triggerAlert("위험 돌발 침범 즉시 브레이크", "돌발 급침범", isUrgentOverride: true);
      }
      else if (structureDelta > 7.5) {
        hitCounter = max(hitCounter + 1, 3);
        safeReleaseCounter = 0;
        alertLevel = "DANGER_BRAKE";
        boxColor = Colors.red;
        collisionAngle = 5;
        targetZone = "근거리 위험 구역";
        driveStatus = "추돌 위험 즉시 브레이크!";
        threatBoundingBox = Rect.fromCenter(
          center: Offset(MediaQuery.of(context).size.width * 0.50, MediaQuery.of(context).size.height * 0.52),
          width: MediaQuery.of(context).size.width * 0.46,
          height: MediaQuery.of(context).size.height * 0.42,
        );
        triggerAlert("추돌 위험 즉시 브레이크", "3단계 위험 제동");
      }
      else if (structureDelta > 5.0) {
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
            width: MediaQuery.of(context).size.width * 0.35,
            height: MediaQuery.of(context).size.height * 0.30,
          );
          triggerAlert("전방 간격 확인 감속하십시오", "2단계 감속 권고");
        }
      }
      else if (structureDelta > 3.0) {
        hitCounter++;
        if (hitCounter >= 2) {
          safeReleaseCounter = 0;
          alertLevel = "CAUTION_100";
          boxColor = Colors.yellowAccent;
          collisionAngle = 0;
          targetZone = "전방 감지 구역";
          driveStatus = "전방 주의 확인";
          threatBoundingBox = Rect.fromCenter(
            center: Offset(MediaQuery.of(context).size.width * 0.50, MediaQuery.of(context).size.height * 0.42),
            width: MediaQuery.of(context).size.width * 0.28,
            height: MediaQuery.of(context).size.height * 0.24,
          );
          triggerAlert("전방 주의하십시오", "1단계 전방 주의");
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
          driveStatus = "VES 실측 비전(YUV) 가동 중";
          collisionAngle = 0;
          baselineStructure = (baselineStructure * 0.90) + (normalizedStructure * 0.10);
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
              width: size.width * 0.45, height: size.height * 0.50,
              decoration: BoxDecoration(border: Border.all(color: boxColor.withOpacity(0.5), width: 2.0), color: boxColor.withOpacity(0.03)),
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
                          const Text("YUV 비전 센서 (마이박스 연동)", style: TextStyle(color: Colors.cyanAccent, fontSize: 14, fontWeight: FontWeight.bold)),
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
                    driveStatus = "VES 실측 비전(YUV) 가동 중";
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
                  setState(() { isStreaming = true; saveStatusMsg = "실시간 YUV 픽셀 분석 가동 중"; });
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
