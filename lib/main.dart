import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:video_player/video_player.dart';

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
  VideoPlayerController? _controller;
  bool _isPlaying = false;
  bool _isLoading = false;
  String _statusText = "주행 관제 대기 중 (시작 버튼을 누르세요)";

  final String _rtspUrl = "rtsp://192.168.1.1:554/live/ch0";

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("ko-KR");
    await _flutterTts.setSpeechRate(0.5);
  }

  // 🌟 핵심: 범용 블랙박스 깨우기 로직 (Fail-Safe)
  Future<void> _wakeUpDashcams() async {
    final endpoints = [
      "http://192.168.1.1/?custom=1&cmd=2001&par=1", // Novatek/CatchOn 계열
      "http://192.168.1.254/?custom=1&cmd=2001&par=1", // 일반 범용 1
      "http://192.168.1.1/cgi-bin/Config.cgi?action=set&property=Video&value=record" // 일반 범용 2
    ];
    
    final client = HttpClient();
    client.connectionTimeout = const Duration(milliseconds: 500); // 0.5초 대기 후 즉시 패스

    for (var url in endpoints) {
      try {
        final request = await client.getUrl(Uri.parse(url));
        await request.close(); // 요청만 쏘고 응답 내용은 무시 (단방향 트리거)
      } catch (e) {
        // 통신 실패해도 앱이 터지지 않고 조용히 패스 (호환성 유지)
      }
    }
    client.close();
  }

  Future<void> _startLiveStream() async {
    setState(() {
      _isLoading = true;
      _statusText = "블랙박스 잠금 해제 및 영상 연결 중...";
    });

    await _flutterTts.speak("블랙박스 신호를 깨우고 영상을 강제 연결합니다.");

    // 1. 범용 깨우기 신호 발송
    await _wakeUpDashcams();
    
    // 2. 비디오 렌더러 연결
    try {
      _controller = VideoPlayerController.networkUrl(Uri.parse(_rtspUrl));
      await _controller!.initialize();
      await _controller!.play();

      if (mounted) {
        setState(() {
          _isLoading = false;
          _isPlaying = true;
          _statusText = "● 정상 주행 관제 중 (실시간 영상 수신)";
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isPlaying = true;
          _statusText = "● 영상 수신 대기 (렌더링 보류)";
        });
      }
    }
  }

  Future<void> _stopLiveStream() async {
    if (_controller != null) {
      await _controller!.pause();
      await _controller!.dispose();
      _controller = null;
    }
    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isLoading = false;
        _statusText = "관제 중단됨 (대기 상태)";
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E17),
      body: SafeArea(
        child: Column(
          children: [
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
                            : (_isPlaying && _controller != null && _controller!.value.isInitialized)
                                ? AspectRatio(
                                    aspectRatio: _controller!.value.aspectRatio,
                                    child: VideoPlayer(_controller!),
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
