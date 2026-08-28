import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';

List<CameraDescription> _availableCameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  try {
    _availableCameras = await availableCameras();
  } catch (e) {
    debugPrint('카메라 초기화 오류: $e');
  }

  runApp(const BusEyeRealVisionApp());
}

class BusEyeRealVisionApp extends StatelessWidget {
  const BusEyeRealVisionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BusEye Real Vision',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const BusEyeRealVisionScreen(),
    );
  }
}

enum ThreatLevel { safe, caution, warning }

class RealDetectedTarget {
  final Rect screenRect;
  final double estimatedDistance;
  final double ttc;
  final ThreatLevel threat;
  final String label;

  RealDetectedTarget({
    required this.screenRect,
    required this.estimatedDistance,
    required this.ttc,
    required this.threat,
    required this.label,
  });
}

class BusEyeRealVisionScreen extends StatefulWidget {
  const BusEyeRealVisionScreen({super.key});

  @override
  State<BusEyeRealVisionScreen> createState() => _BusEyeRealVisionScreenState();
}

class _BusEyeRealVisionScreenState extends State<BusEyeRealVisionScreen> with WidgetsBindingObserver {
  final FlutterTts _tts = FlutterTts();
  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _isAnalyzing = false;
  bool _isProcessingFrame = false;

  List<RealDetectedTarget> _detectedTargets = [];
  String _statusMessage = "카메라 준비 중...";
  int _analyzedFpsCount = 0;
  DateTime _lastFpsTime = DateTime.now();
  int _currentFps = 0;

  // 실시간 프레임 분석 추적 변수
  int _previousCenterMass = 0;
  double _prevTargetSize = 0.0;
  DateTime _lastFrameTime = DateTime.now();
  DateTime _lastAlertTime = DateTime.now().subtract(const Duration(seconds: 10));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTts();
    _initCamera();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage("ko-KR");
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
  }

  Future<void> _initCamera() async {
    if (_availableCameras.isEmpty) {
      setState(() => _statusMessage = "카메라 장치를 감지할 수 없습니다.");
      return;
    }

    CameraDescription backCam = _availableCameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => _availableCameras.first,
    );

    _cameraController = CameraController(
      backCam,
      ResolutionPreset.medium, // 고속 실시간 영상처리를 위한 최적 해상도
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cameraController!.initialize();
      if (mounted) {
        setState(() {
          _isCameraReady = true;
          _statusMessage = "실제 카메라 준비 완료. 관제를 시작하세요.";
        });
      }
    } catch (e) {
      if (mounted) setState(() => _statusMessage = "카메라 권한을 확인해주세요.");
    }
  }

  // 실제 카메라 비디오 프레임 스트림 분석 가동
  Future<void> _startRealAnalysis() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    await _tts.speak("실제 비전 AI 안전 관제를 시작합니다.");
    setState(() {
      _isAnalyzing = true;
      _statusMessage = "● 실제 영상 프레임 실시간 분석 중";
    });

    try {
      await _cameraController!.startImageStream((CameraImage image) {
        if (!_isAnalyzing || _isProcessingFrame) return;
        _isProcessingFrame = true;

        _processActualCameraFrame(image);
      });
    } catch (e) {
      debugPrint("스트림 오류: $e");
    }
  }

  // 실제 카메라 Y-Plane(명도 픽셀) 기반 위험 객체 탐지 및 TTC 계산 엔진
  void _processActualCameraFrame(CameraImage image) {
    try {
      final int width = image.width;
      final int height = image.height;
      final Uint8List yPlane = image.planes[0].bytes;

      // FPS 측정
      _analyzedFpsCount++;
      final now = DateTime.now();
      if (now.difference(_lastFpsTime).inMilliseconds >= 1000) {
        _currentFps = _analyzedFpsCount;
        _analyzedFpsCount = 0;
        _lastFpsTime = now;
      }

      // 도로 중심 영역 (ROI: 20% ~ 80% 너비, 40% ~ 85% 높이) 스캔
      final int startX = (width * 0.20).toInt();
      final int endX = (width * 0.80).toInt();
      final int startY = (height * 0.40).toInt();
      final int endY = (height * 0.85).toInt();

      int edgeMass = 0;
      int minActiveY = endY;
      int maxActiveY = startY;
      int minActiveX = endX;
      int maxActiveX = startX;

      // 4픽셀 간격 다운샘플링 고속 엣지/윤곽선 감지
      for (int y = startY; y < endY; y += 4) {
        for (int x = startX; x < endX; x += 4) {
          int index = y * width + x;
          int rightIndex = index + 4;
          int bottomIndex = (y + 4) * width + x;

          if (rightIndex < yPlane.length && bottomIndex < yPlane.length) {
            int currentY = yPlane[index];
            int diffX = (currentY - yPlane[rightIndex]).abs();
            int diffY = (currentY - yPlane[bottomIndex]).abs();

            if (diffX > 25 || diffY > 25) {
              edgeMass++;
              if (x < minActiveX) minActiveX = x;
              if (x > maxActiveX) maxActiveX = x;
              if (y < minActiveY) minActiveY = y;
              if (y > maxActiveY) maxActiveY = y;
            }
          }
        }
      }

      List<RealDetectedTarget> targets = [];

      // 유의미한 전방 물체(차량 등)가 검출된 경우
      if (edgeMass > 150 && maxActiveX > minActiveX && maxActiveY > minActiveY) {
        double relativeWidth = (maxActiveX - minActiveX) / width;
        double relativeHeight = (maxActiveY - minActiveY) / height;
        double boundingArea = relativeWidth * relativeHeight;

        // 카메라 렌즈 수식 기반 거리 추정 (원근법 모델)
        double estimatedDist = (0.35 / (relativeWidth + 0.001)) * 12.0;
        if (estimatedDist > 60.0) estimatedDist = 60.0;
        if (estimatedDist < 2.0) estimatedDist = 2.0;

        // 접근 속도 및 TTC(충돌 예상 시간) 계산
        double dt = now.difference(_lastFrameTime).inMilliseconds / 1000.0;
        if (dt <= 0) dt = 0.05;

        double sizeDelta = boundingArea - _prevTargetSize;
        double approachRate = sizeDelta / dt; // 화면 팽창 속도 (Expansion Rate)
        _prevTargetSize = boundingArea;
        _lastFrameTime = now;

        double ttc = 99.9;
        ThreatLevel threat = ThreatLevel.safe;
        String label = "전방 차량";

        if (approachRate > 0.03 && estimatedDist < 25.0) {
          ttc = (estimatedDist / (approachRate * 80.0)).clamp(0.5, 20.0);
        }

        if (estimatedDist < 10.0 || (ttc < 2.5 && approachRate > 0.05)) {
          threat = ThreatLevel.warning;
          label = "급접근 추돌위험";
          _triggerActualAlert("전방 추돌 주의! 속도를 줄이세요.");
        } else if (estimatedDist < 18.0 || ttc < 4.5) {
          threat = ThreatLevel.caution;
          label = "전방 주의";
        }

        targets.add(RealDetectedTarget(
          screenRect: Rect.fromLTRB(
            minActiveX / width,
            minActiveY / height,
            maxActiveX / width,
            maxActiveY / height,
          ),
          estimatedDistance: estimatedDist,
          ttc: ttc,
          threat: threat,
          label: label,
        ));
      }

      if (mounted) {
        setState(() {
          _detectedTargets = targets;
        });
      }
    } catch (e) {
      debugPrint("프레임 연산 예외: $e");
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _triggerActualAlert(String message) async {
    final now = DateTime.now();
    if (now.difference(_lastAlertTime).inSeconds >= 3) {
      _lastAlertTime = now;
      await _tts.speak(message);
    }
  }

  Future<void> _stopRealAnalysis() async {
    if (_cameraController != null && _cameraController!.value.isStreamingImages) {
      await _cameraController!.stopImageStream();
    }
    setState(() {
      _isAnalyzing = false;
      _detectedTargets = [];
      _statusMessage = "실제 비전 관제 중단됨";
    });
    await _tts.speak("안전 관제를 중단합니다.");
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_cameraController != null && _cameraController!.value.isStreamingImages) {
      _cameraController?.stopImageStream();
    }
    _cameraController?.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070B12),
      body: SafeArea(
        child: Column(
          children: [
            // 상단 실시간 상태바
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              color: const Color(0xFF0F172A),
              child: Row(
                children: [
                  const Icon(Icons.remove_red_eye, color: Colors.cyanAccent),
                  const SizedBox(width: 8),
                  const Text("BusEye Real Vision", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.cyanAccent.withOpacity(0.4)),
                    ),
                    child: Text(
                      "$_currentFps FPS",
                      style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            // 메인 비디오 뷰포트 + 실시간 분석 박스 오버레이
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _isAnalyzing ? Colors.cyanAccent : Colors.white24, width: 1.5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_isCameraReady && _cameraController != null)
                        CameraPreview(_cameraController!)
                      else
                        const Center(child: CircularProgressIndicator(color: Colors.cyanAccent)),

                      // 실제 감지된 객체 바운딩 박스
                      if (_isAnalyzing)
                        LayoutBuilder(
                          builder: (context, constraints) {
                            return Stack(
                              children: _detectedTargets.map((target) {
                                final left = target.screenRect.left * constraints.maxWidth;
                                final top = target.screenRect.top * constraints.maxHeight;
                                final width = target.screenRect.width * constraints.maxWidth;
                                final height = target.screenRect.height * constraints.maxHeight;

                                Color boxColor = target.threat == ThreatLevel.warning
                                    ? Colors.redAccent
                                    : (target.threat == ThreatLevel.caution ? Colors.amberAccent : Colors.greenAccent);

                                return Positioned(
                                  left: left.clamp(0.0, constraints.maxWidth - 50),
                                  top: top.clamp(0.0, constraints.maxHeight - 50),
                                  width: width.clamp(40.0, constraints.maxWidth),
                                  height: height.clamp(30.0, constraints.maxHeight),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(color: boxColor, width: 2.5),
                                      borderRadius: BorderRadius.circular(6),
                                      color: boxColor.withOpacity(0.15),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                          color: boxColor,
                                          child: Text(
                                            "${target.label} | ${target.estimatedDistance.toStringAsFixed(1)}m",
                                            style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                        const Spacer(),
                                        if (target.threat == ThreatLevel.warning)
                                          Container(
                                            alignment: Alignment.centerRight,
                                            padding: const EdgeInsets.all(4),
                                            child: Text(
                                              "TTC ${target.ttc.toStringAsFixed(1)}s",
                                              style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),

                      // 하단 상태바
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                          color: Colors.black.withOpacity(0.8),
                          child: Text(
                            _statusMessage,
                            style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 하단 가동 버튼
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isAnalyzing ? Colors.redAccent : Colors.cyanAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: !_isCameraReady ? null : (_isAnalyzing ? _stopRealAnalysis : _startRealAnalysis),
                  icon: Icon(_isAnalyzing ? Icons.stop : Icons.play_arrow, size: 24),
                  label: Text(
                    _isAnalyzing ? "실제 관제 중단" : "실시간 비전 AI 관제 가동",
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
