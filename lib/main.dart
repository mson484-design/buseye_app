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
  bool isProcessing = false;

  String driveStatus = "VES 안전 관제 중";
  Color boxColor = Colors.greenAccent;
  String alertMessage = "전방 및 차로 안전 확보";
  String roadBriefing = "도로 상태: 정상 폭 주행로";
  String targetZone = "안전";

  Rect? threatBoundingBox;

  // TTS 8초 잠금
  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  List<int>? prevFrameBytes;
  int frameSkipCounter = 0;
  int confirmedThreatFrames = 0;

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
        startVESInference();
      });
    }
  }

  void startVESInference() {
    controller?.startImageStream((CameraImage image) {
      if (!isRunning || isProcessing) return;

      frameSkipCounter++;
      if (frameSkipCounter % 3 != 0) return; // 10 FPS 연산

      isProcessing = true;
      processVESInference(image);
    });
  }

  void processVESInference(CameraImage image) {
    try {
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final width = image.width;
      final height = image.height;

      int corridorLeft = (width * 0.30).toInt();
      int corridorRight = (width * 0.70).toInt();
      int scanTop = (height * 0.35).toInt();
      int scanBottom = (height * 0.90).toInt();

      int minX = width, maxX = 0;
      int minY = height, maxY = 0;

      int leftDensity = 0;
      int rightDensity = 0;
      int corridorMotionPixels = 0;
      int bottomBlindMotion = 0;

      List<int> currentSamples = [];
      int sampleIdx = 0;

      for (int y = scanTop; y < scanBottom; y += 12) {
        for (int x = (width * 0.10).toInt(); x < (width * 0.90).toInt(); x += 12) {
          int byteIdx = y * plane.bytesPerRow + x;
          if (byteIdx < bytes.length) {
            int curVal = bytes[byteIdx];
            currentSamples.add(curVal);

            if (prevFrameBytes != null && sampleIdx < prevFrameBytes!.length) {
              int diff = (curVal - prevFrameBytes![sampleIdx]).abs();

              if (diff > 55) {
                double relX = x / width;
                double relY = y / height;

                if (relX < 0.28) leftDensity++;
                if (relX > 0.72) rightDensity++;

                if (x >= corridorLeft && x <= corridorRight) {
                  corridorMotionPixels++;
                  minX = min(minX, x);
                  maxX = max(maxX, x);
                  minY = min(minY, y);
                  maxY = max(maxY, y);

                  if (relY > 0.76) bottomBlindMotion++;
                }
              }
            }
            sampleIdx++;
          }
        }
      }

      prevFrameBytes = currentSamples;

      // 1. 도로 환경 능동 브리핑 판단
      String currentRoadStatus = "도로 상태: 정상 주행로";
      if (leftDensity > 18 && rightDensity > 18) {
        currentRoadStatus = "도로 상태: 도로폭 협소 구간";
      } else if (rightDensity > 22) {
        currentRoadStatus = "도로 상태: 우측 수풀/벽체 밀착 주의";
      } else if (leftDensity > 22) {
        currentRoadStatus = "도로 상태: 좌측 장애물 밀착 주의";
      }

      // 2. 충돌 궤적 및 사각지대 위험 판정
      if (corridorMotionPixels < 12 || minX >= maxX || minY >= maxY) {
        setState(() {
          threatBoundingBox = null;
          roadBriefing = currentRoadStatus;
          if (driveStatus != "VES 안전 관제 중") {
            driveStatus = "VES 안전 관제 중";
            boxColor = Colors.greenAccent;
            alertMessage = "전방 및 차로 안전 확보";
            targetZone = "안전";
          }
        });
        confirmedThreatFrames = 0;
        isProcessing = false;
        return;
      }

      Rect threatBox = Rect.fromLTRB(
        minX.toDouble(),
        minY.toDouble(),
        maxX.toDouble(),
        maxY.toDouble(),
      );

      double boxBottomY = threatBox.bottom / height;
      double boxAreaRatio = (threatBox.width * threatBox.height) / (width * height);

      String zoneStr = "차로 전방";
      Color dangerColor = Colors.orangeAccent;
      String ttsCommand = "전방 위험 감속하십시오";
      String statusStr = "전방 객체 접근";

      if (bottomBlindMotion >= 3 && boxAreaRatio > 0.03) {
        zoneStr = "전방 하단 사각지대";
        dangerColor = Colors.redAccent;
        ttsCommand = "사각지대 위험 즉시 제동";
        statusStr = "사각지대 주취자/장애물 감지";
        confirmedThreatFrames += 2;
      } else if (boxAreaRatio > 0.12) {
        zoneStr = "정면 충돌 궤적";
        dangerColor = Colors.redAccent;
        ttsCommand = "위험 전방 주시 브레이크";
        statusStr = "전방 급접근 충돌 위험";
        confirmedThreatFrames += 2;
      } else if (boxAreaRatio > 0.04) {
        zoneStr = "차로 내 전방 객체";
        dangerColor = Colors.orangeAccent;
        ttsCommand = "전방 위험 감속하십시오";
        statusStr = "전방 감속 주의";
        confirmedThreatFrames += 1;
      } else {
        confirmedThreatFrames = max(0, confirmedThreatFrames - 1);
      }

      setState(() {
        threatBoundingBox = threatBox;
        targetZone = zoneStr;
        roadBriefing = currentRoadStatus;
      });

      if (confirmedThreatFrames >= 3) {
        triggerVESAlert(dangerColor, statusStr, "$zoneStr 객체 근접", ttsCommand);
      } else if (confirmedThreatFrames == 0) {
        resetVESState(currentRoadStatus);
      }

    } catch (e) {
      print("VES Inference Error: $e");
    } finally {
      isProcessing = false;
    }
  }

  void triggerVESAlert(Color color, String status, String msg, String speechText) {
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

  void resetVESState(String roadStatus) {
    if (!mounted) return;
    setState(() {
      boxColor = Colors.greenAccent;
      driveStatus = "VES 안전 관제 중";
      alertMessage = "전방 및 차로 안전 확보";
      targetZone = "안전";
      roadBriefing = roadStatus;
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
                border: Border.all(color: boxColor.withOpacity(0.4), width: 1.5),
                color: boxColor.withOpacity(0.03),
              ),
            ),
          ),

          if (threatBoundingBox != null)
            Positioned(
              left: threatBoundingBox!.left * (size.width / (controller!.value.previewSize?.height ?? 1)),
              top: threatBoundingBox!.top * (size.height / (controller!.value.previewSize?.width ?? 1)),
              width: threatBoundingBox!.width * (size.width / (controller!.value.previewSize?.height ?? 1)),
              height: threatBoundingBox!.height * (size.height / (controller!.value.previewSize?.width ?? 1)),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: boxColor, width: 3.5),
                  color: boxColor.withOpacity(0.2),
                ),
              ),
            ),

          Positioned(
            top: 40,
            left: 15,
            right: 15,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                  const SizedBox(height: 4),
                  Text(
                    roadBriefing,
                    style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
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
