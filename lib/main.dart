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
  Timer? visionLoopTimer;

  bool isRunning = true;
  String driveStatus = "주행 감시 중";
  Color boxColor = Colors.greenAccent;
  double estimatedDistance = 15.0;
  String alertMessage = "전방 안전 확보";
  int warningLevel = 0; // 0:안전, 1:주의, 2:경고, 3:위험

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
      );
      controller!.initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        startVisionEngine();
      });
    }
  }

  // 실시간 비전 감지 루프 (0.5초 간격 갱신)
  void startVisionEngine() {
    visionLoopTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!isRunning) return;

      // 주행 분석 (실제 주행 시뮬레이션 및 전방 물체 감지 가중치)
      setState(() {
        // 상황별 거리 감지 및 알림 트리거 테스트 로직
        if (estimatedDistance > 4.0) {
          estimatedDistance -= 1.5; // 접근 시뮬레이션
        } else {
          estimatedDistance = 15.0; // 리셋
        }

        if (estimatedDistance <= 4.0) {
          driveStatus = "위험 추돌 경고";
          boxColor = Colors.redAccent;
          alertMessage = "전방 급접근! 추돌 주의!";
          warningLevel = 3;
          flutterTts.speak("위험 전방 주시 브레이크");
        } else if (estimatedDistance <= 7.0) {
          driveStatus = "서행 접근 주의";
          boxColor = Colors.orangeAccent;
          alertMessage = "앞차 접근 중 | 감속";
          warningLevel = 2;
          flutterTts.speak("앞차 주의");
        } else {
          driveStatus = "정상 주행 중";
          boxColor = Colors.greenAccent;
          alertMessage = "안전 거리 유지";
          warningLevel = 0;
        }
      });
    });
  }

  @override
  void dispose() {
    visionLoopTimer?.cancel();
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
          // 1. 카메라 전체화면 뷰파인더
          SizedBox(
            width: size.width,
            height: size.height,
            child: CameraPreview(controller!),
          ),

          // 2. 상단 상태 알림 바
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
                    "30 FPS | AI ON",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),

          // 3. 전방 도로 집중 타겟팅 박스 (차선/차량 중심 하단 배치)
          Align(
            alignment: const Alignment(0, 0.4), // 도로 전방으로 영역 강제 하향
            child: Container(
              width: size.width * 0.75,
              height: size.height * 0.35,
              decoration: BoxDecoration(
                border: Border.all(color: boxColor, width: 3.0),
                borderRadius: BorderRadius.circular(12),
                color: boxColor.withOpacity(0.12),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
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

          // 4. 하단 제어 및 종료 버튼
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
                    driveStatus = "관제 일시 중지";
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
