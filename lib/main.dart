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
    home: VisionSafetyScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class VisionSafetyScreen extends StatefulWidget {
  const VisionSafetyScreen({Key? key}) : super(key: key);

  @override
  State<VisionSafetyScreen> createState() => _VisionSafetyScreenState();
}

class _VisionSafetyScreenState extends State<VisionSafetyScreen> {
  CameraController? controller;
  FlutterTts flutterTts = FlutterTts();

  bool isRunning = true;
  bool isProcessing = false;

  String driveStatus = "사각지대 및 궤적 관제 중";
  Color boxColor = Colors.greenAccent;
  String alertMessage = "전방 및 측면 안전 확보";
  String riskZone = "안전";

  // TTS 8초 잠금
  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  List<int>? previousFrameBytes;
  int frameSkipCounter = 0;

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
        startRealtimeInference();
      });
    }
  }

  void startRealtimeInference() {
    controller?.startImageStream((CameraImage image) {
      if (!isRunning || isProcessing) return;

      frameSkipCounter++;
      if (frameSkipCounter % 3 != 0) return; // 10 FPS 수준 유지

      isProcessing = true;
      inferCollisionThreats(image);
    });
  }

  // [핵심 추론 엔진: 모든 움직이는 물체의 궤적 및 사각지대 분석]
  void inferCollisionThreats(CameraImage image) {
    try {
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final width = image.width;
      final height = image.height;

      // 3개 위험 구역 분할 샘플링
      // 1. 좌측 사각지대 (회전/끼어들기)
      // 2. 우측 사각지대 (회전/보행자/오토바이)
      // 3. 전방 하단 사각지대 (범퍼 근접/주취자/지면 장애물)
      int leftSideMotion = 0;
      int rightSideMotion = 0;
      int bottomBlindMotion = 0;
      int centerFrontMotion = 0;

      List<int> currentSamples = [];
      int sampleIndex = 0;

      // 샘플 그리드 스캔 (화면 전체의 위험 궤적 영역)
      for (int y = (height * 0.35).toInt(); y < (height * 0.90).toInt(); y += 14) {
        for (int x = (width * 0.10).toInt(); x < (width * 0.90).toInt(); x += 14) {
          int byteIdx = y * plane.bytesPerRow + x;
          if (byteIdx < bytes.length) {
            int curVal = bytes[byteIdx];
            currentSamples.add(curVal);

            if (previousFrameBytes != null && sampleIndex < previousFrameBytes!.length) {
              int diff = (curVal - previousFrameBytes![sampleIndex]).abs();
              
              // 뚜렷한 움직임을 보이는 객체만 추출 (임계값 50)
              if (diff > 50) {
                double relX = x / width;
                double relY = y / height;

                if (relY > 0.70) {
                  // 차량 바로 앞 전방 하단 사각지대
                  bottomBlindMotion++;
                } else if (relX < 0.30) {
                  // 좌측 궤적
                  leftSideMotion++;
                } else if (relX > 0.70) {
                  // 우측 궤적
                  rightSideMotion++;
                } else {
                  // 정면 주행 궤적
                  centerFrontMotion++;
                }
              }
            }
            sampleIndex++;
          }
        }
      }

      previousFrameBytes = currentSamples;

      // 충돌 위험 추론 및 단계 확정
      // A. 전방 하단 사각지대 위험 (최고 위험: 즉시 제동)
      if (bottomBlindMotion >= 3) {
        triggerWarning(
          Colors.redAccent,
          "전방 사각지대 객체 감지! 즉시 제동",
          "전방 하단 사각지대",
          "사각지대 위험 즉시 제동",
        );
      }
      // B. 측면(좌/우) 궤적 파고듦 위험
      else if (leftSideMotion >= 3 || rightSideMotion >= 3) {
        String side = leftSideMotion >= 3 ? "좌측" : "우측";
        triggerWarning(
          Colors.orangeAccent,
          "$side 사각지대 물체 접근 중",
          "$side 충돌 궤적",
          "측면 사각지대 위험 감속",
        );
      }
      // C. 정면 충돌 궤적 위험
      else if (centerFrontMotion >= 4) {
        triggerWarning(
          Colors.redAccent,
          "전방 급접근 객체! 브레이크",
          "정면 충돌 궤적",
          "위험 전방 주시 브레이크",
        );
      } else if (centerFrontMotion >= 2) {
        triggerWarning(
          Colors.orangeAccent,
          "전방 물체 접근 중 감속",
          "정면 서행 접근",
          "전방 위험 감속하십시오",
        );
      } else {
        resetSafeState();
      }

    } catch (e) {
      print("Inference Error: $e");
    } finally {
      isProcessing = false;
    }
  }

  void triggerWarning(Color color, String msg, String zone, String ttsText) {
    if (!mounted) return;

    setState(() {
      boxColor = color;
      alertMessage = msg;
      riskZone = zone;
      driveStatus = color == Colors.redAccent ? "긴급 충돌 경고" : "주의 감속 경고";
    });

    final now = DateTime.now();
    if (!isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= 8) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      flutterTts.speak(ttsText);

      Timer(const Duration(seconds: 8), () {
        isSpeechLocked = false;
      });
    }
  }

  void resetSafeState() {
    if (!mounted || driveStatus == "사각지대 및 궤적 관제 중") return;
    setState(() {
      boxColor = Colors.greenAccent;
      driveStatus = "사각지대 및 궤적 관제 중";
      alertMessage = "전방 및 측면 안전 확보";
      riskZone = "안전";
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
          // 1. 카메라 광각 뷰
          SizedBox(
            width: size.width,
            height: size.height,
            child: CameraPreview(controller!),
          ),

          // 2. 상단 상태바
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
                    "상태: $driveStatus",
                    style: TextStyle(color: boxColor, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "구역: $riskZone",
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),

          // 3. 광각 전방위 사각지대 관제 박스
          Align(
            alignment: const Alignment(0, 0.40),
            child: Container(
              width: size.width * 0.90,
              height: size.height * 0.45,
              decoration: BoxDecoration(
                border: Border.all(color: boxColor, width: 3.0),
                borderRadius: BorderRadius.circular(12),
                color: boxColor.withOpacity(0.06),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: boxColor,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(8),
                        bottomRight: Radius.circular(8),
                      ),
                    ),
                    child: Text(
                      alertMessage,
                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14),
                    ),
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
