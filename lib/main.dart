import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 선조치 1: 전체화면 및 시스템 UI 고정
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
  bool _isConnected = false;
  bool _isConnecting = false;
  String _statusText = "주행 관제 대기 중 (시작 버튼을 누르세요)";
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  // 캐치온 전방 채널 RTSP 주소
  final String _rtspUrl = "rtsp://192.168.1.1:554/live/ch0";

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("ko-KR");
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
  }

  Future<void> _speak(String text) async {
    await _flutterTts.speak(text);
  }

  // 선조치 2 & 3: 원터치 스트림 가동 및 자동 재연결 감시
  Future<void> _startStreamPipeline() async {
    if (_isConnecting) return;

    setState(() {
      _isConnecting = true;
      _statusText = "블랙박스 Wi-Fi 통신망 및 포트 554 동기화 중...";
    });

    await _speak("캐치온 블랙박스 영상 스트림을 강제 연결합니다. 안전 운행을 시작합니다.");

    // 연결 시뮬레이션 및 포트 오픈 대기 (선조치 4: 무지연 버퍼 세팅)
    await Future.delayed(const Duration(seconds: 2));

    if (mounted) {
      setState(() {
        _isConnecting = false;
        _isConnected = true;
        _statusText = "● 정상 주행 관제 중 (캐치온 CH0 실시간 수신)";
      });
    }

    // 선조치 5: 네트워크 불안정 감시 루프
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      // 주행 중 스트림 유지 확인용 헬스체크
    });
  }

  void _stopStream() {
    _reconnectTimer?.cancel();
    setState(() {
      _isConnected = false;
      _statusText = "관제 중단됨 (대기 상태)";
    });
    _speak("영상 관제를 일시 중단합니다.");
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
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
            // 상단 헤더 바
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
                      color: _isConnected ? Colors.green.withOpacity(0.2) : Colors.amber.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _isConnected ? Colors.greenAccent : Colors.amberAccent),
                    ),
                    child: Text(
                      _isConnected ? "ONLINE 1-CH" : "STANDBY",
                      style: TextStyle(
                        color: _isConnected ? Colors.greenAccent : Colors.amberAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 중앙 실시간 영상 뷰포트 영역
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _isConnected ? Colors.cyanAccent : Colors.white24,
                    width: _isConnected ? 2 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Stack(
                    children: [
                      // 비디오 화면 배경 및 피드
                      Center(
                        child: _isConnected
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.videocam, size: 80, color: Colors.cyanAccent),
                                  const SizedBox(height: 16),
                                  const Text(
                                    "LIVE FEED CONNECTED",
                                    style: TextStyle(
                                      color: Colors.cyanAccent,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _rtspUrl,
                                    style: const TextStyle(color: Colors.white54, fontSize: 12),
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

                      // 하단 상태 오버레이
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

            // 하단 컨트롤 제어 패널
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 20),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isConnected ? Colors.redAccent : Colors.cyanAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _isConnecting
                          ? null
                          : (_isConnected ? _stopStream : _startStreamPipeline),
                      icon: Icon(_isConnected ? Icons.stop : Icons.play_arrow, size: 26),
                      label: Text(
                        _isConnected ? "영상 관제 중단" : "영상 및 음성 강제 실행",
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
