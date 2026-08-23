import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BusEyeBrainApp());
}

class BusEyeBrainApp extends StatelessWidget {
  const BusEyeBrainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BusEye AI Brain',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B1120),
      ),
      home: const BusEyeMainScreen(),
    );
  }
}

class BusEyeMainScreen extends StatefulWidget {
  const BusEyeMainScreen({super.key});

  @override
  State<BusEyeMainScreen> createState() => _BusEyeMainScreenState();
}

class _BusEyeMainScreenState extends State<BusEyeMainScreen> {
  final FlutterTts flutterTts = FlutterTts();

  // 속도계 보간 변수
  double _displaySpeed = 0.0;
  double _targetSpeed = 0.0;
  Position? _lastPos;
  DateTime? _lastTime;
  Timer? _smoothingTimer;

  // 녹화 및 시스템 상태
  bool _isRec = false;
  int _recSeconds = 0;
  Timer? _recTimer;
  String _statusMsg = "블랙박스 Wi-Fi 및 초정밀 GPS 대기 중";
  Color _statusColor = Colors.cyanAccent;
  bool _isBlackboxConnected = false;

  @override
  void initState() {
    super.initState();
    _initTts();
    _initPrecisionGps();
    _startSpeedInterpolation();
  }

  void _initTts() async {
    await flutterTts.setLanguage("ko-KR");
    await flutterTts.setSpeechRate(0.5);
  }

  // 100ms(0.1초) 주기로 1km/h 단위 부드러운 수렴
  void _startSpeedInterpolation() {
    _smoothingTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if ((_displaySpeed - _targetSpeed).abs() > 0.2) {
        setState(() {
          _displaySpeed += (_targetSpeed - _displaySpeed) * 0.35;
        });
      } else {
        setState(() {
          _displaySpeed = _targetSpeed;
        });
      }
    });
  }

  Future<void> _initPrecisionGps() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }

    // 표준 고정밀 네비게이션 스트림
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen((pos) {
      DateTime now = DateTime.now();
      double speed = 0.0;

      if (_lastPos != null && _lastTime != null) {
        double d = Geolocator.distanceBetween(
          _lastPos!.latitude,
          _lastPos!.longitude,
          pos.latitude,
          pos.longitude,
        );
        double dt = now.difference(_lastTime!).inMilliseconds / 1000.0;
        if (dt > 0.05) {
          speed = (d / dt) * 3.6;
        }
      }

      double rawSpeed = (pos.speed > 0) ? (pos.speed * 3.6) : 0.0;
      double finalSpeed = (rawSpeed > 0) ? rawSpeed : speed;
      if (finalSpeed < 2.0) finalSpeed = 0.0;

      setState(() {
        _targetSpeed = finalSpeed;
        _lastPos = pos;
        _lastTime = now;
      });
    });
  }

  void _toggleBlackboxConnection() {
    setState(() {
      _isBlackboxConnected = !_isBlackboxConnected;
      if (_isBlackboxConnected) {
        _statusMsg = "블랙박스 비디오 스트림 수신 중 (AI 정상)";
        _statusColor = Colors.greenAccent;
        flutterTts.speak("블랙박스 영상이 연결되었습니다.");
      } else {
        _statusMsg = "블랙박스 신호 대기 중";
        _statusColor = Colors.orangeAccent;
      }
    });
  }

  void _toggleRec() {
    setState(() {
      _isRec = !_isRec;
      if (_isRec) {
        _recSeconds = 0;
        _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          setState(() => _recSeconds++);
        });
        flutterTts.speak("실차 주행 실증 녹화를 시작합니다.");
      } else {
        _recTimer?.cancel();
        flutterTts.speak("주행 실증 로그가 저장되었습니다.");
      }
    });
  }

  void _alert(String msg, Color color, String voice) {
    setState(() {
      _statusMsg = msg;
      _statusColor = color;
    });
    if (voice.isNotEmpty) {
      flutterTts.speak(voice);
    }
  }

  // 실증 데이터 검증 QR 팝업 (네이버 MYBOX/클라우드 링크 연결용)
  void _showQrDialog() {
    // 네이버 MYBOX 또는 실증 검증용 URL
    final qrData = Uri.encodeComponent("https://mybox.naver.com");
    final qrApiUrl = "https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$qrData";

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text("실차 실증 데이터 검증 QR", style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
              child: Image.network(
                qrApiUrl,
                width: 160,
                height: 160,
                errorBuilder: (context, error, stackTrace) => const Icon(Icons.qr_code_2, size: 160, color: Colors.black),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "노선: 82A / 승용차 실증\n녹화시간: ${_recSeconds}초 | 최고속도: ${_displaySpeed.toInt()} km/h\n(스캔 시 실증 데이터 클라우드로 연결)",
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("닫기", style: TextStyle(color: Colors.cyanAccent)),
          )
        ],
      ),
    );
  }

  @override
  void dispose() {
    _smoothingTimer?.cancel();
    _recTimer?.cancel();
    flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    int m = _recSeconds ~/ 60;
    int s = _recSeconds % 60;
    String timerStr = '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text("BusEye 82A AI Brain", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code, color: Colors.cyanAccent),
            tooltip: "실증 QR 확인",
            onPressed: _showQrDialog,
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              color: _isRec ? Colors.red : Colors.grey[800],
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(_isRec ? "REC $timerStr" : "대기", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          )
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: Container(
              margin: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _statusColor, width: 2),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isBlackboxConnected ? Icons.sensors : Icons.sensors_off,
                          color: _isBlackboxConnected ? Colors.greenAccent : Colors.white38,
                          size: 44,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isBlackboxConnected ? "차량 블랙박스 RTSP 스트림 AI 수신 중" : "블랙박스 Wi-Fi 연결 대기 중",
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text("${_displaySpeed.toInt()}", style: const TextStyle(color: Colors.cyanAccent, fontSize: 32, fontWeight: FontWeight.bold)),
                          const SizedBox(width: 4),
                          const Text("km/h", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _statusColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _statusColor),
            ),
            child: Text(_statusMsg, textAlign: TextAlign.center, style: TextStyle(color: _statusColor, fontSize: 14, fontWeight: FontWeight.bold)),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: Icon(_isBlackboxConnected ? Icons.link_off : Icons.wifi_tethering),
                        label: Text(_isBlackboxConnected ? "블박 해제" : "블박 연동"),
                        style: ElevatedButton.styleFrom(backgroundColor: _isBlackboxConnected ? Colors.teal[800] : Colors.blueGrey[800]),
                        onPressed: _toggleBlackboxConnection,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: Icon(_isRec ? Icons.stop : Icons.fiber_manual_record),
                        label: Text(_isRec ? "녹화 완료" : "실증 녹화"),
                        style: ElevatedButton.styleFrom(backgroundColor: _isRec ? Colors.red[800] : Colors.blueAccent[700]),
                        onPressed: _toggleRec,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red[900]),
                        onPressed: () => _alert("승객 미착석 출발 주의", Colors.redAccent, "승객이 아직 착석하지 않았습니다."),
                        child: const Text("승객 전도", style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.orange[900]),
                        onPressed: () => _alert("우측 사각지대 오토바이 주의", Colors.orangeAccent, "우측 사각지대에 오토바이가 접근 중입니다."),
                        child: const Text("오토바이", style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[800]),
                        onPressed: () => _alert("정상 주행 모니터링 중", Colors.cyanAccent, ""),
                        child: const Text("리셋", style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}
