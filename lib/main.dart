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
  String detectedObject = "없음"; // 사람, 차량, 없음

  // TTS 잠금 (8초 락)
  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 20));

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
        ResolutionPreset.low, // 처리 속도 극대화를 위해 해상도 최적화
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

      // 프레임 처리 속도 개선: 3프레임당 1회 연산 (약 10 FPS 유지)
      frameSkipCounter++;
      if (frameSkipCounter % 3 != 0) return;

      isProcessing = true;
      processObjectDetection(image);
    });
  }

  // [핵심] 객체 감지 및 거리 계산 파이프라인
  void processObjectDetection(CameraImage image) {
    try {
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final width = image.width;
      final height = image.height;

      // 광각 관제 영역
      int startX = (width * 0.15).toInt();
      int endX = (width * 0.85).toInt();
      int startY = (height * 0.35).toInt();
      int endY = (height * 0.85).toInt();

      List<int> currentSamples = [];
      
      // 움직이는 객체의 윤곽(바운딩 박스) 찾기
      int minX = width, maxX = 0;
      int minY = height, maxY = 0;
      int motionPixelCount = 0;

      for (int y = startY; y < endY; y += 12) {
        for (int x = startX; x < endX; x += 12) {
          int index = y * plane.bytesPerRow + x;
          if (index < bytes.length) {
            int currentPixel = bytes[index];
            currentSamples.add(currentPixel);

            if (previousFrameBytes != null) {
              int prevPixel = previousFrameBytes![currentSamples.length - 1];
              if ((currentPixel - prevPixel).abs() > 45) { // 뚜렷한 물체 움직임만 추출
                minX = min(minX, x);
                maxX = max(maxX, x);
                minY = min(minY, y);
                maxY = max(maxY, y);
                motionPixelCount++;
              }
            }
          }
        }
      }

      previousFrameBytes = currentSamples;

      // 노이즈/TV 플리커 필터링: 화면 전체가 번쩍이는 건 무시, 너무 작은 점도 무시
      int totalSampledArea = ((endX - startX) ~/ 12) * ((endY - startY) ~/ 12);
      if (motionPixelCount < 5 || motionPixelCount > totalSampledArea * 0.7) {
        setSafeState();
        isProcessing = false;
        return;
      }

      // 객체 크기 (가로/세로 비율 계산)
      int objWidth = maxX - minX;
      int objHeight = maxY - minY;
      
      String objType = "차량"; // 기본값
      // 높이가 너비보다 1.2배 이상 길면 사람으로 간주 (형태 감지)
      if (objHeight > objWidth * 1.2) {
        objType = "사람";
      }

      // 거리 계산 (화면에서 객체가 차지하는 세로 비율을 거리에 반비례 적용)
      double screenRatio = objHeight / (height * 0.5);
      double calcDistance = (5.0 / screenRatio).clamp(1.5, 15.0);

      evaluateDangerLevel(objType, calcDistance);

    } catch (e) {
      print("Vision Pipeline Error: $e");
    } finally {
      isProcessing = false;
    }
  }

  // [위험 단계 세분화 및 맞춤 TTS 경고]
  void evaluateDangerLevel(String objType, double dist) {
    if (dist <= 3.5) {
      // 1단계: 초근접 위험 (가장 높음)
      triggerAlert(dist, "위험 추돌 경고 ($objType)", Colors.redAccent, "급접근! 브레이크", "위험 전방 주시 브레이크", objType);
    } else if (dist <= 6.5) {
      // 2단계: 사람 접근 감속
      if (objType == "사람") {
        triggerAlert(dist, "보행자 주의", Colors.orangeAccent, "사람 접근 감속", "사람 접근 감속하십시오", objType);
      } 
      // 3단계: 차량/기타 위험 감속
      else {
        triggerAlert(dist, "차량 서행 접근", Colors.orangeAccent, "전방 위험 감속", "전방 위험 감속하십시오", objType);
      }
    } else {
      setSafeState();
    }
  }

  void triggerAlert(double dist, String status, Color color, String msg, String speechText, String obj) {
    if (!mounted) return;

    setState(() {
      estimatedDistance = dist;
      driveStatus = status;
      boxColor = color;
      alertMessage = msg;
      detectedObject = obj;
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

  void setSafeState() {
    if (!mounted || driveStatus == "정상 주행 중") return;
    setState(() {
      estimatedDistance = 15.0;
      driveStatus = "정상 주행 중";
      boxColor = Colors.greenAccent;
      alertMessage = "전방 안전 확보";
      detectedObject = "없음";
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
          // 1. 카메라
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
                    "객체: $detectedObject",
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),

          // 3. 중앙 관제 박스
          Align(
            alignment: const Alignment(0, 0.40),
            child: Container(
              width: size.width * 0.85,
              height: size.height * 0.40,
              decoration: BoxDecoration(
                border: Border.all(color: boxColor, width: 3.0),
                borderRadius: BorderRadius.circular(12),
                color: boxColor.withOpacity(0.08),
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
                      "$alertMessage | ${estimatedDistance.toStringAsFixed(1)}m",
                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 4. 하단 버튼
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
                    driveStatus = "관제 중지";
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
