import 'dart:async';
import 'dart:io';
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
  String roadBriefing = "도로 상태: 정상 주행로";
  String targetZone = "안전";

  Rect? threatBoundingBox;
  double prevBoxArea = 0.0;

  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  List<int>? prevFrameBytes;
  int frameSkipCounter = 0;
  int confirmedThreatFrames = 0;

  final List<String> _driveLogSession = [];
  int eventSaveCount = 0;
  String saveStatusMsg = "데이터 기록 대기 중";

  @override
  void initState() {
    super.initState();
    initTTS();
    initCamera();
    _startNewDriveSession();
  }

  void _startNewDriveSession() {
    final now = DateTime.now();
    _driveLogSession.clear();
    _driveLogSession.add("=== VES (Vehicle Eye System) 주행 관제 세션 ===");
    _driveLogSession.add("시작 시각: ${now.toIso8601String()}");
    _driveLogSession.add("-----------------------------------------------");
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
      if (frameSkipCounter % 3 != 0) return;

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

      int corridorLeft = (width * 0.32).toInt();
      int corridorRight = (width * 0.68).toInt();

      // [와이퍼 및 보닛 배제] 상단 40% 이하, 하단 82% 이상 제외
      int scanTop = (height * 0.40).toInt();
      int scanBottom = (height * 0.82).toInt();

      int minX = width, maxX = 0;
      int minY = height, maxY = 0;

      int leftDensity = 0;
      int rightDensity = 0;
      int corridorMotionPixels = 0;

      List<int> currentSamples = [];
      int sampleIdx = 0;

      for (int y = scanTop; y < scanBottom; y += 14) {
        for (int x = (width * 0.10).toInt(); x < (width * 0.90).toInt(); x += 14) {
          int byteIdx = y * plane.bytesPerRow + x;
          if (byteIdx < bytes.length) {
            int curVal = bytes[byteIdx];
            currentSamples.add(curVal);

            if (prevFrameBytes != null && sampleIdx < prevFrameBytes!.length) {
              int diff = (curVal - prevFrameBytes![sampleIdx]).abs();

              // 차량 진동 노이즈 차단 (임계값 65)
              if (diff > 65) {
                double relX = x / width;

                if (relX < 0.30) leftDensity++;
                if (relX > 0.70) rightDensity++;

                if (x >= corridorLeft && x <= corridorRight) {
                  corridorMotionPixels++;
                  minX = min(minX, x);
                  maxX = max(maxX, x);
                  minY = min(minY, y);
                  maxY = max(maxY, y);
                }
              }
            }
            sampleIdx++;
          }
        }
      }

      prevFrameBytes = currentSamples;

      // 도로 환경 실시간 브리핑
      String currentRoadStatus = "도로 상태: 정상 주행로";
      if (leftDensity > 22 && rightDensity > 22) {
        currentRoadStatus = "도로 상태: 도로폭 협소 구간";
      } else if (rightDensity > 26) {
        currentRoadStatus = "도로 상태: 우측 수풀/벽체 밀착 주의";
      } else if (leftDensity > 26) {
        currentRoadStatus = "도로 상태: 좌측 장애물 밀착 주의";
      }

      // 안전 상태 복귀 판정
      if (corridorMotionPixels < 20 || minX >= maxX || minY >= maxY) {
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
        prevBoxArea = 0.0;
        isProcessing = false;
        return;
      }

      Rect threatBox = Rect.fromLTRB(
        minX.toDouble(),
        minY.toDouble(),
        maxX.toDouble(),
        maxY.toDouble(),
      );

      double boxBottomRatio = threatBox.bottom / height;
      double boxAreaRatio = (threatBox.width * threatBox.height) / (width * height);

      // 박스 크기 확장률 (급접근 판정)
      bool isApproachingRapidly = (prevBoxArea > 0) && (boxAreaRatio > prevBoxArea * 1.35);
      prevBoxArea = boxAreaRatio;

      String zoneStr = "차로 전방";
      Color dangerColor = Colors.orangeAccent;
      String ttsCommand = "전방 주의";
      String statusStr = "전방 흐름 유지";

      if (boxBottomRatio > 0.75 && boxAreaRatio > 0.06 && isApproachingRapidly) {
        zoneStr = "전방 하단 사각지대";
        dangerColor = Colors.redAccent;
        ttsCommand = "사각지대 위험 즉시 제동";
        statusStr = "사각지대 급접근 장애물";
        confirmedThreatFrames += 2;
      } else if (boxAreaRatio > 0.18 && isApproachingRapidly) {
        zoneStr = "정면 충돌 궤적";
        dangerColor = Colors.redAccent;
        ttsCommand = "위험 전방 주시 브레이크";
        statusStr = "전방 급접근 충돌 위험";
        confirmedThreatFrames += 2;
      } else if (boxAreaRatio > 0.08 && isApproachingRapidly) {
        zoneStr = "차로 내 접근 객체";
        dangerColor = Colors.orangeAccent;
        ttsCommand = "전방 간격 확인 감속";
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

      if (confirmedThreatFrames >= 4) {
        triggerVESAlert(dangerColor, statusStr, "$zoneStr 객체 근접", ttsCommand, currentRoadStatus);
      } else if (confirmedThreatFrames == 0) {
        resetVESState(currentRoadStatus);
      }

    } catch (e) {
      print("VES Inference Error: $e");
    } finally {
      isProcessing = false;
    }
  }

  void triggerVESAlert(Color color, String status, String msg, String speechText, String roadStatus) {
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

      eventSaveCount++;
      final logEntry = "[이벤트 #$eventSaveCount] ${now.toIso8601String()} | 구역: $targetZone | 상태: $status | $roadStatus | 음성: $speechText";
      _driveLogSession.add(logEntry);

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

  // MYBOX 폴더(/DCIM/VES_Records) 자동 저장
  Future<void> _saveSessionDataToMybox() async {
    try {
      final baseDir = Directory('/storage/emulated/0/DCIM/VES_Records');

      if (!await baseDir.exists()) {
        await baseDir.create(recursive: true);
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${baseDir.path}/VES_DriveReport_$timestamp.txt');

      _driveLogSession.add("-----------------------------------------------");
      _driveLogSession.add("종료 시각: ${DateTime.now().toIso8601String()}");
      _driveLogSession.add("총 감지 이벤트 수: $eventSaveCount건");

      await file.writeAsString(_driveLogSession.join('\n'));

      setState(() {
        saveStatusMsg = "MYBOX 폴더 저장 완료";
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("주행 데이터가 DCIM/VES_Records에 저장되었습니다. (MYBOX 자동 백업)"),
            backgroundColor: Colors.teal,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      print("Save error: $e");
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
                  const SizedBox(height: 2),
                  Text(
                    "기록 상태: $saveStatusMsg",
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
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
              onPressed: () async {
                if (isRunning) {
                  await _saveSessionDataToMybox();
                  setState(() {
                    isRunning = false;
                    driveStatus = "관제 종료 (MYBOX 저장됨)";
                    boxColor = Colors.grey;
                  });
                } else {
                  _startNewDriveSession();
                  setState(() {
                    isRunning = true;
                    driveStatus = "VES 안전 관제 중";
                    boxColor = Colors.greenAccent;
                    saveStatusMsg = "새 세션 기록 중";
                  });
                }
              },
              child: Text(
                isRunning ? "■ 관제 종료 (MYBOX 자동 저장)" : "▶ 관제 다시 시작",
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
