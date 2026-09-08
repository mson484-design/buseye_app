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

  // 기사님 철학에 맞춘 차분한 관제 상태 메시지
  String driveStatus = "VES 사각지대 안심 관제 중";
  Color boxColor = Colors.greenAccent;
  String alertLevel = "SAFE"; 
  String targetZone = "정상 주행 시야";

  Rect? threatBoundingBox;

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

  // --- [추가] 자동 영점 조절 및 각도 진단 관련 변수 ---
  bool isCalibrated = false;       // 영점 고정 여부 (true면 연산 중단하여 발열 방지)
  double currentSpeed = 0.0;       // 현재 속도 (테스트용 가상 출발 버튼 연동)
  String calibrationStatusMsg = "대기 중 (영점 미완료)";

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
    _driveLogSession.add("=== VES 안심 운행 보조 리포트 ===");
    _driveLogSession.add("시작: ${now.toIso8601String()}");
    _driveLogSession.add("모드: 자동 영점 조절 및 사각지대 부드러운 주의 안내");
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
            processSoftSafetyFrame(image);
          } catch (e) {
            debugPrint("Frame Error: $e");
          } finally {
            isAnalyzingFrame = false; 
          }
        });

        setState(() {
          isStreaming = true;
          saveStatusMsg = "사각지대 감시 필터 가동 중";
        });

      } catch (e) {
        debugPrint("Camera Start Error: $e");
      }
    }
  }

  // --- [추가/개선] 2~3km/h 주행 시 자동 영점 조절 및 각도 이탈 진단 로직 ---
  void checkAndCalibrateAngle(double speed, int height, int edgeSum, int sampleCount) {
    if (isCalibrated) return; // 이미 영점이 잡혔다면 연산 스킵 (발열 방지)

    // 차량이 2km/h 이상으로 움직이기 시작할 때 (또는 가상 출발 버튼 클릭 시)
    if (speed >= 2.0) {
      // 소실점/구조 분석 결과 예시 (정상 주행 시야 범위 판별)
      // 시뮬레이션을 위해 edgeSum과 화면 높이를 활용한 비율 계산 대용 검증
      double angleCheckValue = sampleCount > 0 ? (edgeSum / sampleCount) : 0.0;

      // [시나리오] 정상적인 렌즈 각도 범위 내에 들어올 때
      if (angleCheckValue >= 10.0 && angleCheckValue <= 100.0) {
        setState(() {
          isCalibrated = true;
          calibrationStatusMsg = "영점 고정 완료 (정상 주행)";
        });
        triggerGentleAlert("도로 인식 완료. 안전 운행을 시작합니다.");
      } 
      // [시나리오] 카메라가 너무 하늘이나 바닥을 봐서 영점을 도저히 잡지 못할 때
      else {
        setState(() {
          calibrationStatusMsg = "각도 비정상 (점검 필요)";
        });
        triggerGentleAlert("카메라 각도가 비정상입니다. 블랙박스 렌즈 위치를 점검해 주세요.");
      }
    }
  }

  void processSoftSafetyFrame(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;
    final int width = image.width;
    final int height = image.height;
    final int rowStride = image.planes[0].bytesPerRow;

    int step = 16; 

    // 전방 사각지대 집중 감시 구역
    int roiStartY = (height * 0.42).toInt();
    int roiEndY = (height * 0.80).toInt();
    int roiStartX = (width * 0.40).toInt();
    int roiEndX = (width * 0.60).toInt();

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

    // --- [추가] 주행 시작 시 자동 영점 조절 로직 태우기 ---
    checkAndCalibrateAngle(currentSpeed, height, edgeSum, sampleCount);

    double rawStructure = edgeSum / sampleCount;
    double normalizedStructure = rawStructure * (120.0 / (globalLuma + 50.0));

    if (baselineStructure == 0.0) {
      baselineStructure = normalizedStructure;
      prevStructure = normalizedStructure;
      return;
    }

    double structureDelta = normalizedStructure - baselineStructure;
    if (structureDelta < 0) structureDelta = 0.0;
    
    double expansionSpeed = normalizedStructure - prevStructure;

    setState(() {
      // 영점이 잡힌 이후부터 사각지대/추돌 의심 감시 작동
      if (isCalibrated && (expansionSpeed > 7.0 || structureDelta > 15.0)) {
        alertLevel = "CAUTION_NOTICE";
        boxColor = Colors.orangeAccent; 
        targetZone = "전방 사각지대 / 추돌 의심";
        driveStatus = "전방 장애물 주의 안내";
        threatBoundingBox = Rect.fromCenter(
          center: Offset(MediaQuery.of(context).size.width * 0.50, MediaQuery.of(context).size.height * 0.50),
          width: MediaQuery.of(context).size.width * 0.28,
          height: MediaQuery.of(context).size.height * 0.25,
        );
        triggerGentleAlert("전방에 주의가 필요합니다. 간격을 확인하세요.");
      }
      else if (isCalibrated) {
        alertLevel = "SAFE";
        boxColor = Colors.greenAccent;
        threatBoundingBox = null;
        targetZone = "정상 주행 시야";
        driveStatus = "VES 사각지대 안심 관제 중";
        baselineStructure = (baselineStructure * 0.95) + (normalizedStructure * 0.05);
      }
      prevStructure = normalizedStructure;
    });
  }

  void triggerGentleAlert(String speechText) {
    final now = DateTime.now();
    if (!isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= 8) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      flutterTts.speak(speechText);
      eventSaveCount++;
      final logEntry = "[안내 #$eventSaveCount] ${now.toIso8601String()} | $speechText";
      _driveLogSession.add(logEntry);
      Timer(const Duration(seconds: 8), () {
        isSpeechLocked = false;
      });
    }
  }

  Future<void> stopAndSaveEDRLog() async {
    if (controller == null || !isStreaming) return;
    try {
      setState(() { saveStatusMsg = "운행 리포트 저장 중..."; });
      
      try {
        await controller!.stopImageStream();
      } catch (e) {}
      
      setState(() { isStreaming = false; });

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final targetDir = Directory('/storage/emulated/0/DCIM/Camera');
      if (!await targetDir.exists()) await targetDir.create(recursive: true);

      final logFile = File('${targetDir.path}/VES_Drive_Report_$timestamp.txt');
      _driveLogSession.add("--------------------------------------------------");
      _driveLogSession.add("종료 시각: ${DateTime.now().toIso8601String()}");
      _driveLogSession.add("총 안내 횟수: $eventSaveCount건");
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
          
          // 사각지대 전용 중앙 감시 박스
          Align(
            alignment: const Alignment(0, 0.35),
            child: Container(
              width: size.width * 0.22, height: size.height * 0.40,
              decoration: BoxDecoration(border: Border.all(color: boxColor.withOpacity(0.6), width: 2.0), color: boxColor.withOpacity(0.02)),
            ),
          ),
          if (threatBoundingBox != null)
            Positioned(
              left: threatBoundingBox!.left, top: threatBoundingBox!.top, width: threatBoundingBox!.width, height: threatBoundingBox!.height,
              child: Container(decoration: BoxDecoration(border: Border.all(color: boxColor, width: 3.0), color: boxColor.withOpacity(0.15))),
            ),
            
          // 상단 관제 상태 바
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
                          const Text("VES 사각지대 안심 도우미", style: TextStyle(color: Colors.cyanAccent, fontSize: 14, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Text(driveStatus, style: TextStyle(color: boxColor, fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("상태: $alertLevel", style: TextStyle(color: boxColor, fontSize: 12, fontWeight: FontWeight.w600)),
                      Text("영점: $calibrationStatusMsg", style: const TextStyle(color: Colors.yellowAccent, fontSize: 11)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          
          // --- [추가] 내일 영상 촬영을 위한 화면 우측 하단 '가상 출발 버튼' ---
          Positioned(
            bottom: 95, right: 20,
            child: FloatingActionButton.extended(
              onPressed: () {
                setState(() {
                  currentSpeed = 3.0; // 버튼을 누르면 3km/h 주행 시작으로 인식
                });
              },
              label: Text(isCalibrated ? '영점 완료됨' : '가상 출발(3km)'),
              icon: Icon(Icons.directions_bus),
              backgroundColor: isCalibrated ? Colors.grey : Colors.amber,
            ),
          ),

          // 하단 운행 종료 및 리포트 저장 버튼
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
                    isCalibrated = false; // 재시작 시 영점 초기화
                    currentSpeed = 0.0;
                    driveStatus = "VES 사각지대 안심 관제 중";
                    boxColor = Colors.greenAccent;
                    calibrationStatusMsg = "대기 중 (영점 미완료)";
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
                        processSoftSafetyFrame(image);
                      } catch (e) {
                        debugPrint("Error: $e");
                      } finally {
                        isAnalyzingFrame = false;
                      }
                    });
                  }
                  setState(() { isStreaming = true; saveStatusMsg = "사각지대 감시 필터 가동 중"; });
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
