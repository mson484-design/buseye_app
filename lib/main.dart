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
    home: FullAngleSafetyScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class FullAngleSafetyScreen extends StatefulWidget {
  const FullAngleSafetyScreen({Key? key}) : super(key: key);

  @override
  State<FullAngleSafetyScreen> createState() => _FullAngleSafetyScreenState();
}

class _FullAngleSafetyScreenState extends State<FullAngleSafetyScreen> {
  CameraController? controller;
  FlutterTts flutterTts = FlutterTts();

  bool isRunning = true;
  bool isProcessing = false;

  String driveStatus = "전방위 사각지대 관제 중";
  Color boxColor = Colors.greenAccent;
  String alertMessage = "전방 및 측면 안전 확보";
  String activeZone = "안전";

  Rect? threatBoundingBox;

  // 멘트 중복 방지 8초 락
  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  List<int>? prevFrameBytes;
  int frameSkipCounter = 0;
  int threatPersistence = 0;

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
        startFullAngleStream();
      });
    }
  }

  void startFullAngleStream() {
    controller?.startImageStream((CameraImage image) {
      if (!isRunning || isProcessing) return;

      frameSkipCounter++;
      if (frameSkipCounter % 3 != 0) return; // 10 FPS 연산

      isProcessing = true;
      inferMultiZoneCollision(image);
    });
  }

  // [핵심] 정면 + 좌/우 전측면 + 전방 하단 4대 영역 충돌 궤적 연산
  void inferMultiZoneCollision(CameraImage image) {
    try {
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final width = image.width;
      final height = image.height;

      // 카메라 화각 전체 스캔 (하늘 제외: 가로 8%~92%, 세로 35%~90%)
      int scanLeft = (width * 0.08).toInt();
      int scanRight = (width * 0.92).toInt();
      int scanTop = (height * 0.35).toInt();
      int scanBottom = (height * 0.90).toInt();

      int minX = width, maxX = 0;
      int minY = height, maxY = 0;
      int motionCount = 0;

      // 구역별 위협 픽셀 수집
      int leftThreat = 0;
      int rightThreat = 0;
      int centerThreat = 0;
      int bottomThreat = 0;

      List<int> currentSamples = [];
      int sampleIdx = 0;

      for (int y = scanTop; y < scanBottom; y += 12) {
        for (int x = scanLeft; x < scanRight; x += 12) {
          int byteIdx = y * plane.bytesPerRow + x;
          if (byteIdx < bytes.length) {
            int curVal = bytes[byteIdx];
            currentSamples.add(curVal);

            if (prevFrameBytes != null && sampleIdx < prevFrameBytes!.length) {
              int diff = (curVal - prevFrameBytes![sampleIdx]).abs();

              // 유효한 접근 모션만 감지 (임계값 55)
              if (diff > 55) {
                minX = min(minX, x);
                maxX = max(maxX, x);
                minY = min(minY, y);
                maxY = max(maxY, y);
                motionCount++;

                double relX = x / width;
                double relY = y / height;

                if (relY > 0.76) {
                  bottomThreat++; // 전방 하단 0~2m
                } else if (relX < 0.30) {
                  leftThreat++; // 좌측 측면 궤적
                } else if (relX > 0.70) {
                  rightThreat++; // 우측 측면 궤적
                } else {
                  centerThreat++; // 정면 차로 궤적
                }
              }
            }
            sampleIdx++;
          }
        }
      }

      prevFrameBytes = currentSamples;

      // 노이즈 필터링 (최소 12픽셀 이상 응집된 물체만 판정)
      if (motionCount < 12 || minX >= maxX || minY >= maxY) {
        resetToSafe();
        isProcessing = false;
        return;
      }

      Rect detectedBox = Rect.fromLTRB(
        minX.toDouble(),
        minY.toDouble(),
        maxX.toDouble(),
        maxY.toDouble(),
      );

      double boxAreaRatio = (detectedBox.width * detectedBox.height) / (width * height);

      String zoneName = "전방";
      Color alertColor = Colors.orangeAccent;
      String ttsMsg = "전방 위험 감속하십시오";
      String statusMsg = "전방 객체 접근";

      // 1. 전방 하단 사각지대 (최우선: 지면 주취자/장애물)
      if (bottomThreat >= 3 && boxAreaRatio > 0.03) {
        zoneName = "전방 하단 사각지대";
        alertColor = Colors.redAccent;
        ttsMsg = "사각지대 위험 즉시 제동";
        statusMsg = "사각지대 장애물 감지";
        threatPersistence += 2;
      }
      // 2. 좌측 측면 사각지대 (회전/끼어들기 위험)
      else if (leftThreat >= 4 && boxAreaRatio > 0.04) {
        zoneName = "좌측 사각지대";
        alertColor = Colors.orangeAccent;
        ttsMsg = "좌측 사각지대 위험 감속";
        statusMsg = "좌측 충돌 궤적 접근";
        threatPersistence += 2;
      }
      // 3. 우측 측면 사각지대 (우회전/보행자 파고듦)
      else if (rightThreat >= 4 && boxAreaRatio > 0.04) {
        zoneName = "우측 사각지대";
        alertColor = Colors.orangeAccent;
        ttsMsg = "우측 사각지대 위험 감속";
        statusMsg = "우측 충돌 궤적 접근";
        threatPersistence += 2;
      }
      // 4. 정면 충돌 궤적 (급접근)
      else if (centerThreat >= 4 && boxAreaRatio > 0.10) {
        zoneName = "정면 충돌 궤적";
        alertColor = Colors.redAccent;
        ttsMsg = "위험 전방 주시 브레이크";
        statusMsg = "전방 급접근 충돌 위험";
        threatPersistence += 2;
      }
      // 5. 정면 단순 서행 접근
      else if (centerThreat >= 3) {
        zoneName = "정면 서행 궤적";
        alertColor = Colors.orangeAccent;
        ttsMsg = "전방 위험 감속하십시오";
        statusMsg = "전방 감속 주의";
        threatPersistence += 1;
      } else {
        threatPersistence = max(0, threatPersistence - 1);
      }

      setState(() {
        threatBoundingBox = detectedBox;
        activeZone = zoneName;
      });

      if (threatPersistence >= 3) {
        executeAlert(alertColor, statusMsg, "$zoneName 위험", ttsMsg);
      } else if (threatPersistence == 0) {
        resetToSafe();
      }

    } catch (e) {
      print("Multi-zone error: $e");
    } finally {
      isProcessing = false;
    }
  }

  void executeAlert(Color color, String status, String msg, String speechText) {
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

  void resetToSafe() {
    if (!mounted) return;
    setState(() {
      threatBoundingBox = null;
      boxColor = Colors.greenAccent;
      driveStatus = "전방위 사각지대 관제 중";
      alertMessage = "전방 및 측면 안전 확보";
      activeZone = "안전";
    });
    threatPersistence = 0;
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
          // 1. 카메라 광각 뷰파인더
          SizedBox(
            width: size.width,
            height: size.height,
            child: CameraPreview(controller!),
          ),

          // 2. 감지된 위협 객체 바운딩 박스
          if (threatBoundingBox != null)
            Positioned(
              left: threatBoundingBox!.left * (size.width / (controller!.value.previewSize?.height ?? 1)),
              top: threatBoundingBox!.top * (size.height / (controller!.value.previewSize?.width ?? 1)),
              width: threatBoundingBox!.width * (size.width / (controller!.value.previewSize?.height ?? 1)),
              height: threatBoundingBox!.height * (size.height / (controller!.value.previewSize?.width ?? 1)),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: boxColor, width: 3.5),
                  color: boxColor.withOpacity(0.25),
                ),
              ),
            ),

          // 3. 상단 전방위 관제 상태창
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
                    "구역: $activeZone",
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
