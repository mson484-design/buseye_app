import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
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

  // 실제 GPS 속도 변수
  double currentSpeedKmh = 0.0;
  StreamSubscription<Position>? positionStream;

  String driveStatus = "VES 실측 비전(YUV) 관제 중";
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

  // YUV 픽셀 기반 적응형 변수
  double baselineStructure = 0.0;
  double prevStructure = 0.0;
  int hitCounter = 0;
  int safeReleaseCounter = 0;

  @override
  void initState() {
    super.initState();
    initTTS();
    _startNewDriveSession();
    initLocationAndSpeed();
    initCameraAndStart();
  }

  void _startNewDriveSession() {
    final now = DateTime.now();
    _driveLogSession.clear();
    _driveLogSession.add("=== VES 실차/실내 비전 EDR 관제 ===");
    _driveLogSession.add("기록 시작: ${now.toIso8601String()}");
    _driveLogSession.add("엔진: YUV420 순수 픽셀(Raw) 스트리밍 직결 (압축 데이터 배제)");
    _driveLogSession.add("--------------------------------------------------");
  }

  void initTTS() async {
    await flutterTts.setLanguage("ko-KR");
    await flutterTts.setSpeechRate(0.58);
    await flutterTts.setVolume(1.0);
  }

  Future<void> initLocationAndSpeed() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen((Position? position) {
      if (position != null && mounted) {
        setState(() {
          currentSpeedKmh = position.speed * 3.6;
          if (currentSpeedKmh < 3.0) currentSpeedKmh = 0.0; // 방 안 테스트 시 0 고정
        });
      }
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

        // MP4 녹화와 동시에 YUV 원시 픽셀 프레임 추출 (핵심 변경점)
        await controller!.startVideoRecording(onAvailable: (CameraImage image) {
          if (!isRunning) return;
          
          final int now = DateTime.now().millisecondsSinceEpoch;
          // 초당 약 4프레임 분석 (250ms 간격)
          if (now - lastFrameTime < 250) return;
          
          if (isAnalyzingFrame) return;

          lastFrameTime = now;
          isAnalyzingFrame = true;
          processRealYuvFrame(image);
          isAnalyzingFrame = false;
        });

        setState(() {
          isRecordingVideo = true;
          saveStatusMsg = "주행 영상(MP4) 및 픽셀 동시 분석 중";
        });

      } catch (e) {
        debugPrint("Camera Start Error: $e");
      }
    }
  }

  // 순수 Y (Luma: 밝기) 채널 픽셀 직접 분석
  void processRealYuvFrame(CameraImage image) {
    // 안드로이드 YUV_420_888 포맷에서 Y(밝기) 평면 추출
    final Uint8List yPlane = image.planes[0].bytes;
    final int width = image.width;
    final int height = image.height;
    final int rowStride = image.planes[0].bytesPerRow;

    int step = 8; // 성능을 위해 8픽셀 건너뛰며 스캔

    // ROI (관심 구역: 화면 중앙~하단 40%~90%)
    int roiStartY = (height * 0.40).toInt();
    int roiEndY = (height * 0.90).toInt();
    int roiStartX = (width * 0.20).toInt();
    int roiEndX = (width * 0.80).toInt();

    int edgeSum = 0;
    int sampleCount = 0;
    int globalSum = 0;
    int globalCount = 0;

    // 1. 전체 조도 파악
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

    // 2. 사각지대/전방 장애물(수직 윤곽선) 파악
    for (int y = roiStartY; y < roiEndY; y += step) {
      for (int x = roiStartX; x < roiEndX; x += step) {
        int currentIndex = (y * rowStride) + x;
        int nextYIndex = ((y + step) * rowStride) + x;

        if (nextYIndex < yPlane.length) {
          // 실제 픽셀 간 밝기 차이 = 물체의 윤곽선(명암비)
          int diff = (yPlane[currentIndex] - yPlane[nextYIndex]).abs();
          edgeSum += diff;
          sampleCount++;
        }
      }
    }

    if (sampleCount == 0) return;

    double rawStructure = edgeSum / sampleCount;
    
    // 조명 정규화 (방 안 실내등 vs 야간 헤드라이트 보정)
    double normalizedStructure = (globalLuma < 60) 
        ? rawStructure * 1.5 
        : rawStructure * (120.0 / (globalLuma + 50.0));

    if (baselineStructure == 0.0) {
      baselineStructure = normalizedStructure;
      prevStructure = normalizedStructure;
      return;
    }

    // 실제 화면 픽셀의 윤곽선 밀도 변화량
    double structureDelta = (normalizedStructure - baselineStructure).abs();
    double expansionSpeed = normalizedStructure - prevStructure;

    // 속도 보정: 방 안 테스트(0km/h)에서도 잘 반응하도록 기본값 1.0 보장
    double speedMultiplier = 1.0;
    if (currentSpeedKmh > 50) speedMultiplier = 1.3;
    
    double adjustedDelta = structureDelta * speedMultiplier;
    double adjustedExpansion = expansionSpeed * speedMultiplier;

    setState(() {
      // 픽셀 임계치: JPEG 압축이 아닌 순수 픽셀이므로 임계치를 현실화 (방안 손/사람 반응)
      
      // 1. 돌발 급침범 (카메라 앞을 갑자기 손으로 가리거나 확 다가올 때)
      if (adjustedExpansion > 6.0 || (adjustedDelta > 12.0 && adjustedExpansion > 3.0)) {
        hitCounter = 4;
        safeReleaseCounter = 0;
        alertLevel = "CRITICAL_CUTIN";
        boxColor = Colors.redAccent;
        collisionAngle = 45;
        targetZone = "돌발 대각 급침범";
        driveStatus = "돌발 침범 즉시 브레이크!";

        threatBoundingBox = Rect.fromCenter(
          center: Offset(size.width * 0.58, size.height * 0.55),
          width: size.width * 0.52,
          height: size.height * 0.45,
        );

        triggerAlert("위험 돌발 침범 즉시 브레이크", "돌발 급침범", isUrgentOverride: true);
      }
      // 2. 3단계 최종 추돌 위험 (근접)
      else if (adjustedDelta > 9.0) {
        hitCounter = max(hitCounter + 1, 3);
        safeReleaseCounter = 0;
        alertLevel = "DANGER_BRAKE";
        boxColor = Colors.red;
        collisionAngle = 5;
        targetZone = "근거리 위험 구역";
        driveStatus = "추돌 위험 즉시 브레이크!";

        threatBoundingBox = Rect.fromCenter(
          center: Offset(size.width * 0.50, size.height * 0.52),
          width: size.width * 0.46,
          height: size.height * 0.42,
        );

        triggerAlert("추돌 위험 즉시 브레이크", "3단계 위험 제동");
      }
      // 3. 2단계 감속 권고
      else if (adjustedDelta > 6.0) {
        hitCounter++;
        if (hitCounter >= 2) {
          safeReleaseCounter = 0;
          alertLevel = "WARNING_50";
          boxColor = Colors.orangeAccent;
          collisionAngle = 2;
          targetZone = "전방 접근 구간";
          driveStatus = "전방 간격 확인 감속";

          threatBoundingBox = Rect.fromCenter(
            center: Offset(size.width * 0.50, size.height * 0.45),
            width: size.width * 0.35,
            height: size.height * 0.30,
          );

          triggerAlert("전방 간격 확인 감속하십시오", "2단계 감속 권고");
        }
      }
      // 4. 1단계 전방 주의 (손이나 사람이 멀리서 포착될 때)
      else if (adjustedDelta > 3.5) {
        hitCounter++;
        if (hitCounter >= 2) {
          safeReleaseCounter = 0;
          alertLevel = "CAUTION_100";
          boxColor = Colors.yellowAccent;
          collisionAngle = 0;
          targetZone = "전방 감지 구역";
          driveStatus = "전방 주의 확인";

          threatBoundingBox = Rect.fromCenter(
            center: Offset(size.width * 0.50, size.height * 0.42),
            width: size.width * 0.28,
            height: size.height * 0.24,
          );

          triggerAlert("전방 주의하십시오", "1단계 전방 주의");
        }
      }
      // 5. 안전 (물체가 사라지면 1초 후 복귀)
      else {
        safeReleaseCounter++;
        if (safeReleaseCounter >= 4) {
          hitCounter = 0;
          alertLevel = "SAFE";
          boxColor = Colors.greenAccent;
          threatBoundingBox = null;
          targetZone = "정상 주행로";
          driveStatus = "VES 실측 비전(YUV) 관제 중";
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
      final logEntry = "[EDR #$eventSaveCount] ${now.toIso8601String()} | 속도: ${currentSpeedKmh.toStringAsFixed(0)}km/h | 단계: $alertLevel | 각도: ${collisionAngle}° | $status";
      _driveLogSession.add(logEntry);

      Timer(Duration(seconds: cooldownSec), () {
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

      final String finalVideoPath = '${targetDir.path}/VES_DriveVideo_$timestamp.mp4';
      await File(rawVideoFile.path).copy(finalVideoPath);

      final logFile = File('${targetDir.path}/VES_EDR_Report_$timestamp.txt');
      _driveLogSession.add("--------------------------------------------------");
      _driveLogSession.add("종료 시각: ${DateTime.now().toIso8601String()}");
      _driveLogSession.add("총 EDR 이벤트: $eventSaveCount건");
      await logFile.writeAsString(_driveLogSession.join('\n'));

      setState(() {
        saveStatusMsg = "MP4 및 EDR 저장 완료";
        driveStatus = "관제 및 녹화 종료";
        boxColor = Colors.grey;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("저장 완료!\n파일명: VES_DriveVideo_$timestamp.mp4"),
            backgroundColor: Colors.teal,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint("Save error: $e");
    }
  }

  @override
  void dispose() {
    positionStream?.cancel();
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
      body: Stack(
        children: [
          SizedBox(
            width: size.width,
            height: size.height,
            child: CameraPreview(controller!),
          ),

          Align(
            alignment: const Alignment(0, 0.35),
            child: Container(
              width: size.width * 0.45,
              height: size.height * 0.50,
              decoration: BoxDecoration(
                border: Border.all(color: boxColor.withOpacity(0.5), width: 2.0),
                color: boxColor.withOpacity(0.03),
              ),
            ),
          ),

          if (threatBoundingBox != null)
            Positioned(
              left: threatBoundingBox!.left,
              top: threatBoundingBox!.top,
              width: threatBoundingBox!.width,
              height: threatBoundingBox!.height,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: boxColor, width: 3.5),
                  color: boxColor.withOpacity(0.20),
                ),
              ),
            ),

          Positioned(
            top: 40,
            left: 15,
            right: 15,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: boxColor, width: 1.5),
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
                            style: const TextStyle(color: Colors.cyanAccent, fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Text(
                        driveStatus,
                        style: TextStyle(color: boxColor, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "경보단계: $alertLevel",
                        style: TextStyle(color: boxColor, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        "구역: $targetZone",
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "상태: $saveStatusMsg",
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                ],
              ),
            ),
          ),

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
                    driveStatus = "VES 실측 비전(YUV) 관제 중";
                    boxColor = Colors.greenAccent;
                  });
                  await controller?.startVideoRecording(onAvailable: (CameraImage image) {
                    if (!isRunning) return;
                    final int now = DateTime.now().millisecondsSinceEpoch;
                    if (now - lastFrameTime < 250) return;
                    if (isAnalyzingFrame) return;

                    lastFrameTime = now;
                    isAnalyzingFrame = true;
                    processRealYuvFrame(image);
                    isAnalyzingFrame = false;
                  });
                  setState(() {
                    isRecordingVideo = true;
                    saveStatusMsg = "주행 영상(MP4) 실시간 녹화 중";
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
    );
  }
}
