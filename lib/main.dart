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
    home: VESDeepLearningScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class VESDeepLearningScreen extends StatefulWidget {
  const VESDeepLearningScreen({Key? key}) : super(key: key);

  @override
  State<VESDeepLearningScreen> createState() => _VESDeepLearningScreenState();
}

class _VESDeepLearningScreenState extends State<VESDeepLearningScreen> {
  CameraController? controller;
  FlutterTts flutterTts = FlutterTts();

  bool isRunning = true;
  bool isStreaming = false;

  String currentMode = "CCTV"; 
  String driveStatus = "VES 모니터 관제 대기 중";
  Color boxColor = Colors.greenAccent;

  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  bool isAnalyzingFrame = false;
  int lastFrameTime = 0;

  final List<String> _dlDatasetLog = [];
  int eventSaveCount = 0;

  double baselineStructure = 0.0;
  double prevStructure = 0.0;
  double prevGlobalLuma = 128.0; 

  @override
  void initState() {
    super.initState();
    initTTS();
    _startNewDeepLearningSession();
    initCameraAndStart();
  }

  void _startNewDeepLearningSession() {
    final now = DateTime.now();
    _dlDatasetLog.clear();
    _dlDatasetLog.add("=== VES Deep Learning Dataset ===");
    _dlDatasetLog.add("Session Start: ${now.toIso8601String()}");
    _dlDatasetLog.add("Timestamp,Mode,GlobalLuma,ComplexityChange,StructureDelta,TierLabel,Action");
    _dlDatasetLog.add("--------------------------------------------------");
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
          
          int frameInterval = (currentMode == "CCTV") ? 600 : 400;
          if (now - lastFrameTime < frameInterval) return; 
          
          if (isAnalyzingFrame) return;

          lastFrameTime = now;
          isAnalyzingFrame = true;
          
          try {
            processDeepLearningFrame(image);
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

  void processDeepLearningFrame(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;
    final int width = image.width;
    final int height = image.height;
    final int rowStride = image.planes[0].bytesPerRow;

    int step = 16; 

    int roiStartY = (currentMode == "CCTV") ? (height * 0.35).toInt() : (height * 0.55).toInt();
    int roiEndY = (currentMode == "CCTV") ? (height * 0.75).toInt() : (height * 0.85).toInt();
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

    // [수정 핵심] 모니터(CCTV) 모드 임계값 재조정 
    // 기존의 과도하게 높았던 수치(28.0, 18.0, 11.0)를 대폭 하향하여 정상적인 정체 영상에 반응하도록 수정했습니다.
    double t3Limit = (currentMode == "CCTV") ? 18.0 : 18.0; 
    double t2Limit = (currentMode == "CCTV") ? 12.0 : 11.0; 
    double t1Limit = (currentMode == "CCTV") ? 7.5 : 6.5; 

    setState(() {
      int currentTier = 0;

      if (complexityChange > t3Limit || structureDelta > (t3Limit * 1.5)) {
        currentTier = 3;
        boxColor = Colors.redAccent;
        driveStatus = "🚨 [$currentMode] 3단계 긴급 (데이터 기록중)";
        triggerTieredAlert("전방 급정체! 즉시 감속하세요!", 3, globalLuma, complexityChange, structureDelta);
      } else if (complexityChange > t2Limit || structureDelta > (t2Limit * 1.5)) {
        currentTier = 2;
        boxColor = Colors.orangeAccent;
        driveStatus = "⚠️ [$currentMode] 2단계 주의 (데이터 기록중)";
        triggerTieredAlert("전방 정체 구간, 속도를 줄이세요.", 2, globalLuma, complexityChange, structureDelta);
      } else if (complexityChange > t1Limit || structureDelta > (t1Limit * 1.4)) {
        currentTier = 1;
        boxColor = Colors.amber;
        driveStatus = "⚡ [$currentMode] 1단계 혼잡 (데이터 기록중)";
        triggerTieredAlert("전방 교통 혼잡, 주의하세요.", 1, globalLuma, complexityChange, structureDelta);
      } else {
        boxColor = Colors.greenAccent;
        driveStatus = "[$currentMode] 정상 관제 (학습 데이터 누적)";
        baselineStructure = (baselineStructure * 0.99) + (normalizedStructure * 0.01);
      }
      prevStructure = normalizedStructure;
    });
  }

  void triggerTieredAlert(String speechText, int tier, double luma, double complexity, double structure) {
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
      
      String timeStr = now.toIso8601String();
      String dlLog = "$timeStr,$currentMode,${luma.toStringAsFixed(2)},${complexity.toStringAsFixed(2)},${structure.toStringAsFixed(2)},Tier_$tier,$speechText";
      _dlDatasetLog.add(dlLog);
      
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

  Future<void> stopAndSaveDeepLearningData() async {
    if (controller == null || !isStreaming) return;
    try {
      try { await controller!.stopImageStream(); } catch (e) {}
      setState(() { isStreaming = false; });

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final targetDir = Directory('/storage/emulated/0/DCIM/Camera');
      if (!await targetDir.exists()) await targetDir.create(recursive: true);

      final logFile = File('${targetDir.path}/VES_ML_Dataset_$timestamp.csv');
      _dlDatasetLog.add("--------------------------------------------------");
      _dlDatasetLog.add("Session End: ${DateTime.now().toIso8601String()}");
      _dlDatasetLog.add("Total Labeled Events: $eventSaveCount");
      await logFile.writeAsString(_dlDatasetLog.join('\n'));

      setState(() {
        driveStatus = "관제 종료 (딥러닝 데이터셋 저장 완료)";
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

          Positioned(
            top: 40, left: 15, right: 15,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10), border: Border.all(color: boxColor, width: 1.5)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        currentMode = (currentMode == "CCTV") ? "LIVE" : "CCTV";
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.cyanAccent, borderRadius: BorderRadius.circular(4)),
                      child: Text("소스: $currentMode", style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  Text(driveStatus, style: TextStyle(color: boxColor, fontSize: 12, fontWeight: FontWeight.bold)),
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
                  await stopAndSaveDeepLearningData();
                } else {
                  setState(() {
                    isRunning = true;
                    driveStatus = "VES 딥러닝 데이터 수집 재가동";
                    boxColor = Colors.greenAccent;
                  });
                  if (controller != null) {
                    controller!.startImageStream((CameraImage image) {
                      if (!isRunning) return;
                      final int now = DateTime.now().millisecondsSinceEpoch;
                      int interval = (currentMode == "CCTV") ? 600 : 400;
                      if (now - lastFrameTime < interval) return;
                      if (isAnalyzingFrame) return;
                      
                      lastFrameTime = now;
                      isAnalyzingFrame = true;
                      
                      try {
                        processDeepLearningFrame(image);
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
              child: Text(isRunning ? "■ 운행 종료 및 ML 데이터셋 저장" : "▶ AI 관제 다시 시작", style: const TextStyle(color: Colors.black, fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
