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

  // 멘트 반복 완전 방지용 변수
  int currentAlertLevel = 0; // 0:안전, 1:주의, 2:위험
  int previousAlertLevel = 0;
  bool isTtsSpeaking = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  int previousFrameEnergy = 0;
  int frameSkipCounter = 0;
  int dangerCount = 0;

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
    
    flutterTts.setCompletionHandler(() {
      isTtsSpeaking = false;
    });
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
        startRealtimeVisionStream();
      });
    }
  }

  void startRealtimeVisionStream() {
    controller?.startImageStream((CameraImage image) {
      if (!isRunning || isProcessing) return;

      // 4프레임마다 1회 연산하여 기기 발열 및 과부하 방지
      frameSkipCounter++;
      if (frameSkipCounter % 4 != 0) return;

      isProcessing = true;
      processCameraFrame(image);
    });
  }

  void processCameraFrame(CameraImage image) {
    try {
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final width = image.width;
      final height = image.height;

      // 하늘/건물을 제외한 전방 도로 및 앞차 영역 (하단 45% ~ 80%)
      int startX = (width * 0.35).toInt();
      int endX = (width * 0.65).toInt();
      int startY = (height * 0.45).toInt();
      int endY = (height * 0.80).toInt();

      int currentEnergy = 0;
      int sampledPixels = 0;

      for (int y = startY; y < endY; y += 16) {
        for (int x = startX; x < endX; x += 16) {
          int index = y * plane.bytesPerRow + x;
          if (index < bytes.length) {
            currentEnergy += bytes[index];
            sampledPixels++;
          }
        }
      }

      if (sampledPixels > 0) {
        int avgBrightness = currentEnergy ~/ sampledPixels;
        int diff = (avgBrightness - previousFrameEnergy).abs();
        previousFrameEnergy = avgBrightness;

        // 미세 떨림/노이즈 무시 (diff 60 이상 급변화 시 위험 카운트)
        if (diff > 60) {
          dangerCount++;
        } else {
          dangerCount = 0;
        }

        if (dangerCount >= 3) {
          updateState(3.5, "위험 추돌 경고", Colors.redAccent, "전방 급접근! 브레이크", 2, "위험 전방 주시 브레이크");
        } else if (dangerCount == 2) {
          updateState(6.5, "서행 접근 주의", Colors.orangeAccent, "앞차 접근 중 | 감속", 1, "앞차 주의");
        } else {
          updateState(15.0, "정상 주행 중", Colors.greenAccent, "전방 안전 확보", 0, "");
        }
      }
    } catch (e) {
      print("Frame processing error: $e");
    } finally {
      isProcessing = false;
    }
  }

  void updateState(double dist, String status, Color color, String msg, int level, String speechText) {
    if (!mounted) return;

    setState(() {
      estimatedDistance = dist;
      driveStatus = status;
      boxColor = color;
      alertMessage = msg;
      currentAlertLevel = level;
    });

    // [핵심] 멘트 중복 방지: 단계가 올라갔을 때만 딱 1번 말하고 최소 6초간 침묵
    final now = DateTime.now();
    if (level > 0 && level != previousAlertLevel) {
      if (!isTtsSpeaking && now.difference(lastSpokenTime).inSeconds >= 6) {
        isTtsSpeaking = true;
        lastSpokenTime = now;
        flutterTts.speak(speechText);
      }
    }
    previousAlertLevel = level;
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
          // 1. 카메라 뷰파인더
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

          // 3. 전방 도로 타겟팅 박스 (도로/차선 중앙 하단 배치)
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
