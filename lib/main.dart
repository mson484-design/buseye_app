import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';

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
  VlcPlayerController? _vlcViewController;
  bool _isPlaying = false;
  String _statusText = "주행 관제 대기 중 (시작 버튼을 누르세요)";

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

  void _startLiveStream() {
    setState(() {
      _statusText = "블랙박스 영상 신호 수신 및 디코딩 중...";
    });

    _speak("캐치온 블랙박스 영상 스트림을 강제 연결합니다. 정상 작동 중입니다.");

    // VLC 저지연 스트리밍 설정 주입
    _vlcViewController = VlcPlayerController.network(
      _rtspUrl,
      hwAcc: HwAcc.full,
      autoPlay: true,
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([
          '--rtsp-tcp',
          '--network-caching=150',
          '--clock-jitter=0',
        ]),
        rtp: VlcRtpOptions([
          '--rtsp-tcp',
        ]),
      ),
    );

    setState(() {
      _isPlaying = true;
      _statusText = "● 정상 주행 관제 중 (캐치온 1-CH 실시간 영상)";
    });
  }

  void _stopLiveStream() async {
    if (_vlcViewController != null) {
      await _vlcViewController!.stop();
      await _vlcViewController!.dispose();
      _vlcViewController = null;
    }
    setState(() {
      _isPlaying = false;
      _statusText = "관제 중단됨 (대기 상태)";
    });
    _speak("영상 관제를 일시 중단합니다.");
  }

  @override
  void dispose() {
    _vlcViewController?.dispose();
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

            // 비디오 렌더러 화면
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black,
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
                        child: _isPlaying && _vlcViewController != null
                            ? VlcPlayer(
                                controller: _vlcViewController!,
                                aspectRatio: 16 / 9,
                                placeholder: const Center(
                                  child: CircularProgressIndicator(color: Colors.cyanAccent),
                                ),
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

            // 하단 조작 패널
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
                      onPressed: _isPlaying ? _stopLiveStream : _startLiveStream,
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
