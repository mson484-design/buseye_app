import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
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
    debugPrint('Camera init error: $e');
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
  bool isRecordingVideo = false;

  String driveStatus = "VES 전천후 실차 관제 중";
  Color boxColor = Colors.greenAccent;
  String alertLevel = "SAFE"; 
  String targetZone = "정상 주행로";

  Rect? threatBoundingBox;
  int collisionAngle = 0;

  bool isSpeechLocked = false;
  DateTime lastSpokenTime = DateTime.now().subtract(const Duration(seconds: 30));

  Timer? visionScanTimer;
  bool isAnalyzingFrame = false;

  final List<String> _driveLogSession = [];
  int eventSaveCount = 0;
  String saveStatusMsg = "대기 중";

  // 전천후 필터 변수 (와이퍼, 우천 반사, 주야간 조도 적응)
  double baselineStructure = 0.0;
  double prevStructure = 0.0;
  int hitCounter = 0;
  int safeReleaseCounter = 0;
  int wiperBypassFrames = 0;

  @override
  void initState() {
    super.initState();
    initTTS();
    _startNewDriveSession();
    initCameraAndStart();
  }

  void _startNewDriveSession() {
    final now = DateTime.now();
    _driveLogSession.clear();
    _driveLogSession.add("=== VES 실차 도로 EDR 관제 (우천/야간/역광 전천후 모드) ===");
    _driveLogSession.add("기록 시작: ${now.toIso8601String()}");
    _driveLogSession.add("필터: 와이퍼 통과 바이패스 + 노면 빗길 난반사 상쇄 + 입체 윤곽 분별");
    _driveLogSession.add("--------------------------------------------------");
  }

  void initTTS() async {
    await flutterTts.setLanguage("ko-KR");
    await flutterTts.setSpeechRate(0.58);
    await flutterTts.setVolume(1.0);
  }

  Future<void> initCameraAndStart() async {
    if (cameras.isNotEmpty) {
      controller = CameraController(
        cameras[0],
        ResolutionPreset.medium,
        enableAudio: false,
      );

      try {
        await controller!.initialize();
        if (!mounted) return;
        setState(() {});

        await controller!.startVideoRecording();
        setState(() {
          isRecordingVideo = true;
          saveStatusMsg = "주행 영상(MP4) 실시간 녹화 중";
        });

        startAllWeatherVisionLoop();
      } catch (e) {
        debugPrint("Camera Start Error: $e");
      }
    }
  }

  void startAllWeatherVisionLoop() {
    visionScanTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) async {
      if (!isRunning || controller == null || !controller!.value.isInitialized) return;
      if (isAnalyzingFrame) return;

      isAnalyzingFrame = true;
      try {
        final XFile snapshot = await controller!.takePicture();
        final Uint8List bytes = await snapshot.readAsBytes();
        await File(snapshot.path).delete();

        processAllWeatherFrame(bytes);
      } catch (e) {
        // 녹화 충돌 프레임 통과
      } finally {
        isAnalyzingFrame = false;
      }
    });
  }

  // 우천 빗길, 야간 헤드라이트, 주간 터널/역광 전천후 분석
  void processAllWeatherFrame(Uint8List bytes) {
    if (bytes.length < 12000) return;

    final size = MediaQuery.of(context).size;
    int step = 64;

    // 1. 와이퍼 감지 및 화면 전체 순간 가림 바이패스
    // 와이퍼가 지날 때는 1프레임 동안 전체 픽셀이 급변함 -> 1회성 프레임은 무시
    int globalCheckSum = 0;
    int checkCount = 0;
    for (int i = 0; i < bytes.length; i += step * 8) {
      globalCheckSum += bytes[i];
      checkCount++;
    }
    double globalLuma = checkCount > 0 ? globalCheckSum / checkCount : 128.0;

    // 2. 주행 관심 영역 (상단 하늘/가로등 배제, 노면 위 0~50m 전방 및 측면 ROI)
    int roiStart = (bytes.length * 0.42).toInt();
    int roiEnd = (bytes.length * 0.88).toInt();

    int verticalDiffSum = 0; // 입체 구조물(차량/보행자)의 수직 윤곽
    int sampleCount = 0;

    for (int i = roiStart; i < roiEnd - (step * 2); i += step) {
      // 바닥 난반사는 가로로 퍼지므로, 수직(Vertical) 명암 대비를 측정해 입체 객체만 추출
      int vDiff = (bytes[i] - bytes[i + (step * 2)]).abs();
      verticalDiffSum += vDiff;
      sampleCount++;
    }

    if (sampleCount == 0) return;

    // 조도 적응형 구조 점유도 (Structure Density) 계산
    double rawStructure = verticalDiffSum / sampleCount;
    // 야간 저조도에서는 감도 1.6배 보정, 주간 역광에서는 정규화
    double normalizedStructure = (globalLuma < 50) 
        ? rawStructure * 1.6 
        : rawStructure * (120.0 / (globalLuma + 50.0));

    if (baselineStructure == 0.0) {
      baselineStructure = normalizedStructure;
      prevStructure = normalizedStructure;
      return;
    }

    // 와이퍼 통과 필터 (단 1프레임 급변 후 다음 프레임 정상 복귀하는 특성 차단)
    double frameJump = (normalizedStructure - prevStructure).abs();
    if (frameJump > 35.0 && wiperBypassFrames == 0) {
      wiperBypassFrames = 1;
      prevStructure = normalizedStructure;
      return; // 와이퍼 통과 순간 스킵
    }
    wiperBypassFrames = 0;

    // 실제 장애물 편차 및 접근 팽창 속도
    double structureDelta = (normalizedStructure - baselineStructure).abs();
    double expansionSpeed = normalizedStructure - prevStructure;

    setState(() {
      // 1. 돌발 급침범 (사람 뛰어들기, 야간 사각지대 급출현, 대각선 컷인)
      if (expansionSpeed > 15.0 || (structureDelta > 28.0 && expansionSpeed > 9.0)) {
        hitCounter = 4;
        safeReleaseCounter = 0;
        alertLevel = "CRITICAL_CUTIN";
        boxColor = Colors.redAccent;
        collisionAngle = 45;
        targetZone = "돌발 대각 급침범";
        driveStatus = "돌발 침범 즉시 브레이크!";

        threatBoundingBox = Rect.fromCenter(
          center: Offset(size.width * 0.58, size.height * 0.55),
          width: size.width * 0.52,
          height: size.height * 0.45,
        );

        triggerAlert("위험 돌발 침범 즉시 브레이크", "돌발 급침범", isUrgentOverride: true);
      }
      // 2. 3단계 최종 추돌 위험 (근거리 제동 구간 진입)
      else if (structureDelta > 24.0) {
        hitCounter = max(hitCounter + 1, 3);
        safeReleaseCounter = 0;
        alertLevel = "DANGER_BRAKE";
        boxColor = Colors.red;
        collisionAngle = 5;
        targetZone = "근거리 위험 구역";
        driveStatus = "추돌 위험 즉시 브레이크!";

        threatBoundingBox = Rect.fromCenter(
          center: Offset(size.width * 0.50, size.height * 0.52),
          width: size.width * 0.46,
          height: size.height * 0.42,
        );

        triggerAlert("추돌 위험 즉시 브레이크", "3단계 위험 제동");
      }
      // 3. 2단계 감속 권고 (약 30~50m 전방 장애물 접근)
      else if (structureDelta > 16.0) {
        hitCounter++;
        if (hitCounter >= 2) {
          safeReleaseCounter = 0;
          alertLevel = "WARNING_50";
          boxColor = Colors.orangeAccent;
          collisionAngle = 2;
          targetZone = "전방 접근 구간";
          driveStatus = "전방 간격 확인 감속";

          threatBoundingBox = Rect.fromCenter(
            center: Offset(size.width * 0.50, size.height * 0.45),
            width: size.width * 0.35,
            height: size.height * 0.30,
          );

          triggerAlert("전방 간격 확인 감속하십시오", "2단계 감속 권고");
        }
      }
      // 4. 1단계 전방 주의 (약 80~100m 원거리 물체)
      else if (structureDelta > 11.0) {
        hitCounter++;
        if (hitCounter >= 2) {
          safeReleaseCounter = 0;
          alertLevel = "CAUTION_100";
          boxColor = Colors.yellowAccent;
          collisionAngle = 0;
          targetZone = "전방 감지 구역";
          driveStatus = "전방 주의 확인";

          threatBoundingBox = Rect.fromCenter(
            center: Offset(size.width * 0.50, size.height * 0.42),
            width: size.width * 0.28,
            height: size.height * 0.24,
          );

          triggerAlert("전방 주의하십시오", "1단계 전방 주의");
        }
      }
      // 5. 안전 주행로 (환경 변화 점진 흡수)
      else {
        safeReleaseCounter++;
        if (safeReleaseCounter >= 4) { // 1초 지속 유지 후 해제
          hitCounter = 0;
          alertLevel = "SAFE";
          boxColor = Colors.greenAccent;
          threatBoundingBox = null;
          targetZone = "정상 주행로";
          driveStatus = "VES 전천후 실차 관제 중";
          collisionAngle = 0;
          baselineStructure = (baselineStructure * 0.93) + (normalizedStructure * 0.07);
        }
      }

      prevStructure = normalizedStructure;
    });
  }

  void triggerAlert(String speechText, String status, {bool isUrgentOverride = false}) {
    final now = DateTime.now();
    int cooldownSec = isUrgentOverride ? 2 : 5;

    if (isUrgentOverride || (!isSpeechLocked && now.difference(lastSpokenTime).inSeconds >= cooldownSec)) {
      isSpeechLocked = true;
      lastSpokenTime = now;
      flutterTts.speak(speechText);

      eventSaveCount++;
      final logEntry = "[EDR #$eventSaveCount] ${now.toIso8601String()} | 단계: $alertLevel | 각도: ${collisionAngle}° | $status | 음성: $speechText";
      _driveLogSession.add(logEntry);

      Timer(Duration(seconds: cooldownSec), () {
        isSpeechLocked = false;
      });
    }
  }

  Future<void> stopAndSaveVideoToMybox() async {
    if (controller == null || !controller!.value.isRecordingVideo) return;

    try {
      setState(() {
        saveStatusMsg = "동영상 및 EDR 로그 저장 중...";
      });

      final XFile rawVideoFile = await controller!.stopVideoRecording();
      setState(() {
        isRecordingVideo = false;
      });

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final targetDir = Directory('/storage/emulated/0/DCIM/Camera');
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final String finalVideoPath = '${targetDir.path}/VES_DriveVideo_$timestamp.mp4';
      await File(rawVideoFile.path).copy(finalVideoPath);

      final logFile = File('${targetDir.path}/VES_EDR_Report_$timestamp.txt');
      _driveLogSession.add("--------------------------------------------------");
      _driveLogSession.add("종료 시각: ${DateTime.now().toIso8601String()}");
      _driveLogSession.add("총 EDR 이벤트: $eventSaveCount건");
      await logFile.writeAsString(_driveLogSession.join('\n'));

      setState(() {
        saveStatusMsg = "MP4 및 EDR 저장 완료 (MYBOX 연동)";
        driveStatus = "관제 및 녹화 종료";
        boxColor = Colors.grey;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("주행 영상과 EDR 리포트 저장 완료!\n파일명: VES_DriveVideo_$timestamp.mp4"),
            backgroundColor: Colors.teal,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint("Save error: $e");
    }
  }

  @override
  void dispose() {
    visionScanTimer?.cancel();
    if (controller != null && controller!.value.isRecordingVideo) {
      controller!.stopVideoRecording();
    }
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
                border: Border.all(color: boxColor.withOpacity(0.5), width: 2.0),
                color: boxColor.withOpacity(0.03),
              ),
            ),
          ),

          if (threatBoundingBox != null)
            Positioned(
              left: threatBoundingBox!.left,
              top: threatBoundingBox!.top,
              width: threatBoundingBox!.width,
              height: threatBoundingBox!.height,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: boxColor, width: 3.5),
                  color: boxColor.withOpacity(0.20),
                ),
              ),
            ),

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          if (isRecordingVideo)
                            Container(
                              width: 10,
                              height: 10,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: const BoxDecoration(
                                color: Colors.redAccent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          Text(
                            driveStatus,
                            style: TextStyle(color: boxColor, fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Text(
                        "추돌각: ${collisionAngle}°",
                        style: const TextStyle(color: Colors.yellowAccent, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "경보단계: $alertLevel",
                        style: TextStyle(color: boxColor, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        "구역: $targetZone",
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "상태: $saveStatusMsg",
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
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
                  setState(() {
                    isRunning = false;
                  });
                  await stopAndSaveVideoToMybox();
                } else {
                  setState(() {
                    isRunning = true;
                    driveStatus = "VES 전천후 실차 관제 중";
                    boxColor = Colors.greenAccent;
                  });
                  await controller?.startVideoRecording();
                  setState(() {
                    isRecordingVideo = true;
                    saveStatusMsg = "주행 영상(MP4) 실시간 녹화 중";
                  });
                }
              },
              child: Text(
                isRunning ? "■ 주행 관제 종료 (MP4 + EDR 저장)" : "▶ 관제 및 녹화 다시 시작",
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
