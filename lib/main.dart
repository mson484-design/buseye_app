import 'dart:async';
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
    home: BusEyeVisionScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class BusEyeVisionScreen extends StatefulWidget {
  const BusEyeVisionScreen({Key? key}) : super(key: key);

  @override
  State<BusEyeVisionScreen> createState() => _BusEyeVisionScreenState();
}

class _BusEyeVisionScreenState extends State<BusEyeVisionScreen> {
  CameraController? controller;
  FlutterTts flutterTts = FlutterTts();

  bool isRunning = true;
  bool isProcessing = false;

  String driveStatus = "정상 주행 중";
  Color boxColor = Colors.greenAccent;
  double estimatedDistance = 15.0;
  String alertMessage = "전방 안전 확보";

  int currentAlertLevel = 0; // 0:안전, 1:주의, 2:위험
  int lastSpokenLevel = 0;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  List<int>? previousSampleBuffer;
  int frameSkipCounter = 0;
  int triggerCount = 0;

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
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      controller!.initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        startVisionStream();
      });
    }
  }

  void startVisionStream() {
    controller?.startImageStream((CameraImage image) {
      if (!isRunning || isProcessing) return;

      // 초당 연산 빈도 제어 (3프레임당 1회 연산)
      frameSkipCounter++;
      if (frameSkipCounter % 3 != 0) return;

      isProcessing = true;
      processMotionDetection(image);
    });
  }

  void processMotionDetection(CameraImage image) {
    try {
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final width = image.width;
      final height = image.height;

      // 도로/타겟팅 ROI 영역 (중앙 가로 40%~60%, 세로 45%~75%)
      int startX = (width * 0.40).toInt();
      int endX = (width * 0.60).toInt();
      int startY = (height * 0.45).toInt();
      int endY = (height * 0.75).toInt();

      List<int> currentSamples = [];
      for (int y = startY; y < endY; y += 14) {
        for (int x = startX; x < endX; x += 14) {
          int index = y * plane.bytesPerRow + x;
          if (index < bytes.length) {
            currentSamples.add(bytes[index]);
          }
        }
      }

      if (previousSampleBuffer == null || previousSampleBuffer!.length != currentSamples.length) {
        previousSampleBuffer = currentSamples;
        isProcessing = false;
        return;
      }

      // 픽셀 간 차이(Motion Delta) 합산 계산
      int totalDifference = 0;
      for (int i = 0; i < currentSamples.length; i++) {
        totalDifference += (currentSamples[i] - previousSampleBuffer![i]).abs();
      }
      int avgDiff = totalDifference ~/ currentSamples.length;
      previousSampleBuffer = currentSamples;

      // 실제 물체 접근/움직임 강도 판정
      if (avgDiff > 35) {
        // 급격한 접근 / 급제동 상황
        triggerCount = (triggerCount < 5) ? triggerCount + 2 : 5;
      } else if (avgDiff > 18) {
        // 서서히 접근 중
        triggerCount = (triggerCount < 5) ? triggerCount + 1 : 5;
      } else {
        // 움직임 없음 (안정/정차)
        if (triggerCount > 0) triggerCount--;
      }

      // 상태 확정
      if (triggerCount >= 3) {
        updateAlert(3.5, "위험 추돌 경고", Colors.redAccent, "전방 급접근! 브레이크", 2, "위험 전방 주시 브레이크");
      } else if (triggerCount >= 1) {
        updateAlert(6.5, "서행 접근 주의", Colors.orangeAccent, "앞차 접근 중 | 감속", 1, "앞차 주의");
      } else {
        updateAlert(15.0, "정상 주행 중", Colors.greenAccent, "전방 안전 확보", 0, "");
      }

    } catch (e) {
      print("Motion detection error: $e");
    } finally {
      isProcessing = false;
    }
  }

  void updateAlert(double dist, String status, Color color, String msg, int level, String speechText) {
    if (!mounted) return;

    setState(() {
      estimatedDistance = dist;
      driveStatus = status;
      boxColor = color;
      alertMessage = msg;
      currentAlertLevel = level;
    });

    final now = DateTime.now();
    // [중복 멘트 방지] 레벨이 새로 상승했을 때만 1회 출력 + 최소 5초 쿨타임
    if (level > 0 && level != lastSpokenLevel) {
      if (now.difference(lastSpokenTime).inSeconds >= 5) {
        flutterTts.speak(speechText);
        lastSpokenLevel = level;
        lastSpokenTime = now;
      }
    } else if (level == 0) {
      lastSpokenLevel = 0; // 안전 복귀 시 리셋
    }
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
                    style: TextStyle(
                      color: boxColor,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    "VES-Bus AI ON",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),

          // 3. 도로 타겟팅 박스
          Align(
            alignment: const Alignment(0, 0.45),
            child: Container(
              width: size.width * 0.72,
              height: size.height * 0.32,
              decoration: BoxDecoration(
                border: Border.all(color: boxColor, width: 3.0),
                borderRadius: BorderRadius.circular(12),
                color: boxColor.withOpacity(0.08),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: boxColor,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(8),
                        bottomRight: Radius.circular(8),
                      ),
                    ),
                    child: Text(
                      "$alertMessage | ${estimatedDistance.toStringAsFixed(1)}m",
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                setState(() {
                  isRunning = !isRunning;
                  if (!isRunning) {
                    driveStatus = "관제 중지";
                    boxColor = Colors.grey;
                  }
                });
              },
              child: Text(
                isRunning ? "■ 관제 일시 중지" : "▶ 관제 다시 시작",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
