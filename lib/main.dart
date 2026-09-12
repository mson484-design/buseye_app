import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart'; 

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera init error: $e');
  }
  runApp(const MaterialApp(
    home: VESRealDriveScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class VESRealDriveScreen extends StatefulWidget {
  const VESRealDriveScreen({Key? key}) : super(key: key);

  @override
  State<VESRealDriveScreen> createState() => _VESRealDriveScreenState();
}

class _VESRealDriveScreenState extends State<VESRealDriveScreen> {
  CameraController? controller;
  FlutterTts flutterTts = FlutterTts();
  StreamSubscription<Position>? positionStream;

  bool isRunning = true;
  bool isStreaming = false;

  String driveStatus = "GPS 연결 중...";
  Color boxColor = Colors.greenAccent;

  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));
  DateTime lastBusStopSpokenTime = DateTime.now().subtract(const Duration(minutes: 2)); // 정류장 멘트 남발 방지 (2분 쿨타임)

  bool isAnalyzingFrame = false;
  int lastFrameTime = 0;

  double baselineStructure = 0.0;
  double prevStructure = 0.0;
  double prevGlobalLuma = 128.0; 

  double currentRealSpeed = 0.0; 
  bool isBusStopMode = false;
  
  final List<String> _driveLog = [];

  @override
  void initState() {
    super.initState();
    initTTS();
    initCameraAndStart();
    _startGPSLocationTracking();
    _driveLog.add("=== VES 실차 테스트 로그 (GPS 연동) ===");
  }

  void initTTS() async {
    await flutterTts.setLanguage("ko-KR");
    await flutterTts.setSpeechRate(0.50);
    await flutterTts.setVolume(1.0);
  }

  void _startGPSLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() { driveStatus = "GPS 기능이 꺼져있습니다."; });
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high)
      ).listen((Position position) {
        if (!mounted) return;
        setState(() {
          currentRealSpeed = position.speed * 3.6; // m/s -> km/h 변환
        });
      });
    }
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
            processRealDriveFrame(image);
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

  void processRealDriveFrame(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;
    final int width = image.width;
    final int height = image.height;
    final int rowStride = image.planes[0].bytesPerRow;

    int step = 16; 

    // 실차 환경: 하늘(구름, 햇빛)과 반대편 차선을 배제한 내 차로 집중 ROI
    int roiStartY = (height * 0.55).toInt();
    int roiEndY = (height * 0.85).toInt();
    int roiStartX = (width * 0.35).toInt();
    int roiEndX = (width * 0.65).toInt();

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
    
    // 갑작스러운 그림자나 터널 진입 시 오작동 방지 (Luma 변화가 크면 이번 프레임 스킵)
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
      // 1. [정차/초저속] 속도 5km/h 이하: 정류장/신호대기 
      if (currentRealSpeed <= 5.0) {
        isBusStopMode = true;
        boxColor = Colors.lightBlueAccent;
        driveStatus = "정차/초저속 (정류장/신호대기)";
        triggerAutoBusStopAlert();
      } 
      // 2. [서행/멘트 차단] 속도 20km/h 이하: 서행 시 멘트 남발 완벽 차단
      else if (currentRealSpeed <= 20.0) {
        isBusStopMode = false;
        boxColor = Colors.grey;
        driveStatus = "서행 중 (경고 음소거됨)";
        baselineStructure = (baselineStructure * 0.99) + (normalizedStructure * 0.01);
      } 
      // 3. [정상 주행] 속도 20km/h 초과: 실차 3단계 경고 (문턱값 상향으로 남발 방지)
      else {
        isBusStopMode = false;
        
        if (complexityChange > 22.0 || structureDelta > 30.0) {
          boxColor = Colors.redAccent;
          driveStatus = "🚨 3단계 긴급 경고";
          triggerAlert("전방 급정체! 즉시 감속하세요!", 3);
        } else if (complexityChange > 14.0 || structureDelta > 19.0) {
          boxColor = Colors.orangeAccent;
          driveStatus = "⚠️ 2단계 정체 주의";
          triggerAlert("전방 정체 구간, 속도를 줄이세요.", 2);
        } else if (complexityChange > 8.0 || structureDelta > 11.0) {
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
    // 멘트 남발 방지를 위해 쿨타임 대폭 강화 (3단계 8초, 2단계 15초, 1단계 20초)
    int cooldown = (tier == 3) ? 8 : (tier == 2) ? 15 : 20;

    if (!isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= cooldown) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      
      flutterTts.speak(text);
      
      _driveLog.add("${now.toIso8601String()}, ${currentRealSpeed.toInt()}km/h, Tier $tier");
      
      Timer(Duration(seconds: cooldown), () { isSpeechLocked = false; });
    }
  }

  void triggerAutoBusStopAlert() {
    final now = DateTime.now();
    // 정류장/정차 안내는 멘트 남발 방지를 위해 무려 120초(2분)에 한 번만 나오도록 설정
    if (!isSpeechLocked && now.difference(lastBusStopSpokenTime).inSeconds >= 120) {
      isSpeechLocked = true;
      lastBusStopSpokenTime = now;
      
      flutterTts.speak("정차 구간입니다. 승객 승하차에 주의하세요.");
      
      Timer(const Duration(seconds: 8), () { isSpeechLocked = false; });
    }
  }

  @override
  void dispose() {
    if (controller != null && isStreaming) { controller!.stopImageStream(); }
    controller?.dispose();
    flutterTts.stop();
    positionStream?.cancel();
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
              width: size.width * 0.35, height: size.height * 0.25,
              decoration: BoxDecoration(border: Border.all(color: boxColor, width: 2.5), borderRadius: BorderRadius.circular(8)),
            ),
          ),

          if (isBusStopMode)
            Align(
              alignment: const Alignment(0.85, 0.40),
              child: Container(
                width: size.width * 0.25, height: size.height * 0.40,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.lightBlueAccent, width: 3.0),
                  color: Colors.lightBlueAccent.withOpacity(0.2),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.directions_bus, color: Colors.white, size: 40),
                    SizedBox(height: 8),
                    Text("승객 스캔 활성", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
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
                  Text("GPS 속도: ${currentRealSpeed.toInt()} km/h", style: TextStyle(color: currentRealSpeed <= 20 ? Colors.grey : Colors.cyanAccent, fontSize: 16, fontWeight: FontWeight.bold)),
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
