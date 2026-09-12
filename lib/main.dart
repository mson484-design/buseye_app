import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
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
    home: VESIntegratedScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class VESIntegratedScreen extends StatefulWidget {
  const VESIntegratedScreen({Key? key}) : super(key: key);

  @override
  State<VESIntegratedScreen> createState() => _VESIntegratedScreenState();
}

class _VESIntegratedScreenState extends State<VESIntegratedScreen> {
  CameraController? controller;
  FlutterTts flutterTts = FlutterTts();

  bool isRunning = true;
  bool isStreaming = false;

  // 관제 모드 선택 (LIVE: 실차 주행 / MONITOR: 모니터 및 블박/CCTV 분석)
  String currentMode = "MONITOR"; 
  String driveStatus = "VES 통합 멀티소스 관제 대기";
  Color boxColor = Colors.greenAccent;

  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  bool isAnalyzingFrame = false;
  int lastFrameTime = 0;

  final List<String> _driveLogSession = [];
  int eventSaveCount = 0;

  double baselineStructure = 0.0;
  double prevStructure = 0.0;
  double prevGlobalLuma = 128.0; 

  @override
  void initState() {
    super.initState();
    initTTS();
    _startNewSession();
    initCameraAndStart();
  }

  void _startNewSession() {
    final now = DateTime.now();
    _driveLogSession.clear();
    _driveLogSession.add("=== VES 통합 관제 리포트 (실차/모니터/블박/CCTV) ===");
    _driveLogSession.add("시작: ${now.toIso8601String()}");
    _driveLogSession.add("--------------------------------------------------");
  }

  void initTTS() async {
    await flutterTts.setLanguage("ko-KR");
    await flutterTts.setSpeechRate(0.50);
    await flutterTts.setVolume(0.9);
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
          
          // 모드에 따라 프레임 샘플링 주기 최적화 (모니터는 600ms로 노이즈 타임블록 필터링)
          int frameInterval = (currentMode == "MONITOR") ? 600 : 400;
          if (now - lastFrameTime < frameInterval) return; 
          
          if (isAnalyzingFrame) return;

          lastFrameTime = now;
          isAnalyzingFrame = true;
          
          try {
            processMultiSourceFrame(image);
          } catch (e) {
            debugPrint("Frame Error: $e");
          } finally {
            isAnalyzingFrame = false; 
          }
        });

        setState(() {
          isStreaming = true;
        });

      } catch (e) {
        debugPrint("Camera Start Error: $e");
      }
    }
  }

  void processMultiSourceFrame(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;
    final int width = image.width;
    final int height = image.height;
    final int rowStride = image.planes[0].bytesPerRow;

    int step = 16; 

    // 모드별 최적 감시 구역(ROI) 동적 매핑
    int roiStartY = (currentMode == "MONITOR") ? (height * 0.35).toInt() : (height * 0.55).toInt();
    int roiEndY = (currentMode == "MONITOR") ? (height * 0.75).toInt() : (height * 0.85).toInt();
    int roiStartX = (width * 0.30).toInt();
    int roiEndX = (width * 0.70).toInt();

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

    double lumaDelta = (globalLuma - prevGlobalLuma).abs();
    prevGlobalLuma = globalLuma;
    if (lumaDelta > 55.0) return;

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
    double normalizedStructure = rawStructure * (120.0 / (globalLuma + 50.0));

    if (baselineStructure == 0.0) {
      baselineStructure = normalizedStructure;
      prevStructure = normalizedStructure;
      return;
    }

    double structureDelta = normalizedStructure - baselineStructure;
    if (structureDelta < 0) structureDelta = 0.0;
    
    double complexityChange = (normalizedStructure - prevStructure).abs();

    // 모니터/블박 분석 모드일 때 디지털 주사선 오작동 방지를 위한 추가 문턱 방어벽
    double t3Limit = (currentMode == "MONITOR") ? 28.0 : 18.0;
    double t2Limit = (currentMode == "MONITOR") ? 18.0 : 11.0;
    double t1Limit = (currentMode == "MONITOR") ? 11.0 : 6.5;

    setState(() {
      if (complexityChange > t3Limit || structureDelta > (t3Limit * 1.5)) {
        boxColor = Colors.redAccent;
        driveStatus = "🚨 [${currentMode}] 3단계 긴급 경고!";
        triggerTieredAlert("전방 급정체! 즉시 감속하세요!", 3);
      } else if (complexityChange > t2Limit || structureDelta > (t2Limit * 1.5)) {
        boxColor = Colors.orangeAccent;
        driveStatus = "⚠️ [${currentMode}] 2단계 정체 주의";
        triggerTieredAlert("전방 정체 구간, 속도를 줄이세요.", 2);
      } else if (complexityChange > t1Limit || structureDelta > (t1Limit * 1.4)) {
        boxColor = Colors.amber;
        driveStatus = "⚡ [${currentMode}] 1단계 교통 혼잡";
        triggerTieredAlert("전방 교통 혼잡, 주의하세요.", 1);
      } else {
        boxColor = Colors.greenAccent;
        driveStatus = "[$currentMode] 정상 관제 대기 중";
        baselineStructure = (baselineStructure * 0.99) + (normalizedStructure * 0.01);
      }
      prevStructure = normalizedStructure;
    });
  }

  void triggerTieredAlert(String speechText, int tier) {
    final now = DateTime.now();
    int cooldown = (tier == 3) ? 8 : (tier == 2) ? 12 : 15;

    if (!isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= cooldown) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      
      if (tier == 2) {
        speakRepeatedly(speechText, 3);
      } else {
        flutterTts.speak(speechText);
      }

      eventSaveCount++;
      _driveLogSession.add("[$currentMode - 티어 $tier 경고 #$eventSaveCount] ${now.toIso8601String()} | $speechText");
      
      Timer(Duration(seconds: cooldown), () {
        isSpeechLocked = false;
      });
    }
  }

  void speakRepeatedly(String text, int count) async {
    for (int i = 0; i < count; i++) {
      flutterTts.speak(text);
      await Future.delayed(const Duration(milliseconds: 2500));
    }
  }

  Future<void> stopAndSaveLog() async {
    if (controller == null || !isStreaming) return;
    try {
      try { await controller!.stopImageStream(); } catch (e) {}
      setState(() { isStreaming = false; });

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final targetDir = Directory('/storage/emulated/0/DCIM/Camera');
      if (!await targetDir.exists()) await targetDir.create(recursive: true);

      final logFile = File('${targetDir.path}/VES_Integrated_Report_$timestamp.txt');
      _driveLogSession.add("--------------------------------------------------");
      _driveLogSession.add("종료 시각: ${DateTime.now().toIso8601String()}");
      _driveLogSession.add("총 감지 횟수: $eventSaveCount건");
      await logFile.writeAsString(_driveLogSession.join('\n'));

      setState(() {
        driveStatus = "관제 종료 (통합 리포트 저장됨)";
        boxColor = Colors.grey;
      });
    } catch (e) {
      debugPrint("Save error: $e");
    }
  }

  @override
  void dispose() {
    if (controller != null && isStreaming) { controller!.stopImageStream(); }
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
            alignment: const Alignment(0, 0.40),
            child: Container(
              width: size.width * 0.40, 
              height: size.height * 0.30,
              decoration: BoxDecoration(
                border: Border.all(color: boxColor, width: 2.5), 
                color: boxColor.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: boxColor, width: 1.5),
                      ),
                    ),
                  ),
                  Center(child: Container(width: 4, height: 1, color: boxColor)),
                  Center(child: Container(width: 1, height: 4, color: boxColor)),
                ],
              ),
            ),
          ),

          // 상단 상태바 및 모드 전환 버튼
          Positioned(
            top: 40, left: 15, right: 15,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10), border: Border.all(color: boxColor, width: 1.5)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // 모드 스위치 버튼 (탭하면 MONITOR <-> LIVE 전환)
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        currentMode = (currentMode == "MONITOR") ? "LIVE" : "MONITOR";
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Colors.cyanAccent, borderRadius: BorderRadius.circular(4)),
                      child: Text("모드: $currentMode", style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  Text(driveStatus, style: TextStyle(color: boxColor, fontSize: 11, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),

          Positioned(
            bottom: 30, left: 20, right: 20,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: isRunning ? Colors.orangeAccent : Colors.green, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              onPressed: () async {
                if (isRunning) {
                  setState(() { isRunning = false; });
                  await stopAndSaveLog();
                } else {
                  setState(() {
                    isRunning = true;
                    driveStatus = "VES 통합 관제 재가동";
                    boxColor = Colors.greenAccent;
                  });
                  if (controller != null) {
                    controller!.startImageStream((CameraImage image) {
                      if (!isRunning) return;
                      final int now = DateTime.now().millisecondsSinceEpoch;
                      int interval = (currentMode == "MONITOR") ? 600 : 400;
                      if (now - lastFrameTime < interval) return;
                      if (isAnalyzingFrame) return;
                      
                      lastFrameTime = now;
                      isAnalyzingFrame = true;
                      
                      try {
                        processMultiSourceFrame(image);
                      } catch (e) {
                        debugPrint("Error: $e");
                      } finally {
                        isAnalyzingFrame = false;
                      }
                    });
                  }
                  setState(() { isStreaming = true; });
                }
              },
              child: Text(isRunning ? "■ 운행/분석 종료 및 리포트 저장" : "▶ 관제 다시 시작", style: const TextStyle(color: Colors.black, fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
