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

  String driveStatus = "광각 전방 관제 중";
  Color boxColor = Colors.greenAccent;
  double estimatedDistance = 15.0;
  String alertMessage = "전방 안전 확보";

  // TTS 반복 완전 차단용 락 (8초 락)
  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 20));

  List<int>? previousSampleBuffer;
  int frameSkipCounter = 0;
  
  // 상태 변화 필터링 (히스테리시스 버퍼)
  int dangerScore = 0;

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

      // 4프레임마다 1회 연산
      frameSkipCounter++;
      if (frameSkipCounter % 4 != 0) return;

      isProcessing = true;
      processWideAngleFrame(image);
    });
  }

  void processWideAngleFrame(CameraImage image) {
    try {
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final width = image.width;
      final height = image.height;

      // [넓게 보기 설정] 버스/승용차용 광각 ROI (가로 10% ~ 90%, 세로 45% ~ 85%)
      int startX = (width * 0.10).toInt();
      int endX = (width * 0.90).toInt();
      int startY = (height * 0.45).toInt();
      int endY = (height * 0.85).toInt();

      List<int> currentSamples = [];
      for (int y = startY; y < endY; y += 16) {
        for (int x = startX; x < endX; x += 16) {
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

      int diffSum = 0;
      for (int i = 0; i < currentSamples.length; i++) {
        diffSum += (currentSamples[i] - previousSampleBuffer![i]).abs();
      }
      int avgMotionDiff = diffSum ~/ currentSamples.length;
      previousSampleBuffer = currentSamples;

      // 점수 기반 모션 필터링
      if (avgMotionDiff > 45) {
        dangerScore = (dangerScore + 2).clamp(0, 10);
      } else if (avgMotionDiff > 25) {
        dangerScore = (dangerScore + 1).clamp(0, 10);
      } else {
        dangerScore = (dangerScore - 1).clamp(0, 10);
      }

      // 점수에 따른 거리 및 상태 분류
      if (dangerScore >= 6) {
        triggerStatusUpdate(3.5, "위험 추돌 경고", Colors.redAccent, "전방 급접근! 브레이크", "위험 전방 주시 브레이크");
      } else if (dangerScore >= 3) {
        triggerStatusUpdate(6.5, "서행 접근 주의", Colors.orangeAccent, "앞차 접근 중 | 감속", "앞차 주의");
      } else {
        triggerStatusUpdate(15.0, "정상 주행 중", Colors.greenAccent, "전방 안전 확보", "");
      }

    } catch (e) {
      print("Wide vision error: $e");
    } finally {
      isProcessing = false;
    }
  }

  void triggerStatusUpdate(double dist, String status, Color color, String msg, String speechText) {
    if (!mounted) return;

    setState(() {
      estimatedDistance = dist;
      driveStatus = status;
      boxColor = color;
      alertMessage = msg;
    });

    // [강력한 8초 락] 말한 직후 8초 동안은 어떤 경고 멘트도 중복 출력 금지
    final now = DateTime.now();
    if (speechText.isNotEmpty && !isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= 8) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      flutterTts.speak(speechText);

      Timer(const Duration(seconds: 8), () {
        isSpeechLocked = false;
      });
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
          // 1. 카메라 전체화면
          SizedBox(
            width: size.width,
            height: size.height,
            child: CameraPreview(controller!),
          ),

          // 2. 상단 상태 알림창
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
                    "광각 와이드 관제",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),

          // 3. 광각 타겟팅 박스 (화면 가로 88%를 꽉 채워 양옆 차선과 보행자까지 감지)
          Align(
            alignment: const Alignment(0, 0.45),
            child: Container(
              width: size.width * 0.88,
              height: size.height * 0.38,
              decoration: BoxDecoration(
                border: Border.all(color: boxColor, width: 3.0),
                borderRadius: BorderRadius.circular(14),
                color: boxColor.withOpacity(0.06),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: boxColor,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(10),
                        bottomRight: Radius.circular(10),
                      ),
                    ),
                    child: Text(
                      "$alertMessage | ${estimatedDistance.toStringAsFixed(1)}m",
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
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
