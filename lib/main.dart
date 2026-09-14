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
    home: VESWideFieldScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class VESWideFieldScreen extends StatefulWidget {
  const VESWideFieldScreen({Key? key}) : super(key: key);

  @override
  State<VESWideFieldScreen> createState() => _VESWideFieldScreenState();
}

class _VESWideFieldScreenState extends State<VESWideFieldScreen> {
  CameraController? controller;
  FlutterTts flutterTts = FlutterTts();

  bool isRunning = true;
  bool isStreaming = false;

  String driveStatus = "VES 와이드 실차 관제 대기";
  Color boxColor = Colors.greenAccent;

  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));
  DateTime lastStopSpokenTime = DateTime.now().subtract(const Duration(minutes: 2));

  bool isAnalyzingFrame = false;
  int lastFrameTime = 0;

  double baselineStructure = 0.0;
  double prevStructure = 0.0;
  double prevGlobalLuma = 128.0; 

  bool isSlowOrStopMode = false;

  @override
  void initState() {
    super.initState();
    initTTS();
    initCameraAndStart();
  }

  void initTTS() async {
    await flutterTts.setLanguage("ko-KR");
    await flutterTts.setSpeechRate(0.50);
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
          
          if (now - lastFrameTime < 400) return; 
          if (isAnalyzingFrame) return;

          lastFrameTime = now;
          isAnalyzingFrame = true;
          
          try {
            processWideFieldFrame(image);
          } catch (e) {
            debugPrint("Frame Error: $e");
          } finally {
            isAnalyzingFrame = false; 
          }
        });
        setState(() { isStreaming = true; });
      } catch (e) {
        debugPrint("Camera Start Error: $e");
      }
    }
  }

  void processWideFieldFrame(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;
    final int width = image.width;
    final int height = image.height;
    final int rowStride = image.planes[0].bytesPerRow;

    int step = 16; 

    // [와이드 스트립 ROI 세팅] 세로는 얇게(하늘/보닛 제외), 가로는 넓게(양옆 차선 포함)
    int roiStartY = (height * 0.70).toInt();
    int roiEndY = (height * 0.85).toInt();
    int roiStartX = (width * 0.20).toInt();
    int roiEndX = (width * 0.80).toInt();

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
    
    // 급격한 조도 변화(터널, 그림자) 필터링
    if (lumaDelta > 45.0) return; 

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
      if (normalizedStructure < 7.0) {
        isSlowOrStopMode = true;
        boxColor = Colors.lightBlueAccent;
        driveStatus = "정차 / 서행 구간 감시";
        triggerStopAlert();
      } else {
        isSlowOrStopMode = false;
        
        if (complexityChange > 20.0 || structureDelta > 28.0) {
          boxColor = Colors.redAccent;
          driveStatus = "🚨 3단계 긴급 경고";
          triggerAlert("전방 급정체! 즉시 감속하세요!", 3);
        } else if (complexityChange > 12.0 || structureDelta > 17.0) {
          boxColor = Colors.orangeAccent;
          driveStatus = "⚠️ 2단계 정체 주의";
          triggerAlert("전방 정체 구간, 속도를 줄이세요.", 2);
        } else if (complexityChange > 7.0 || structureDelta > 10.0) {
          boxColor = Colors.amber;
          driveStatus = "⚡ 1단계 교통 혼잡";
          triggerAlert("전방 교통 혼잡, 주의하세요.", 1);
        } else {
          boxColor = Colors.greenAccent;
          driveStatus = "정상 주행 관제 중";
          baselineStructure = (baselineStructure * 0.99) + (normalizedStructure * 0.01);
        }
      }
      prevStructure = normalizedStructure;
    });
  }

  void triggerAlert(String text, int tier) {
    final now = DateTime.now();
    int cooldown = (tier == 3) ? 8 : (tier == 2) ? 15 : 20;

    if (!isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= cooldown) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      flutterTts.speak(text);
      Timer(Duration(seconds: cooldown), () { isSpeechLocked = false; });
    }
  }

  void triggerStopAlert() {
    final now = DateTime.now();
    if (!isSpeechLocked && now.difference(lastStopSpokenTime).inSeconds >= 120) {
      isSpeechLocked = true;
      lastStopSpokenTime = now;
      flutterTts.speak("정차 구간입니다. 주변 안전에 주의하세요.");
      Timer(const Duration(seconds: 8), () { isSpeechLocked = false; });
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
          
          // [화면 UI 가이드] 코드 내 ROI 영역(가로 20%~80%, 세로 70%~85%)과 일치하는 와이드 스트립 박스
          Align(
            alignment: const Alignment(0, 0.55),
            child: Container(
              width: size.width * 0.60, 
              height: size.height * 0.15,
              decoration: BoxDecoration(
                border: Border.all(color: boxColor, width: 2.5),
                borderRadius: BorderRadius.circular(6),
                color: boxColor.withOpacity(0.1),
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
                  const Text("VES 와이드 관제", style: TextStyle(color: Colors.cyanAccent, fontSize: 15, fontWeight: FontWeight.bold)),
                  Text(driveStatus, style: TextStyle(color: boxColor, fontSize: 13, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
