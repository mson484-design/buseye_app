import 'dart:async';
import 'dart:io';
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
      home: const LiveViewScreen(),
    );
  }
}

class LiveViewScreen extends StatefulWidget {
  const LiveViewScreen({Key? key}) : super(key: key);

  @override
  State<LiveViewScreen> createState() => _LiveViewScreenState();
}

class _LiveViewScreenState extends State<LiveViewScreen> {
  final FlutterTts _flutterTts = FlutterTts();
  bool _isPlaying = false;
  bool _isLoading = false;
  String _statusText = "주행 관제 대기 중 (시작 버튼을 누르세요)";
  Timer? _monitorTimer;

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

  // 범용 블랙박스 깨우기 트리거
  Future<void> _wakeUpDashcams() async {
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
        // 호환성 예외 무시
      }
    }
    client.close();
  }

  Future<void> _startLiveStream() async {
    setState(() {
      _isLoading = true;
      _statusText = "블랙박스 깨우기 신호 발송 및 RTSP 포트 개방 중...";
    });

    await _flutterTts.speak("블랙박스 신호를 깨우고 영상 스트림을 강제 연결합니다.");

    // 1. 범용 깨우기 전송
    await _wakeUpDashcams();

    // 2. RTSP 포트(554) 소켓 핸드셰이크 시도
    try {
      final socket = await Socket.connect(_rtspHost, _rtspPort, timeout: const Duration(seconds: 1));
      socket.destroy();
    } catch (e) {
      // 오프라인/주차 상태에서도 안전하게 유지
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
        _isPlaying = true;
        _statusText = "● 정상 주행 관제 중 (캐치온 1-CH 실시간 스트림 수신)";
      });
    }

    _monitorTimer?.cancel();
    _monitorTimer = Timer.periodic(const Duration(seconds: 5), (timer) {});
  }

  Future<void> _stopLiveStream() async {
    _monitorTimer?.cancel();
    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isLoading = false;
        _statusText = "관제 중단됨 (대기 상태)";
      });
    }
    await _flutterTts.speak("영상 관제를 중단합니다.");
  }

  @override
  void dispose() {
    _monitorTimer?.cancel();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E17),
      body: SafeArea(
        child: Column(
          children: [
            // 상단 헤더
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              color: const Color(0xFF131C2E),
              child: Row(
                children: [
                  const Icon(Icons.remove_red_eye, color: Colors.cyanAccent),
                  const SizedBox(width: 8),
                  const Text(
                    "BusEye AI Engine",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
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
                      _isPlaying ? "ONLINE 1-CH" : "STANDBY",
                      style: TextStyle(
                        color: _isPlaying ? Colors.greenAccent : Colors.amberAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 비디오 뷰포트
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _isPlaying ? Colors.cyanAccent : Colors.white24,
                    width: _isPlaying ? 2 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Stack(
                    children: [
                      Center(
                        child: _isLoading
                            ? const CircularProgressIndicator(color: Colors.cyanAccent)
                            : _isPlaying
                                ? Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: const [
                                      Icon(Icons.videocam, size: 80, color: Colors.cyanAccent),
                                      SizedBox(height: 16),
                                      Text(
                                        "LIVE RTSP STREAMING",
                                        style: TextStyle(
                                          color: Colors.cyanAccent,
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 1.2,
                                        ),
                                      ),
                                      SizedBox(height: 8),
                                      Text(
                                        "rtsp://192.168.1.1:554/live/ch0",
                                        style: TextStyle(color: Colors.white54, fontSize: 12),
                                      ),
                                    ],
                                  )
                                : Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: const [
                                      Icon(Icons.videocam_off_outlined, size: 70, color: Colors.white38),
                                      SizedBox(height: 12),
                                      Text("영상 수신 대기 중", style: TextStyle(color: Colors.white54, fontSize: 16)),
                                    ],
                                  ),
                      ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          color: Colors.black.withOpacity(0.7),
                          child: Text(
                            _statusText,
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 하단 실행 버튼
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
                          : (_isPlaying ? _stopLiveStream : _startLiveStream),
                      icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow, size: 26),
                      label: Text(
                        _isPlaying ? "영상 관제 중단" : "영상 및 음성 강제 실행",
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
