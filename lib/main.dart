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
    home: CorridorSafetyScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class CorridorSafetyScreen extends StatefulWidget {
  const CorridorSafetyScreen({Key? key}) : super(key: key);

  @override
  State<CorridorSafetyScreen> createState() => _CorridorSafetyScreenState();
}

class _CorridorSafetyScreenState extends State<CorridorSafetyScreen> {
  CameraController? controller;
  FlutterTts flutterTts = FlutterTts();

  bool isRunning = true;
  bool isProcessing = false;

  String driveStatus = "차로 궤적 관제 중";
  Color boxColor = Colors.greenAccent;
  String alertMessage = "차로 및 사각지대 안전 확보";

  Rect? activeCorridorThreatBox;
  String targetZone = "안전";

  // TTS 8초 하드 락
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
        startCorridorStream();
      });
    }
  }

  void startCorridorStream() {
    controller?.startImageStream((CameraImage image) {
      if (!isRunning || isProcessing) return;

      frameSkipCounter++;
      if (frameSkipCounter % 3 != 0) return;

      isProcessing = true;
      processCorridorCollision(image);
    });
  }

  // [핵심] 차로 폭(Corridor) 기준 정지 주차 차량 배제 및 정면/사각지대 충돌체 판정
  void processCorridorCollision(CameraImage image) {
    try {
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final width = image.width;
      final height = image.height;

      // 주행 차로 폭 기준 정의 (화면 가로 중앙 30% ~ 70% 구역을 유효 주행로로 설정)
      int corridorLeft = (width * 0.30).toInt();
      int corridorRight = (width * 0.70).toInt();
      int scanTop = (height * 0.35).toInt();
      int scanBottom = (height * 0.88).toInt();

      int minX = width, maxX = 0;
      int minY = height, maxY = 0;
      int inCorridorMotionPixels = 0;

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

              // 픽셀 변화가 기준 이상일 때
              if (diff > 60) {
                // [필터 1] 차로 바깥쪽(양옆 주차된 차량 구역)의 단순 상대 운동은 완전 무시
                bool isInDrivingCorridor = (x >= corridorLeft && x <= corridorRight);
                
                if (isInDrivingCorridor) {
                  minX = min(minX, x);
                  maxX = max(maxX, x);
                  minY = min(minY, y);
                  maxY = max(maxY, y);
                  inCorridorMotionPixels++;
                }
              }
            }
            sampleIdx++;
          }
        }
      }

      prevFrameBytes = currentSamples;

      // 차로 내부에 응집된 객체가 없으면 즉시 안전 상태 복귀
      if (inCorridorMotionPixels < 15 || minX >= maxX || minY >= maxY) {
        setState(() {
          activeCorridorThreatBox = null;
          targetZone = "안전";
          if (driveStatus != "차로 궤적 관제 중") {
            driveStatus = "차로 궤적 관제 중";
            boxColor = Colors.greenAccent;
            alertMessage = "차로 및 사각지대 안전 확보";
          }
        });
        confirmedThreatFrames = 0;
        isProcessing = false;
        return;
      }

      // 차로 내 충돌 위협 객체 바운딩 박스
      Rect threatBox = Rect.fromLTRB(
        minX.toDouble(),
        minY.toDouble(),
        maxX.toDouble(),
        maxY.toDouble(),
      );

      double boxBottomY = threatBox.bottom / height;
      double boxArea = threatBox.width * threatBox.height;
      double corridorArea = (corridorRight - corridorLeft) * (scanBottom - scanTop).toDouble();
      double corridorOccupancy = boxArea / corridorArea;

      String zoneStr = "차로 전방";
      Color dangerColor = Colors.orangeAccent;
      String ttsText = "전방 위험 감속하십시오";
      String statusStr = "전방 객체 감지";

      // 1. 전방 하단 사각지대 (내 진행 차로 바로 앞 0~2m 지면에 머무는 장애물/주취자)
      if (boxBottomY > 0.78 && corridorOccupancy > 0.08) {
        zoneStr = "전방 하단 사각지대";
        dangerColor = Colors.redAccent;
        ttsText = "사각지대 위험 즉시 제동";
        statusStr = "사각지대 객체 감지";
        confirmedThreatFrames += 2;
      }
      // 2. 정면 충돌 궤적 (차로 폭을 25% 이상 틀어막으며 접근)
      else if (corridorOccupancy > 0.20) {
        zoneStr = "정면 충돌 궤적";
        dangerColor = Colors.redAccent;
        ttsText = "위험 전방 주시 브레이크";
        statusStr = "전방 급접근 충돌 위험";
        confirmedThreatFrames += 2;
      } 
      // 3. 차로 내 단순 감속 대상
      else if (corridorOccupancy > 0.08) {
        zoneStr = "차로 내 전방 객체";
        dangerColor = Colors.orangeAccent;
        ttsText = "전방 위험 감속하십시오";
        statusStr = "전방 감속 주의";
        confirmedThreatFrames += 1;
      } else {
        confirmedThreatFrames = max(0, confirmedThreatFrames - 1);
      }

      setState(() {
        activeCorridorThreatBox = threatBox;
        targetZone = zoneStr;
      });

      // 연속 3프레임 이상 차로를 막고 있는 실위험체만 경보
      if (confirmedThreatFrames >= 3) {
        triggerCorridorAlert(dangerColor, statusStr, "$zoneStr 장애물", ttsText);
      } else if (confirmedThreatFrames == 0) {
        resetSafeState();
      }

    } catch (e) {
      print("Corridor Processing Error: $e");
    } finally {
      isProcessing = false;
    }
  }

  void triggerCorridorAlert(Color color, String status, String msg, String speechText) {
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
      driveStatus = "차로 궤적 관제 중";
      alertMessage = "차로 및 사각지대 안전 확보";
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
          // 1. 카메라 뷰
          SizedBox(
            width: size.width,
            height: size.height,
            child: CameraPreview(controller!),
          ),

          // 2. 가상 주행 차로 가이드라인 (중앙 30%~70% 주행로 영역 시각화)
          Align(
            alignment: const Alignment(0, 0.35),
            child: Container(
              width: size.width * 0.45,
              height: size.height * 0.50,
              decoration: BoxDecoration(
                border: Border.all(color: boxColor.withOpacity(0.5), width: 1.5),
                color: boxColor.withOpacity(0.04),
              ),
            ),
          ),

          // 3. 차로 내 감지된 위협 객체 바운딩 박스
          if (activeCorridorThreatBox != null)
            Positioned(
              left: activeCorridorThreatBox!.left * (size.width / (controller!.value.previewSize?.height ?? 1)),
              top: activeCorridorThreatBox!.top * (size.height / (controller!.value.previewSize?.width ?? 1)),
              width: activeCorridorThreatBox!.width * (size.width / (controller!.value.previewSize?.height ?? 1)),
              height: activeCorridorThreatBox!.height * (size.height / (controller!.value.previewSize?.width ?? 1)),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: boxColor, width: 3.5),
                  color: boxColor.withOpacity(0.2),
                ),
              ),
            ),

          // 4. 상단 상태바
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

          // 5. 하단 제어 버튼
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
