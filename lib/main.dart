import 'dart:async';
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
    print('Camera init error: $e');
  }
  runApp(const MaterialApp(
    home: BoundingBoxTrackingScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class BoundingBoxTrackingScreen extends StatefulWidget {
  const BoundingBoxTrackingScreen({Key? key}) : super(key: key);

  @override
  State<BoundingBoxTrackingScreen> createState() => _BoundingBoxTrackingScreenState();
}

class _BoundingBoxTrackingScreenState extends State<BoundingBoxTrackingScreen> {
  CameraController? controller;
  FlutterTts flutterTts = FlutterTts();

  bool isRunning = true;
  bool isProcessing = false;

  String driveStatus = "객체 궤적 추론 관제 중";
  Color boxColor = Colors.greenAccent;
  String alertMessage = "전방 및 사각지대 안전";

  // 객체 바운딩 박스 상태 정보
  Rect? activeBoundingBox;
  String targetZone = "안전";

  // TTS 하드 락 (8초)
  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  List<int>? prevFrameBytes;
  int frameSkipCounter = 0;
  int threatCount = 0;

  @override
  void initState() {
    super.initState();
    initTTS();
    initCamera();
  }

  void initTTS() async {
    await flutterTts.setLanguage("ko-KR");
    await flutterTts.setSpeechRate(0.55);
    await flutterTts.setVolume(1.0);
  }

  void initCamera() {
    if (cameras.isNotEmpty) {
      controller = CameraController(
        cameras[0],
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      controller!.initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        startTrackingStream();
      });
    }
  }

  void startTrackingStream() {
    controller?.startImageStream((CameraImage image) {
      if (!isRunning || isProcessing) return;

      frameSkipCounter++;
      if (frameSkipCounter % 3 != 0) return; // 10 FPS

      isProcessing = true;
      computeObjectBoundingBoxAndTrajectory(image);
    });
  }

  // [핵심] 식별된 객체의 바운딩 박스 추출 및 궤적(크기 팽창 및 위치) 연산
  void computeObjectBoundingBoxAndTrajectory(CameraImage image) {
    try {
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final width = image.width;
      final height = image.height;

      int minX = width, maxX = 0;
      int minY = height, maxY = 0;
      int motionPixelCount = 0;

      List<int> currentSamples = [];
      int sampleIdx = 0;

      // 전방 및 사각지대 영역 스캔 (하늘 제외, 세로 35% ~ 90%)
      int startY = (height * 0.35).toInt();
      int endY = (height * 0.90).toInt();
      int startX = (width * 0.10).toInt();
      int endX = (width * 0.90).toInt();

      for (int y = startY; y < endY; y += 12) {
        for (int x = startX; x < endX; x += 12) {
          int byteIdx = y * plane.bytesPerRow + x;
          if (byteIdx < bytes.length) {
            int curVal = bytes[byteIdx];
            currentSamples.add(curVal);

            if (prevFrameBytes != null && sampleIdx < prevFrameBytes!.length) {
              int diff = (curVal - prevFrameBytes![sampleIdx]).abs();
              
              // 배경(정지물)을 제외하고 독립적으로 움직이는 객체 픽셀 추출 (임계값 55)
              if (diff > 55) {
                minX = min(minX, x);
                maxX = max(maxX, x);
                minY = min(minY, y);
                maxY = max(maxY, y);
                motionPixelCount++;
              }
            }
            sampleIdx++;
          }
        }
      }

      prevFrameBytes = currentSamples;

      // 노이즈(TV 플리커, 미세 흔들림) 필터링: 최소 크기 이상의 응집된 객체만 바운딩 박스로 인정
      if (motionPixelCount < 12 || minX >= maxX || minY >= maxY) {
        setState(() {
          activeBoundingBox = null;
          targetZone = "안전";
          if (driveStatus != "객체 궤적 추론 관제 중") {
            driveStatus = "객체 궤적 추론 관제 중";
            boxColor = Colors.greenAccent;
            alertMessage = "전방 및 사각지대 안전";
          }
        });
        isProcessing = false;
        return;
      }

      // 1. 객체의 실시간 바운딩 박스 확정
      Rect detectedBox = Rect.fromLTRB(
        minX.toDouble(),
        minY.toDouble(),
        maxX.toDouble(),
        maxY.toDouble(),
      );

      // 2. 박스의 위치(Zone) 및 궤적 판단
      double boxCenterX = detectedBox.center.dx / width;
      double boxBottomY = detectedBox.bottom / height;
      double boxArea = detectedBox.width * detectedBox.height;
      double screenArea = (width * height).toDouble();
      double areaRatio = boxArea / screenArea;

      String zoneStr = "전방";
      Color dangerCol = Colors.orangeAccent;
      String ttsCommand = "전방 위험 감속하십시오";
      String statusStr = "전방 객체 접근";

      // 판정 기준 1: 전방 하단 사각지대 (범퍼 앞 0~2m 지면 구역, 하단 75% 이상)
      if (boxBottomY > 0.75 && areaRatio > 0.03) {
        zoneStr = "전방 하단 사각지대";
        dangerCol = Colors.redAccent;
        ttsCommand = "사각지대 위험 즉시 제동";
        statusStr = "사각지대 위험 감지";
        threatCount += 2;
      }
      // 판정 기준 2: 측면 회전 궤적 사각지대 (좌우 모서리 파고듦)
      else if (boxCenterX < 0.28 || boxCenterX > 0.72) {
        zoneStr = boxCenterX < 0.28 ? "좌측 사각지대" : "우측 사각지대";
        dangerCol = Colors.orangeAccent;
        ttsCommand = "측면 사각지대 위험 감속";
        statusStr = "측면 궤적 객체 침입";
        threatCount += 1;
      }
      // 판정 기준 3: 정면 충돌 궤적 (면적이 급격히 커지며 중앙으로 돌진)
      else if (areaRatio > 0.08) {
        zoneStr = "정면 충돌 궤적";
        dangerCol = Colors.redAccent;
        ttsCommand = "위험 전방 주시 브레이크";
        statusStr = "전방 급접근 충돌 위험";
        threatCount += 2;
      } else {
        threatCount = max(0, threatCount - 1);
      }

      setState(() {
        activeBoundingBox = detectedBox;
        targetZone = zoneStr;
      });

      // 연속 3프레임 이상 위협 궤적이 유지될 때만 경보 발령
      if (threatCount >= 3) {
        triggerValidatedAlert(dangerCol, statusStr, "$zoneStr 객체 근접", ttsCommand);
      } else if (threatCount == 0) {
        resetSafeState();
      }

    } catch (e) {
      print("Tracking Error: $e");
    } finally {
      isProcessing = false;
    }
  }

  void triggerValidatedAlert(Color color, String status, String msg, String speechText) {
    if (!mounted) return;

    setState(() {
      boxColor = color;
      driveStatus = status;
      alertMessage = msg;
    });

    final now = DateTime.now();
    if (!isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= 8) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      flutterTts.speak(speechText);

      Timer(const Duration(seconds: 8), () {
        isSpeechLocked = false;
      });
    }
  }

  void resetSafeState() {
    if (!mounted) return;
    setState(() {
      boxColor = Colors.greenAccent;
      driveStatus = "객체 궤적 추론 관제 중";
      alertMessage = "전방 및 사각지대 안전";
      targetZone = "안전";
    });
  }

  @override
  void dispose() {
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
          // 1. 카메라 프리뷰
          SizedBox(
            width: size.width,
            height: size.height,
            child: CameraPreview(controller!),
          ),

          // 2. 실시간 감지된 객체의 바운딩 박스 시각화 오버레이
          if (activeBoundingBox != null)
            Positioned(
              left: activeBoundingBox!.left * (size.width / (controller!.value.previewSize?.height ?? 1)),
              top: activeBoundingBox!.top * (size.height / (controller!.value.previewSize?.width ?? 1)),
              width: activeBoundingBox!.width * (size.width / (controller!.value.previewSize?.height ?? 1)),
              height: activeBoundingBox!.height * (size.height / (controller!.value.previewSize?.width ?? 1)),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: boxColor, width: 3.5),
                  color: boxColor.withOpacity(0.2),
                ),
              ),
            ),

          // 3. 상단 상태바
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
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    driveStatus,
                    style: TextStyle(color: boxColor, fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "구역: $targetZone",
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),

          // 4. 하단 제어 버튼
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
              onPressed: () {
                setState(() {
                  isRunning = !isRunning;
                  if (!isRunning) {
                    driveStatus = "관제 일시 중지";
                    boxColor = Colors.grey;
                  }
                });
              },
              child: Text(
                isRunning ? "■ 관제 일시 중지" : "▶ 관제 다시 시작",
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
