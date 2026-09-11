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

  String driveStatus = "모니터 초고감도 테스트 중";
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
    _driveLogSession.add("=== VES 모니터 초고감도 테스트 리포트 ===");
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
          if (now - lastFrameTime < 300) return; 
          
          if (isAnalyzingFrame) return;

          lastFrameTime = now;
          isAnalyzingFrame = true;
          
          try {
            processHyperSensitiveMonitorFrame(image);
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

  void processHyperSensitiveMonitorFrame(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;
    final int width = image.width;
    final int height = image.height;
    final int rowStride = image.planes[0].bytesPerRow;

    int step = 12; 

    int roiStartY = (height * 0.40).toInt();
    int roiEndY = (height * 0.80).toInt();
    int roiStartX = (width * 0.25).toInt();
    int roiEndX = (width * 0.75).toInt();

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
    if (lumaDelta > 70.0) return;

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

    setState(() {
      // 모니터 초고감도 감지 조건
      if (complexityChange > 3.5 || structureDelta > 6.0) {
        boxColor = Colors.orangeAccent; 
        driveStatus = "모니터 정체/돌발 감지!";
        triggerAlert("전방 도로 통행량이 복잡합니다. 주의해 주세요.");
      } else {
        boxColor = Colors.greenAccent;
        driveStatus = "모니터 관제 대기 중";
        baselineStructure = (baselineStructure * 0.95) + (normalizedStructure * 0.05);
      }
      prevStructure = normalizedStructure;
    });
  }

  void triggerAlert(String speechText) {
    final now = DateTime.now();
    if (!isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= 8) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      flutterTts.speak(speechText);
      eventSaveCount++;
      _driveLogSession.add("[모니터 감지 #$eventSaveCount] ${now.toIso8601String()} | $speechText");
      Timer(const Duration(seconds: 8), () {
        isSpeechLocked = false;
      });
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

      final logFile = File('${targetDir.path}/VES_Monitor_HyperReport_$timestamp.txt');
      _driveLogSession.add("--------------------------------------------------");
      _driveLogSession.add("종료 시각: ${DateTime.now().toIso8601String()}");
      _driveLogSession.add("총 감지 횟수: $eventSaveCount건");
      await logFile.writeAsString(_driveLogSession.join('\n'));

      setState(() {
        driveStatus = "테스트 종료 (리포트 저장)";
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10), border: Border.all(color: boxColor, width: 1.5)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("VES 모니터 초고감도 테스트", style: TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold)),
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
                  await stopAndSaveLog();
                } else {
                  setState(() {
                    isRunning = true;
                    driveStatus = "모니터 초고감도 테스트 중";
                    boxColor = Colors.greenAccent;
                  });
                  if (controller != null) {
                    controller!.startImageStream((CameraImage image) {
                      if (!isRunning) return;
                      final int now = DateTime.now().millisecondsSinceEpoch;
                      if (now - lastFrameTime < 300) return;
                      if (isAnalyzingFrame) return;
                      
                      lastFrameTime = now;
                      isAnalyzingFrame = true;
                      
                      try {
                        processHyperSensitiveMonitorFrame(image);
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
              child: Text(isRunning ? "■ 테스트 종료 및 리포트 저장" : "▶ 테스트 다시 시작", style: const TextStyle(color: Colors.black, fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
