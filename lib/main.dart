import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart'; // 실시간 GPS 속도 연동용 패키지

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

  String driveStatus = "VES 인간-AI 콜라보 관제 중";
  Color boxColor = Colors.greenAccent;
  String alertLevel = "SAFE"; 
  String targetZone = "전방 도로 복잡도 모니터링";

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

  double currentGpsSpeed = 0.0; // 실시간 버스 속도 (km/h)
  StreamSubscription<Position>? speedSubscription;

  @override
  void initState() {
    super.initState();
    initTTS();
    _startNewDriveSession();
    initSpeedTracking();
    initCameraAndStart();
  }

  void _startNewDriveSession() {
    final now = DateTime.now();
    _driveLogSession.clear();
    _driveLogSession.add("=== VES 인간-AI 콜라보 운행 리포트 ===");
    _driveLogSession.add("시작: ${now.toIso8601String()}");
    _driveLogSession.add("모드: 정차 시 완전 음소거 및 전방 도로 복잡도 특이점 감지");
    _driveLogSession.add("--------------------------------------------------");
  }

  void initTTS() async {
    await flutterTts.setLanguage("ko-KR");
    await flutterTts.setSpeechRate(0.50);
    await flutterTts.setVolume(0.9);
  }

  // 실시간 GPS 속도 연동 (정차 시 멘트 남발 원천 차단)
  void initSpeedTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 2,
    );

    speedSubscription = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) {
      setState(() {
        currentGpsSpeed = position.speed * 3.6; // m/s를 km/h로 환산
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

        controller!.startImageStream((CameraImage image) {
          if (!isRunning) return;
          final int now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastFrameTime < 400) return; // 0.4초 간격으로 부하 최소화
          
          if (isAnalyzingFrame) return;

          lastFrameTime = now;
          isAnalyzingFrame = true;
          
          try {
            processTrafficComplexityFrame(image);
          } catch (e) {
            debugPrint("Frame Error: $e");
          } finally {
            isAnalyzingFrame = false; 
          }
        });

        setState(() {
          isStreaming = true;
          saveStatusMsg = "도로 복잡도 감시 필터 가동 중";
        });

      } catch (e) {
        debugPrint("Camera Start Error: $e");
      }
    }
  }

  // 핵심 로직: 도로 복잡도 및 특이점 분석 (정차 시 완전 음소거 적용)
  void processTrafficComplexityFrame(CameraImage image) {
    // 1단계: 정차 중이거나 서행(3km/h 미만, 정류장/신호대기)일 때는 인간이 전담하므로 AI 완전 음소거
    if (currentGpsSpeed < 3.0) {
      setState(() {
        alertLevel = "SAFE (정차 중 음소거)";
        boxColor = Colors.greenAccent;
        driveStatus = "정차 중 (AI 휴식 모드)";
      });
      return; 
    }

    final Uint8List yPlane = image.planes[0].bytes;
    final int width = image.width;
    final int height = image.height;
    final int rowStride = image.planes[0].bytesPerRow;

    int step = 16; 

    // 하단 거치대 시야각에 맞춘 도로 복잡도 스캔 구역 (하단 50% ~ 85%)
    int roiStartY = (height * 0.50).toInt();
    int roiEndY = (height * 0.85).toInt();
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

    // 야간 헤드라이트 플래시 노이즈 필터
    double lumaDelta = (globalLuma - prevGlobalLuma).abs();
    prevGlobalLuma = globalLuma;
    if (lumaDelta > 40.0) return;

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
      // 2단계: 주행 중 전방 통행량이 급증하거나 특이점(갑작스러운 장애물/혼잡도 증가) 감지 시에만 알림
      if (complexityChange > 8.0 || structureDelta > 18.0) {
        alertLevel = "COMPLEXITY_HIGH";
        boxColor = Colors.orangeAccent; 
        targetZone = "전방 통행량 증가 / 특이점 감지";
        driveStatus = "도로 혼잡도 주의 안내";
        
        triggerSupportiveAlert("전방 도로 통행량이 복잡합니다. 주의해 주세요.");
      }
      else {
        alertLevel = "SAFE";
        boxColor = Colors.greenAccent;
        targetZone = "전방 도로 복잡도 모니터링";
        driveStatus = "VES 콜라보 관제 중";
        baselineStructure = (baselineStructure * 0.98) + (normalizedStructure * 0.02);
      }
      prevStructure = normalizedStructure;
    });
  }

  void triggerSupportiveAlert(String speechText) {
    final now = DateTime.now();
    // 멘트 남발 방지: 최소 12초 쿨타임 적용
    if (!isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= 12) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      flutterTts.speak(speechText);
      eventSaveCount++;
      final logEntry = "[서포트 #$eventSaveCount] ${now.toIso8601String()} | $speechText (속도: ${currentGpsSpeed.toStringAsFixed(1)}km/h)";
      _driveLogSession.add(logEntry);
      Timer(const Duration(seconds: 12), () {
        isSpeechLocked = false;
      });
    }
  }

  Future<void> stopAndSaveEDRLog() async {
    if (controller == null || !isStreaming) return;
    try {
      setState(() { saveStatusMsg = "운행 리포트 저장 중..."; });
      speedSubscription?.cancel();
      try { await controller!.stopImageStream(); } catch (e) {}
      setState(() { isStreaming = false; });

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final targetDir = Directory('/storage/emulated/0/DCIM/Camera');
      if (!await targetDir.exists()) await targetDir.create(recursive: true);

      final logFile = File('${targetDir.path}/VES_Collaboration_Report_$timestamp.txt');
      _driveLogSession.add("--------------------------------------------------");
      _driveLogSession.add("종료 시각: ${DateTime.now().toIso8601String()}");
      _driveLogSession.add("총 서포트 안내 횟수: $eventSaveCount건");
      await logFile.writeAsString(_driveLogSession.join('\n'));

      setState(() {
        saveStatusMsg = "리포트 저장 완료";
        driveStatus = "관제 종료";
        boxColor = Colors.grey;
      });
    } catch (e) {
      debugPrint("Save error: $e");
    }
  }

  @override
  void dispose() {
    speedSubscription?.cancel();
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
          // 하단 거치대 시야각에 맞춘 모니터링 라인 가이드
          Align(
            alignment: const Alignment(0, 0.50),
            child: Container(
              width: size.width * 0.40, height: size.height * 0.30,
              decoration: BoxDecoration(border: Border.all(color: boxColor.withOpacity(0.5), width: 1.5), color: boxColor.withOpacity(0.02)),
            ),
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
                          if (isStreaming) Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 8), decoration: const BoxDecoration(color: Colors.orangeAccent, shape: BoxShape.circle)),
                          const Text("VES 인간-AI 콜라보 도우미", style: TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Text(driveStatus, style: TextStyle(color: boxColor, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("속도: ${currentGpsSpeed.toStringAsFixed(1)} km/h", style: const TextStyle(color: Colors.yellowAccent, fontSize: 11)),
                      Text("모니터링: $targetZone", style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    ],
                  ),
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
                  await stopAndSaveEDRLog();
                } else {
                  setState(() {
                    isRunning = true;
                    driveStatus = "VES 인간-AI 콜라보 관제 중";
                    boxColor = Colors.greenAccent;
                  });
                  initSpeedTracking();
                  if (controller != null) {
                    controller!.startImageStream((CameraImage image) {
                      if (!isRunning) return;
                      final int now = DateTime.now().millisecondsSinceEpoch;
                      if (now - lastFrameTime < 400) return;
                      if (isAnalyzingFrame) return;
                      
                      lastFrameTime = now;
                      isAnalyzingFrame = true;
                      
                      try {
                        processTrafficComplexityFrame(image);
                      } catch (e) {
                        debugPrint("Error: $e");
                      } finally {
                        isAnalyzingFrame = false;
                      }
                    });
                  }
                  setState(() { isStreaming = true; saveStatusMsg = "도로 복잡도 감시 필터 가동 중"; });
                }
              },
              child: Text(isRunning ? "■ 운행 종료 및 리포트 저장" : "▶ 관제 다시 시작", style: const TextStyle(color: Colors.black, fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
