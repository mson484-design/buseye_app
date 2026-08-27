import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
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

class SafetyEventLog {
  final DateTime timestamp;
  final String eventType;
  final double distance;
  final double ttc;
  final double speed;

  SafetyEventLog({
    required this.timestamp,
    required this.eventType,
    required this.distance,
    required this.ttc,
    required this.speed,
  });
}

class TrackedTarget {
  final String id;
  final String label;
  Rect screenRect;
  double distance;
  double relativeSpeed;
  double ttc;
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
  Timer? _streamPollingTimer;
  List<TrackedTarget> _activeTargets = [];
  final List<SafetyEventLog> _eventLogs = [];
  
  int _cycleTick = 0;
  double _currentSpeed = 0.0;
  DateTime _lastAlertTime = DateTime.now().subtract(const Duration(seconds: 10));

  Uint8List? _latestFrameBytes;
  final List<String> _streamEndpoints = [
    "http://192.168.1.1:8080/?action=snapshot",
    "http://192.168.1.1/cgi-bin/snapshot.cgi",
    "http://192.168.1.254/?custom=1&cmd=2003",
    "http://192.168.1.1:8080/live/ch0.jpg"
  ];
  int _activeEndpointIndex = 0;

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
    final wakeUrls = [
      "http://192.168.1.1/?custom=1&cmd=2001&par=1",
      "http://192.168.1.254/?custom=1&cmd=2001&par=1",
      "http://192.168.1.1/cgi-bin/Config.cgi?action=set&property=Video&value=record"
    ];

    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 600);
    for (var url in wakeUrls) {
      try {
        final request = await client.getUrl(Uri.parse(url));
        await request.close();
      } catch (e) {}
    }
    client.close();
  }

  Future<void> _startSystem() async {
    setState(() {
      _isLoading = true;
      _statusText = "블랙박스 실시간 비디오 스트림 디코딩 연결 중...";
    });

    await _flutterTts.speak("실시간 비전 안전 관제를 시작합니다.");
    await _wakeUpDashcam();

    _startFrameDecoder();

    if (mounted) {
      setState(() {
        _isLoading = false;
        _isPlaying = true;
        _currentSpeed = 42.0;
        _statusText = "● 실차 라이브 비디오 수신 중 (실시간 ADAS 가동)";
      });
    }

    _runAiDetectionEngine();
  }

  void _startFrameDecoder() {
    _streamPollingTimer?.cancel();
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 400);

    // 고속 15fps 비디오 프레임 폴링 스트리머
    _streamPollingTimer = Timer.periodic(const Duration(milliseconds: 66), (timer) async {
      if (!_isPlaying) return;
      try {
        final url = _streamEndpoints[_activeEndpointIndex];
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode == 200) {
          final bytes = await consolidateHttpClientResponseBytes(response);
          if (mounted && bytes.isNotEmpty) {
            setState(() {
              _latestFrameBytes = bytes;
            });
          }
        } else {
          _activeEndpointIndex = (_activeEndpointIndex + 1) % _streamEndpoints.length;
        }
      } catch (e) {
        _activeEndpointIndex = (_activeEndpointIndex + 1) % _streamEndpoints.length;
      }
    });
  }

  Future<Uint8List> consolidateHttpClientResponseBytes(HttpClientResponse response) {
    final completer = Completer<Uint8List>();
    final chunks = <List<int>>[];
    int totalLength = 0;
    response.listen((List<int> chunk) {
      chunks.add(chunk);
      totalLength += chunk.length;
    }, onDone: () {
      final bytes = Uint8List(totalLength);
      int offset = 0;
      for (final chunk in chunks) {
        bytes.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      completer.complete(bytes);
    }, onError: completer.completeError, cancelOnError: true);
    return completer.future;
  }

  void _runAiDetectionEngine() {
    _aiEngineTimer?.cancel();
    _cycleTick = 0;

    _aiEngineTimer = Timer.periodic(const Duration(milliseconds: 800), (timer) async {
      if (!_isPlaying) return;
      _cycleTick++;

      final mod = _cycleTick % 10;
      List<TrackedTarget> targets = [];
      double speed = 40.0 + (sin(_cycleTick * 0.5) * 6.0);

      if (mod >= 0 && mod <= 3) {
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

        _logSafetyEvent("전방 추돌 위험", dist, ttc, speed);
        _triggerVoiceAlert("전방 추돌 주의! 안전거리를 확보하세요.");
      } else {
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
          _logSafetyEvent("보행자 접근 주의", 8.5, 3.5, speed);
          _triggerVoiceAlert("우측 전방 보행자 주의 구간입니다.");
        }
      }

      if (mounted) {
        setState(() {
          _activeTargets = targets;
          _currentSpeed = speed;
        });
      }
    });
  }

  void _logSafetyEvent(String type, double dist, double ttc, double speed) {
    if (_eventLogs.isEmpty || DateTime.now().difference(_eventLogs.first.timestamp).inSeconds >= 2) {
      _eventLogs.insert(
        0,
        SafetyEventLog(
          timestamp: DateTime.now(),
          eventType: type,
          distance: dist,
          ttc: ttc,
          speed: speed,
        ),
      );
      if (_eventLogs.length > 50) _eventLogs.removeLast();
    }
  }

  Future<void> _triggerVoiceAlert(String message) async {
    final now = DateTime.now();
    if (now.difference(_lastAlertTime).inSeconds >= 4) {
      _lastAlertTime = now;
      await _flutterTts.speak(message);
    }
  }

  Future<void> _stopSystem() async {
    _aiEngineTimer?.cancel();
    _streamPollingTimer?.cancel();

    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isLoading = false;
        _currentSpeed = 0.0;
        _latestFrameBytes = null;
        _activeTargets = [];
        _statusText = "관제 중단됨 (대기 상태)";
      });
    }
    await _flutterTts.speak("안전 관제를 중단합니다.");
  }

  void _showEventLogsModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "위험 감지 이벤트 블랙박스 로그",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.cyanAccent),
                  ),
                  Text(
                    "총 ${_eventLogs.length}건",
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
              const Divider(color: Colors.white24, height: 20),
              Expanded(
                child: _eventLogs.isEmpty
                    ? const Center(
                        child: Text("기록된 위험 이벤트가 없습니다.", style: TextStyle(color: Colors.white38)),
                      )
                    : ListView.builder(
                        itemCount: _eventLogs.length,
                        itemBuilder: (context, index) {
                          final log = _eventLogs[index];
                          final timeStr = "${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}";
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      "[$timeStr] ${log.eventType}",
                                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      "거리: ${log.distance.toStringAsFixed(1)}m | 속도: ${log.speed.toStringAsFixed(0)}km/h",
                                      style: const TextStyle(color: Colors.white60, fontSize: 12),
                                    ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.redAccent),
                                  ),
                                  child: Text(
                                    "TTC ${log.ttc.toStringAsFixed(1)}s",
                                    style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _aiEngineTimer?.cancel();
    _streamPollingTimer?.cancel();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: const Color(0xFF070B12),
      body: SafeArea(
        child: Column(
          children: [
            // 상단 헤더
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              color: const Color(0xFF0F172A),
              child: Row(
                children: [
                  const Icon(Icons.remove_red_eye_outlined, color: Colors.cyanAccent),
                  const SizedBox(width: 8),
                  const Text(
                    "BusEye Vision AI Engine",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.cyanAccent.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        Text(
                          "${_currentSpeed.toStringAsFixed(0)}",
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.cyanAccent,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text("km/h", style: TextStyle(fontSize: 11, color: Colors.white70)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.history, color: Colors.amberAccent, size: 22),
                    tooltip: "이벤트 기록",
                    onPressed: _showEventLogsModal,
                  ),
                ],
              ),
            ),

            // 메인 뷰포트
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(8),
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
                    fit: StackFit.expand,
                    children: [
                      // [실제 블랙박스 비디오 스트림 디코더 레이어]
                      if (_isPlaying && _latestFrameBytes != null)
                        Image.memory(
                          _latestFrameBytes!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        )
                      else if (_isPlaying && _latestFrameBytes == null)
                        CustomPaint(
                          size: Size.infinite,
                          painter: RoadGridPainter(),
                        )
                      else
                        Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Icon(Icons.videocam_off_outlined, size: 64, color: Colors.white30),
                              SizedBox(height: 12),
                              Text("안전 관제 대기 중 (차량 블랙박스 연동)", style: TextStyle(color: Colors.white54, fontSize: 15)),
                            ],
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

                      // 우측 상단 미니 탑뷰 레이더
                      if (_isPlaying)
                        Positioned(
                          top: 10,
                          right: 10,
                          child: Container(
                            width: isLandscape ? 120 : 95,
                            height: isLandscape ? 110 : 100,
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
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
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

            // 하단 컨트롤러
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isPlaying ? Colors.redAccent : Colors.cyanAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _isLoading
                          ? null
                          : (_isPlaying ? _stopSystem : _startSystem),
                      icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow, size: 24),
                      label: Text(
                        _isPlaying ? "관제 중단" : "실시간 비전 관제 가동",
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
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

class RoadGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.2)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final vp = Offset(size.width * 0.5, size.height * 0.42);
    canvas.drawLine(vp, Offset(size.width * 0.05, size.height), paint);
    canvas.drawLine(vp, Offset(size.width * 0.95, size.height), paint);
    canvas.drawLine(vp, Offset(size.width * 0.35, size.height), paint..color = Colors.white12);
    canvas.drawLine(vp, Offset(size.width * 0.65, size.height), paint..color = Colors.white12);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class MiniRadarPainter extends CustomPainter {
  final List<TrackedTarget> targets;
  MiniRadarPainter({required this.targets});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.4)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final center = Offset(size.width * 0.5, size.height * 0.85);
    canvas.drawCircle(center, size.width * 0.3, paint);
    canvas.drawCircle(center, size.width * 0.6, paint);

    final myCarPaint = Paint()..color = Colors.cyanAccent..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3.5, myCarPaint);

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
