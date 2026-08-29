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

  runApp(const BusEyeVisionApp());
}

class BusEyeVisionApp extends StatelessWidget {
  const BusEyeVisionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BusEye Vision',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const BusEyeVisionScreen(),
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

class BusEyeVisionScreen extends StatefulWidget {
  const BusEyeVisionScreen({super.key});

  @override
  State<BusEyeVisionScreen> createState() => _BusEyeVisionScreenState();
}

class _BusEyeVisionScreenState extends State<BusEyeVisionScreen> with WidgetsBindingObserver {
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

  // 광학 모션 속도 추정치 (0: 정지, 높을수록 고속 주행)
  double _vehicleMotionSpeed = 0.0;
  Uint8List? _prevRoadSample;

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
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cameraController!.initialize();
      if (mounted) {
        setState(() {
          _isCameraReady = true;
          _statusMessage = "카메라 준비 완료. 관제를 시작하세요.";
        });
      }
    } catch (e) {
      if (mounted) setState(() => _statusMessage = "카메라 권한을 확인해주세요.");
    }
  }

  Future<void> _startRealAnalysis() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    await _tts.speak("실시간 비전 안전 관제를 시작합니다.");
    setState(() {
      _isAnalyzing = true;
      _statusMessage = "● 노면 속도 연동 실시간 관제 가동 중";
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

  void _processActualCameraFrame(CameraImage image) {
    try {
      final int width = image.width;
      final int height = image.height;
      final Uint8List yPlane = image.planes[0].bytes;
      final now = DateTime.now();

      _analyzedFpsCount++;
      if (now.difference(_lastFpsTime).inMilliseconds >= 1000) {
        _currentFps = _analyzedFpsCount;
        _analyzedFpsCount = 0;
        _lastFpsTime = now;
      }

      // 1. 차량 주행 속도 추정 (노면 하단 영역 픽셀 변화율 광학 측정)
      final int roadStartY = (height * 0.75).toInt();
      final int roadEndY = (height * 0.95).toInt();
      int roadPixelDiff = 0;
      int sampleCount = 0;

      if (_prevRoadSample != null && _prevRoadSample!.length == (roadEndY - roadStartY) * width ~/ 16) {
        int sampleIdx = 0;
        for (int y = roadStartY; y < roadEndY; y += 4) {
          for (int x = (width * 0.3).toInt(); x < (width * 0.7).toInt(); x += 4) {
            int idx = y * width + x;
            if (idx < yPlane.length && sampleIdx < _prevRoadSample!.length) {
              roadPixelDiff += (yPlane[idx] - _prevRoadSample![sampleIdx]).abs();
              _prevRoadSample![sampleIdx] = yPlane[idx];
              sampleIdx++;
              sampleCount++;
            }
          }
        }
      } else {
        // 초기 샘플 버퍼 생성
        int totalSamples = ((roadEndY - roadStartY) ~/ 4) * (((width * 0.7) - (width * 0.3)) ~/ 4);
        _prevRoadSample = Uint8List(totalSamples);
        int sampleIdx = 0;
        for (int y = roadStartY; y < roadEndY; y += 4) {
          for (int x = (width * 0.3).toInt(); x < (width * 0.7).toInt(); x += 4) {
            int idx = y * width + x;
            if (idx < yPlane.length && sampleIdx < _prevRoadSample!.length) {
              _prevRoadSample![sampleIdx] = yPlane[idx];
              sampleIdx++;
            }
          }
        }
      }

      double avgMotion = sampleCount > 0 ? (roadPixelDiff / sampleCount) : 0.0;
      _vehicleMotionSpeed = (_vehicleMotionSpeed * 0.7) + (avgMotion * 0.3); // 속도 평활화

      // 2. 도로 전방 차량/장애물 ROI 스캔 (중앙 25%~75%, 높이 35%~75%)
      final int startX = (width * 0.25).toInt();
      final int endX = (width * 0.75).toInt();
      final int startY = (height * 0.35).toInt();
      final int endY = (height * 0.75).toInt();

      int edgeMass = 0;
      int minActiveY = endY;
      int maxActiveY = startY;
      int minActiveX = endX;
      int maxActiveX = startX;

      for (int y = startY; y < endY; y += 4) {
        for (int x = startX; x < endX; x += 4) {
          int index = y * width + x;
          int rightIndex = index + 4;
          int bottomIndex = (y + 4) * width + x;

          if (rightIndex < yPlane.length && bottomIndex < yPlane.length) {
            int currentY = yPlane[index];
            int diffX = (currentY - yPlane[rightIndex]).abs();
            int diffY = (currentY - yPlane[bottomIndex]).abs();

            if (diffX > 32 || diffY > 32) {
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

      // 유효 객체 판별
      if (edgeMass > 200 && maxActiveX > minActiveX && maxActiveY > minActiveY) {
        double relativeWidth = (maxActiveX - minActiveX) / width;
        double relativeHeight = (maxActiveY - minActiveY) / height;
        double boundingArea = relativeWidth * relativeHeight;

        double estimatedDist = (0.35 / (relativeWidth + 0.001)) * 12.0;
        estimatedDist = estimatedDist.clamp(2.0, 60.0);

        double dt = now.difference(_lastFrameTime).inMilliseconds / 1000.0;
        if (dt <= 0) dt = 0.05;

        double sizeDelta = boundingArea - _prevTargetSize;
        double approachRate = sizeDelta / dt;
        _prevTargetSize = boundingArea;
        _lastFrameTime = now;

        double ttc = 99.9;
        ThreatLevel threat = ThreatLevel.safe;
        String label = "전방 객체";

        // 차량 모션이 있고(실제 주행 중) 빠르게 다가올 때만 TTC 계산
        bool isVehicleMoving = _vehicleMotionSpeed > 3.5;

        if (isVehicleMoving && approachRate > 0.04) {
          ttc = (estimatedDist / (approachRate * 70.0)).clamp(0.5, 20.0);
        }

        // 위험 판별: 정지 상태(방 안, 제자리)일 때는 무조건 safe 처리
        if (isVehicleMoving) {
          if (ttc < 2.2 && estimatedDist < 15.0) {
            threat = ThreatLevel.warning;
            label = "추돌 위험!";
            _triggerActualAlert("전방 추돌 주의! 감속하세요.");
          } else if (ttc < 4.0 || estimatedDist < 12.0) {
            threat = ThreatLevel.caution;
            label = "전방 주의";
          }
        } else {
          threat = ThreatLevel.safe;
          label = "정차/서행 대기";
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
      _statusMessage = "관제 중단됨";
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
    bool isMoving = _vehicleMotionSpeed > 3.5;

    return Scaffold(
      backgroundColor: const Color(0xFF070B12),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              color: const Color(0xFF0F172A),
              child: Row(
                children: [
                  Icon(
                    isMoving ? Icons.directions_car : Icons.pause_circle_outline,
                    color: isMoving ? Colors.greenAccent : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isMoving ? "주행 감지 중" : "정차 / 서행 중",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: isMoving ? Colors.greenAccent : Colors.grey,
                    ),
                  ),
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
                                        if (target.threat == ThreatLevel.warning && target.ttc < 10.0)
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
                    _isAnalyzing ? "실제 관제 중단" : "실시간 비전 관제 가동",
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
