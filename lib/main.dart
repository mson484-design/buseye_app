import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BusEyeApp());
}

class BusEyeApp extends StatelessWidget {
  const BusEyeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BusEye 82A',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B1120),
      ),
      home: const BusEyeScreen(),
    );
  }
}

class BusEyeScreen extends StatefulWidget {
  const BusEyeScreen({super.key});

  @override
  State<BusEyeScreen> createState() => _BusEyeScreenState();
}

class _BusEyeScreenState extends State<BusEyeScreen> {
  final FlutterTts flutterTts = FlutterTts();
  double _speed = 0.0;
  bool _isRec = false;
  String _status = "정상 주행 모니터링 중";
  Color _statusColor = Colors.greenAccent;
  int _recTime = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _initTts();
    _initGps();
  }

  void _initTts() async {
    await flutterTts.setLanguage("ko-KR");
    await flutterTts.setSpeechRate(0.5);
  }

  Future<void> _initGps() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
    // 1km/h 단위 실시간 정밀 갱신 (거리 필터 0m, 고정밀 수신)
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen((pos) {
      setState(() {
        _speed = (pos.speed > 0) ? (pos.speed * 3.6) : 0.0;
      });
    });
  }

  void _toggleRec() {
    setState(() {
      _isRec = !_isRec;
      if (_isRec) {
        _recTime = 0;
        _timer = Timer.periodic(const Duration(seconds: 1), (t) {
          setState(() => _recTime++);
        });
        flutterTts.speak("실차 주행 실증 녹화를 시작합니다.");
      } else {
        _timer?.cancel();
        flutterTts.speak("주행 영상이 저장되었습니다.");
      }
    });
  }

  void _alert(String msg, Color color, String voice) {
    setState(() {
      _status = msg;
      _statusColor = color;
    });
    if (voice.isNotEmpty) {
      flutterTts.speak(voice);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    int m = _recTime ~/ 60;
    int s = _recTime % 60;
    String timerStr = '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text("BusEye 82A 실차 안전 시스템", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            decoration: BoxDecoration(
              color: _isRec ? Colors.red : Colors.grey[800],
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                Icon(Icons.fiber_manual_record, color: _isRec ? Colors.white : Colors.white54, size: 12),
                const SizedBox(width: 4),
                Text(_isRec ? "REC $timerStr" : "대기", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
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
                      children: const [
                        Icon(Icons.videocam, color: Colors.cyanAccent, size: 40),
                        SizedBox(height: 6),
                        Text("블랙박스 / 주행 화면 실시간 AI 감시", style: TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      color: Colors.black54,
                      child: Text("${_speed.toStringAsFixed(0)} km/h", style: const TextStyle(color: Colors.cyanAccent, fontSize: 22, fontWeight: FontWeight.bold)),
                    ),
                  )
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
            child: Text(_status, textAlign: TextAlign.center, style: TextStyle(color: _statusColor, fontSize: 15, fontWeight: FontWeight.bold)),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: ElevatedButton.icon(
                    icon: Icon(_isRec ? Icons.stop : Icons.play_arrow),
                    label: Text(_isRec ? "실증 영상 녹화 종료 (저장)" : "실증 영상 녹화 시작", style: const TextStyle(fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(backgroundColor: _isRec ? Colors.red[800] : Colors.blueAccent[700]),
                    onPressed: _toggleRec,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red[900]),
                        onPressed: () => _alert("승객 미착석 출발 주의", Colors.redAccent, "승객이 아직 착석하지 않았습니다. 천천히 출발하세요."),
                        child: const Text("승객 전도", style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.orange[900]),
                        onPressed: () => _alert("우측 사각지대 오토바이 감지", Colors.orangeAccent, "우측 사각지대에 오토바이가 접근 중입니다."),
                        child: const Text("오토바이", style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[800]),
                        onPressed: () => _alert("정상 주행 모니터링 중", Colors.greenAccent, ""),
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
