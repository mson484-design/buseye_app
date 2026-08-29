import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

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

  runApp(const BusEyeGpsVisionApp());
}

class BusEyeGpsVisionApp extends StatelessWidget {
  const BusEyeGpsVisionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BusEye GPS Vision',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const BusEyeGpsVisionScreen(),
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

class BusEyeGpsVisionScreen extends StatefulWidget {
  const BusEyeGpsVisionScreen({super.key});

  @override
  State<BusEyeGpsVisionScreen> createState() => _BusEyeGpsVisionScreenState();
}

class _BusEyeGpsVisionScreenState extends State<BusEyeGpsVisionScreen> with WidgetsBindingObserver {
  final FlutterTts _tts = FlutterTts();
  CameraController? _cameraController;
  StreamSubscription<Position>? _gpsStreamSubscription;

  bool _isCameraReady = false;
  bool _isAnalyzing = false;
  bool _isProcessingFrame = false;

  double _currentSpeedKmh = 0.0; // 실제 GPS 주행 속도
  List<RealDetectedTarget> _detectedTargets = [];
  String _statusMessage = "위치 권한 확인 및 카메라 준비 중...";
  int _analyzedFpsCount = 0;
  DateTime _lastFpsTime = DateTime.now();
  int _currentFps = 0;

  double _prevTargetSize = 0.0;
  DateTime _lastFrameTime = DateTime.now();
  DateTime _lastAlertTime = DateTime.now().subtract(const Duration(seconds: 10));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSystem();
  }

  Future<void> _initSystem() async {
    await _initTts();
    await _requestPermissions();
    await _initCamera();
    _startGpsTracking();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage("ko-KR");
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera, Permission.location].request();
  }

  // 실시간 GPS 속도 측정 리스너
  void _startGpsTracking() {
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 1,
    );

    _gpsStreamSubscription = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position position) {
        // m/s -> km/h 변환 (음수 방지)
        double speed = (position.speed < 0) ? 0.0 : (position.speed * 3.6);
        if (mounted) {
          setState(() {
            _currentSpeedKmh = speed;
          });
        }
      },
      onError: (e) {
        debugPrint("GPS 수신 오류: $e");
      },
    );
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
          _statusMessage = "GPS 연동 준비 완료. 관제를 시작하세요.";
        });
      }
    } catch (e) {
      if (mounted) setState(() => _statusMessage = "카메라 권한을 확인해주세요.");
    }
  }

  Future<void> _startRealAnalysis() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    await _tts.speak("GPS 연동 실시간 비전 관제를 시작합니다.");
    setState(() {
      _isAnalyzing = true;
      _statusMessage = "● GPS 속도 기반 위험 분석 가동 중";
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

      _analyzedFpsCount++;
      final now = DateTime.now();
      if (now.difference(_lastFpsTime).inMilliseconds >= 1000) {
        _currentFps = _analyzedFpsCount;
        _analyzedFpsCount = 0;
        _lastFpsTime = now;
      }

      // 도로 중심 ROI 영역 (노면 및 상단 하늘 제외)
      final int startX = (width * 0.25).toInt();
      final int endX = (width * 0.75).toInt();
      final int startY = (height * 0.40).toInt();
      final int endY = (height * 0.80).toInt();

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

            if (diffX > 30 || diffY > 30) {
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

      // 유효 객체 감지 조건
      if (edgeMass > 180 && maxActiveX > minActiveX && maxActiveY > minActiveY) {
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

        // 실제 내 차량이 시속 5km/h 이상 주행 중일 때만 TTC 계산 활성화
        if (_currentSpeedKmh > 5.0 && approachRate > 0.02) {
          ttc = (estimatedDist / (approachRate * 80.0)).clamp(0.5, 20.0);
        }

        // 위험 단계 판단 (속도가 0~5km/h 일 때는 경고 절대 금지)
        if (_currentSpeedKmh > 5.0) {
          if (ttc < 2.2 || (estimatedDist < 8.0 && _currentSpeedKmh > 20.0)) {
            threat = ThreatLevel.warning;
            label = "추돌 위험!";
            _triggerActualAlert("전방 추돌 주의! 감속하세요.");
          } else if (ttc < 4.0 || estimatedDist < 15.0) {
            threat = ThreatLevel.caution;
            label = "전방 주의";
          }
        } else {
          // 정차/서행 시에는 안전 표시만 유지
          threat = ThreatLevel.safe;
          label = "전방 대기";
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
    _gpsStreamSubscription?.cancel();
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
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              color: const Color(0xFF0F172A),
              child: Row(
                children: [
                  const Icon(Icons.speed, color: Colors.cyanAccent),
                  const SizedBox(width: 8),
                  Text(
                    "${_currentSpeedKmh.toStringAsFixed(0)} km/h",
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.cyanAccent, fontFamily: 'monospace'),
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
                    _isAnalyzing ? "실제 관제 중단" : "GPS 연동 비전 관제 가동",
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
