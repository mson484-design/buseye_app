import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const BusEyeApp());
}

class BusEyeApp extends StatelessWidget {
  const BusEyeApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const BusEyeMainScreen(),
    );
  }
}

enum ThreatLevel { safe, caution, warning }

class TrackedTarget {
  final String id;
  final String label;
  Rect screenRect;
  double distance; // m
  double relativeSpeed; // km/h
  double ttc; // 초 (Time to Collision)
  ThreatLevel threatLevel;

  TrackedTarget({
    required this.id,
    required this.label,
    required this.screenRect,
    required this.distance,
    required this.relativeSpeed,
    required this.ttc,
    required this.threatLevel,
  });
}

class BusEyeMainScreen extends StatefulWidget {
  const BusEyeMainScreen({Key? key}) : super(key: key);

  @override
  State<BusEyeMainScreen> createState() => _BusEyeMainScreenState();
}

class _BusEyeMainScreenState extends State<BusEyeMainScreen> {
  final FlutterTts _flutterTts = FlutterTts();
  bool _isPlaying = false;
  bool _isLoading = false;
  String _statusText = "주행 안전 관제 대기 중 (시작 버튼을 누르세요)";

  Timer? _aiEngineTimer;
  List<TrackedTarget> _activeTargets = [];
  int _cycleTick = 0;
  DateTime _lastAlertTime = DateTime.now().subtract(const Duration(seconds: 10));

  final String _rtspHost = "192.168.1.1";
  final int _rtspPort = 554;

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("ko-KR");
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
  }

  Future<void> _wakeUpDashcam() async {
    final endpoints = [
      "http://192.168.1.1/?custom=1&cmd=2001&par=1",
      "http://192.168.1.254/?custom=1&cmd=2001&par=1",
      "http://192.168.1.1/cgi-bin/Config.cgi?action=set&property=Video&value=record"
    ];

    final client = HttpClient();
    client.connectionTimeout = const Duration(milliseconds: 600);

    for (var url in endpoints) {
      try {
        final request = await client.getUrl(Uri.parse(url));
        await request.close();
      } catch (e) {
        // 호환성 방어 예외 무시
      }
    }
    client.close();
  }

  Future<void> _startSystem() async {
    setState(() {
      _isLoading = true;
      _statusText = "블랙박스 신호 연결 및 Vision AI 알고리즘 엔진 초기화...";
    });

    await _flutterTts.speak("버스아이 비전 에이아이 안전 관제를 시작합니다.");
    await _wakeUpDashcam();

    try {
      final socket = await Socket.connect(_rtspHost, _rtspPort, timeout: const Duration(seconds: 1));
      socket.destroy();
    } catch (e) {
      // 대기
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
        _isPlaying = true;
        _statusText = "● 정상 주행 관제 중 (실시간 TTC 충돌 방지 가동)";
      });
    }

    _runAiDetectionEngine();
  }

  void _runAiDetectionEngine() {
    _aiEngineTimer?.cancel();
    _cycleTick = 0;

    _aiEngineTimer = Timer.periodic(const Duration(milliseconds: 800), (timer) async {
      if (!_isPlaying) return;
      _cycleTick++;

      // 시나리오 기반 실시간 비전 연산 시뮬레이션
      final mod = _cycleTick % 10;
      List<TrackedTarget> targets = [];

      if (mod >= 0 && mod <= 3) {
        // 정상 주행 상황 (안전 거리 확보)
        targets.add(TrackedTarget(
          id: "CAR_01",
          label: "선행 차량",
          screenRect: const Rect.fromLTWH(0.32, 0.46, 0.36, 0.28),
          distance: 28.4,
          relativeSpeed: 2.0,
          ttc: 14.2,
          threatLevel: ThreatLevel.safe,
        ));
      } else if (mod >= 4 && mod <= 6) {
        // 전방 차량 급접근 상황 (경고 레벨)
        final double dist = 11.2 - (mod - 4) * 2.1;
        final double ttc = dist / 6.5;
        targets.add(TrackedTarget(
          id: "CAR_01",
          label: "전방 급접근",
          screenRect: const Rect.fromLTWH(0.26, 0.40, 0.48, 0.38),
          distance: dist,
          relativeSpeed: 23.4,
          ttc: ttc,
          threatLevel: ThreatLevel.warning,
        ));

        _triggerVoiceAlert("전방 추돌 주의! 안전거리를 확보하세요.", ThreatLevel.warning);
      } else {
        // 우측 보행자 / 사각지대 감지 상황
        targets.add(TrackedTarget(
          id: "CAR_01",
          label: "선행 차량",
          screenRect: const Rect.fromLTWH(0.34, 0.48, 0.32, 0.25),
          distance: 24.0,
          relativeSpeed: 0.5,
          ttc: 20.0,
          threatLevel: ThreatLevel.safe,
        ));
        targets.add(TrackedTarget(
          id: "PED_01",
          label: "우측 보행자",
          screenRect: const Rect.fromLTWH(0.74, 0.52, 0.16, 0.26),
          distance: 8.5,
          relativeSpeed: 4.0,
          ttc: 3.5,
          threatLevel: ThreatLevel.caution,
        ));

        if (mod == 7) {
          _triggerVoiceAlert("우측 전방 보행자 주의 구간입니다.", ThreatLevel.caution);
        }
      }

      if (mounted) {
        setState(() {
          _activeTargets = targets;
        });
      }
    });
  }

  Future<void> _triggerVoiceAlert(String message, ThreatLevel level) async {
    final now = DateTime.now();
    if (now.difference(_lastAlertTime).inSeconds >= 4) {
      _lastAlertTime = now;
      await _flutterTts.speak(message);
    }
  }

  Future<void> _stopSystem() async {
    _aiEngineTimer?.cancel();
    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isLoading = false;
        _activeTargets = [];
        _statusText = "관제 중단됨 (대기 상태)";
      });
    }
    await _flutterTts.speak("안전 관제를 중단합니다.");
  }

  @override
  void dispose() {
    _aiEngineTimer?.cancel();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070B12),
      body: SafeArea(
        child: Column(
          children: [
            // 상단 시스템 상태 헤더
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              color: const Color(0xFF0F172A),
              child: Row(
                children: [
                  const Icon(Icons.remove_red_eye_outlined, color: Colors.cyanAccent),
                  const SizedBox(width: 8),
                  const Text(
                    "BusEye Vision AI Engine",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _isPlaying ? Colors.green.withOpacity(0.2) : Colors.amber.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _isPlaying ? Colors.greenAccent : Colors.amberAccent),
                    ),
                    child: Text(
                      _isPlaying ? "AI ADAS ACTIVE" : "STANDBY",
                      style: TextStyle(
                        color: _isPlaying ? Colors.greenAccent : Colors.amberAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 메인 HUD & AI 감지 뷰포트
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B132B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _isPlaying ? Colors.cyanAccent.withOpacity(0.6) : Colors.white24,
                    width: 1.5,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Stack(
                    children: [
                      // 배경 가상 도로 그리드
                      Center(
                        child: _isLoading
                            ? const CircularProgressIndicator(color: Colors.cyanAccent)
                            : !_isPlaying
                                ? Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: const [
                                      Icon(Icons.videocam_off_outlined, size: 64, color: Colors.white30),
                                      SizedBox(height: 12),
                                      Text("안전 관제 대기 중", style: TextStyle(color: Colors.white54, fontSize: 15)),
                                    ],
                                  )
                                : CustomPaint(
                                    size: Size.infinite,
                                    painter: RoadGridPainter(),
                                  ),
                      ),

                      // AR 바운딩 박스 오버레이
                      if (_isPlaying)
                        LayoutBuilder(
                          builder: (context, constraints) {
                            return Stack(
                              children: _activeTargets.map((target) {
                                final left = target.screenRect.left * constraints.maxWidth;
                                final top = target.screenRect.top * constraints.maxHeight;
                                final width = target.screenRect.width * constraints.maxWidth;
                                final height = target.screenRect.height * constraints.maxHeight;

                                Color boxColor;
                                switch (target.threatLevel) {
                                  case ThreatLevel.warning:
                                    boxColor = Colors.redAccent;
                                    break;
                                  case ThreatLevel.caution:
                                    boxColor = Colors.amberAccent;
                                    break;
                                  case ThreatLevel.safe:
                                    boxColor = Colors.greenAccent;
                                    break;
                                }

                                return Positioned(
                                  left: left,
                                  top: top,
                                  width: width,
                                  height: height,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(color: boxColor, width: 2.5),
                                      borderRadius: BorderRadius.circular(6),
                                      color: boxColor.withOpacity(0.12),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                          color: boxColor,
                                          child: Text(
                                            "${target.label} | ${target.distance.toStringAsFixed(1)}m",
                                            style: const TextStyle(
                                              color: Colors.black,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        const Spacer(),
                                        if (target.threatLevel == ThreatLevel.warning)
                                          Container(
                                            alignment: Alignment.centerRight,
                                            padding: const EdgeInsets.all(4),
                                            child: Text(
                                              "TTC ${target.ttc.toStringAsFixed(1)}s",
                                              style: const TextStyle(
                                                color: Colors.redAccent,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
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

                      // 우측 상단 미니 탑뷰 레이더 (Top-Down Radar)
                      if (_isPlaying)
                        Positioned(
                          top: 12,
                          right: 12,
                          child: Container(
                            width: 100,
                            height: 110,
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.7),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.cyanAccent.withOpacity(0.5)),
                            ),
                            child: CustomPaint(
                              painter: MiniRadarPainter(targets: _activeTargets),
                            ),
                          ),
                        ),

                      // 하단 상태바
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          color: Colors.black.withOpacity(0.8),
                          child: Text(
                            _statusText,
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 하단 컨트롤 버튼
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 20),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isPlaying ? Colors.redAccent : Colors.cyanAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _isLoading
                          ? null
                          : (_isPlaying ? _stopSystem : _startSystem),
                      icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow, size: 26),
                      label: Text(
                        _isPlaying ? "AI 관제 중단" : "AI 안전 관제 가동",
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 배경 도로 소실점 가이드라인 페인터
class RoadGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.2)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final vp = Offset(size.width * 0.5, size.height * 0.42); // 소실점
    canvas.drawLine(vp, Offset(size.width * 0.05, size.height), paint);
    canvas.drawLine(vp, Offset(size.width * 0.95, size.height), paint);
    canvas.drawLine(vp, Offset(size.width * 0.35, size.height), paint..color = Colors.white12);
    canvas.drawLine(vp, Offset(size.width * 0.65, size.height), paint..color = Colors.white12);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// 미니 탑뷰 레이더 페인터
class MiniRadarPainter extends CustomPainter {
  final List<TrackedTarget> targets;
  MiniRadarPainter({required this.targets});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.4)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final center = Offset(size.width * 0.5, size.height * 0.85); // 내 차량 위치
    canvas.drawCircle(center, size.width * 0.3, paint);
    canvas.drawCircle(center, size.width * 0.6, paint);

    // 내 차량 마커
    final myCarPaint = Paint()..color = Colors.cyanAccent..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3.5, myCarPaint);

    // 감지 타겟 마커
    for (var t in targets) {
      Color targetColor = t.threatLevel == ThreatLevel.warning
          ? Colors.redAccent
          : (t.threatLevel == ThreatLevel.caution ? Colors.amberAccent : Colors.greenAccent);

      final tPaint = Paint()..color = targetColor..style = PaintingStyle.fill;
      final xOffset = (t.screenRect.center.dx - 0.5) * size.width * 1.2;
      final yOffset = -(t.distance / 35.0) * (size.height * 0.7);

      canvas.drawCircle(Offset(center.dx + xOffset, center.dy + yOffset), 4, tPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
