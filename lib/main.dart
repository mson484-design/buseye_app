import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } catch (e) {
    debugPrint('카메라 장치 검색 실패: $e');
  }
  runApp(const VesApp());
}

class VesApp extends StatelessWidget {
  const VesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VES 차량 안전 관제',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const VesMainScreen(),
    );
  }
}

class VesMainScreen extends StatefulWidget {
  const VesMainScreen({super.key});

  @override
  State<VesMainScreen> createState() => _VesMainScreenState();
}

class _VesMainScreenState extends State<VesMainScreen> {
  CameraController? _cameraController;
  final FlutterTts _tts = FlutterTts();
  double _speed = 0.0;
  String _statusText = "안전 운행 중";
  Color _statusColor = Colors.greenAccent;
  bool _isReady = false;

  Timer? _recoveryTimer;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<AccelerometerEvent>? _sensorSub;
  DateTime _lastSensorUpdate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _startSystem();
  }

  Future<void> _startSystem() async {
    // 1. 권한 요청
    await [Permission.camera, Permission.location].request();

    // 2. TTS 초기화
    try {
      await _tts.setLanguage("ko-KR");
      await _tts.setSpeechRate(0.5);
    } catch (_) {}

    // 3. 카메라 연결
    if (_cameras.isNotEmpty) {
      _cameraController = CameraController(
        _cameras[0],
        ResolutionPreset.medium, // 부하를 줄이기 위해 medium으로 안정화
        enableAudio: false,
      );
      try {
        await _cameraController!.initialize();
        if (mounted) {
          setState(() {
            _isReady = true;
          });
        }
      } catch (e) {
        debugPrint("카메라 열기 실패: $e");
      }
    }

    // 4. GPS 속도 측정 (안전 모드)
    try {
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 2,
        ),
      ).listen(
        (Position pos) {
          if (mounted) {
            setState(() {
              _speed = (pos.speed > 0 ? pos.speed : 0.0) * 3.6;
            });
          }
        },
        onError: (e) => debugPrint("GPS 수신 대기 중: $e"),
      );
    } catch (e) {
      debugPrint("위치 센서 오류: $e");
    }

    // 5. 급감속/충격 센서 감지 (과부하 방지 쓰로틀링 적용)
    _sensorSub = accelerometerEventStream().listen((AccelerometerEvent e) {
      final now = DateTime.now();
      // 0.3초마다 한 번씩만 계산하여 멈춤 현상 차단
      if (now.difference(_lastSensorUpdate).inMilliseconds < 300) return;
      _lastSensorUpdate = now;

      // 흔들림 또는 충격 감지 임계치
      if (e.x.abs() > 6.0 || e.y.abs() > 6.0 || (e.z.abs() - 9.8).abs() > 6.0) {
        _triggerAlert("급감속/충격 주의!", Colors.redAccent, "주의하세요");
      }
    });
  }

  void _triggerAlert(String text, Color color, String voiceMsg) {
    if (!mounted) return;

    setState(() {
      _statusText = text;
      _statusColor = color;
    });

    _tts.speak(voiceMsg);

    // 3초 후 다시 '안전 운행 중'으로 자동 복귀
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _statusText = "안전 운행 중";
          _statusColor = Colors.greenAccent;
        });
      }
    });
  }

  @override
  void dispose() {
    _recoveryTimer?.cancel();
    _posSub?.cancel();
    _sensorSub?.cancel();
    _cameraController?.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. 카메라 화면
          if (_isReady && _cameraController != null && _cameraController!.value.isInitialized)
            Center(
              child: CameraPreview(_cameraController!),
            )
          else
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.greenAccent),
                  SizedBox(height: 16),
                  Text(
                    "관제 시스템 연결 중...",
                    style: TextStyle(color: Colors.white70, fontSize: 18),
                  ),
                ],
              ),
            ),

          // 2. 상단 관제 안내 직사각형 바 (고정 오버레이)
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _statusColor, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: _statusColor.withOpacity(0.3),
                      blurRadius: 10,
                      spreadRadius: 2,
                    )
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _statusText,
                      style: TextStyle(
                        color: _statusColor,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_speed.toStringAsFixed(1)} km/h',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
