import 'dart:async';
import 'dart:io';
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

class BusEyeMainScreen extends StatefulWidget {
  const BusEyeMainScreen({Key? key}) : super(key: key);

  @override
  State<BusEyeMainScreen> createState() => _BusEyeMainScreenState();
}

class _BusEyeMainScreenState extends State<BusEyeMainScreen> {
  final FlutterTts _flutterTts = FlutterTts();
  bool _isPlaying = false;
  bool _isLoading = false;
  String _statusText = "Wi-Fi 서칭 완료: 관제 시작 버튼을 누르세요.";
  String _activeProtocol = "탐색 대기";
  String _networkStatusText = "Wi-Fi 네트워크 스캔 중...";
  int _receivedFrameCount = 0;

  Timer? _scannerTimer;
  Timer? _wifiScanTimer;
  Uint8List? _latestFrameBytes;

  final List<Map<String, String>> _streamCandidates = [
    {"name": "Novatek RTSP/HTTP (8080)", "url": "http://192.168.1.1:8080/?action=snapshot"},
    {"name": "Novatek Live JPG", "url": "http://192.168.1.1:8080/live/ch0.jpg"},
    {"name": "Allwinner CGI Snapshot", "url": "http://192.168.1.1/cgi-bin/snapshot.cgi"},
    {"name": "Generalplus Remote Cam", "url": "http://192.168.1.254/?custom=1&cmd=2003"},
    {"name": "Hisilicon Auto Snapshot", "url": "http://192.168.1.1/tmpfs/auto.jpg"},
    {"name": "Universal Port 80 Cam", "url": "http://192.168.1.1:80/snapshot.jpg"},
    {"name": "Sub Gateway (192.168.0.1)", "url": "http://192.168.0.1:8080/?action=snapshot"},
  ];
  int _candidateIndex = 0;

  @override
  void initState() {
    super.initState();
    _initTts();
    _startWifiNetworkSurfing();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("ko-KR");
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
  }

  // 실시간 Wi-Fi 네트워크 환경 및 게이트웨이 서칭
  void _startWifiNetworkSurfing() {
    _wifiScanTimer?.cancel();
    _wifiScanTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        // 네트워크 인터페이스를 통한 주변 IP 바인딩 검사
        final interfaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
        if (interfaces.isNotEmpty) {
          for (var interface in interfaces) {
            for (var addr in interface.addresses) {
              if (addr.address.startsWith("192.168.")) {
                if (mounted) {
                  setState(() {
                    _networkStatusText = "Wi-Fi 연결됨 (${interface.name}) | IP: ${addr.address}";
                  });
                }
                return;
              }
            }
          }
        }
        if (mounted) {
          setState(() {
            _networkStatusText = "⚠️ 블랙박스 Wi-Fi 미접속 상태 (휴대폰 설정 확인 필요)";
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _networkStatusText = "Wi-Fi 서칭 오류 발생";
          });
        }
      }
    });
  }

  Future<void> _sendUniversalWakeUp() async {
    final wakeUrls = [
      "http://192.168.1.1/?custom=1&cmd=2001&par=1",
      "http://192.168.1.1/?custom=1&cmd=1001",
      "http://192.168.1.254/?custom=1&cmd=2001&par=1",
      "http://192.168.1.1/cgi-bin/Config.cgi?action=set&property=Video&value=record",
      "http://192.168.0.1/?custom=1&cmd=2001"
    ];

    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 300);
    for (var url in wakeUrls) {
      try {
        final req = await client.getUrl(Uri.parse(url));
        await req.close();
      } catch (e) {}
    }
    client.close();
  }

  Future<void> _startSystem() async {
    setState(() {
      _isLoading = true;
      _receivedFrameCount = 0;
      _latestFrameBytes = null;
      _statusText = "실차 블랙박스 신호 프로빙 및 Wake-up 패킷 송출 중...";
    });

    await _flutterTts.speak("실차 블랙박스 영상 수신을 시작합니다.");
    await _sendUniversalWakeUp();

    _startRealStreamScanner();

    if (mounted) {
      setState(() {
        _isLoading = false;
        _isPlaying = true;
      });
    }
  }

  void _startRealStreamScanner() {
    _scannerTimer?.cancel();
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 350);

    _scannerTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) async {
      if (!_isPlaying) return;

      final candidate = _streamCandidates[_candidateIndex];
      try {
        final request = await client.getUrl(Uri.parse(candidate["url"]!));
        final response = await request.close();

        if (response.statusCode == 200) {
          final bytes = await _extractBytes(response);
          if (mounted && bytes.isNotEmpty) {
            setState(() {
              _latestFrameBytes = bytes;
              _receivedFrameCount++;
              _activeProtocol = candidate["name"]!;
              _statusText = "● [영상 수신 성공] 실시간 스트림 동기화 완료 (수신 프레임: $_receivedFrameCount)";
            });
          }
        } else {
          _nextEndpoint();
        }
      } catch (e) {
        _nextEndpoint();
      }
    });
  }

  void _nextEndpoint() {
    _candidateIndex = (_candidateIndex + 1) % _streamCandidates.length;
    if (_latestFrameBytes == null && mounted) {
      setState(() {
        _activeProtocol = _streamCandidates[_candidateIndex]["name"]!;
        _statusText = "신호 탐색 중: [${_streamCandidates[_candidateIndex]["name"]}] 응답 확인...";
      });
    }
  }

  Future<Uint8List> _extractBytes(HttpClientResponse response) {
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

  Future<void> _stopSystem() async {
    _scannerTimer?.cancel();

    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isLoading = false;
        _latestFrameBytes = null;
        _activeProtocol = "연결 중단됨";
        _statusText = "관제 중단됨 (대기 상태)";
      });
    }
    await _flutterTts.speak("수신을 중단합니다.");
  }

  @override
  void dispose() {
    _scannerTimer?.cancel();
    _wifiScanTimer?.cancel();
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
            // 상단 하드웨어 및 Wi-Fi 서칭 상태 헤더
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              color: const Color(0xFF0F172A),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.wifi_tethering,
                        color: _latestFrameBytes != null ? Colors.greenAccent : Colors.amberAccent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "BusEye Real-Hardware Validator",
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _latestFrameBytes != null ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _latestFrameBytes != null ? Colors.greenAccent : Colors.redAccent,
                          ),
                        ),
                        child: Text(
                          _latestFrameBytes != null ? "STREAM LIVE" : "NO SIGNAL",
                          style: TextStyle(
                            color: _latestFrameBytes != null ? Colors.greenAccent : Colors.redAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _networkStatusText,
                    style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
                  ),
                ],
              ),
            ),

            // 메인 뷰포트
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _latestFrameBytes != null ? Colors.greenAccent : Colors.white24,
                    width: 1.5,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_isPlaying && _latestFrameBytes != null)
                        Image.memory(
                          _latestFrameBytes!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        )
                      else if (_isPlaying && _latestFrameBytes == null)
                        Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const CircularProgressIndicator(color: Colors.cyanAccent),
                              const SizedBox(height: 16),
                              const Text(
                                "블랙박스 비디오 패킷 수신 대기 중...",
                                style: TextStyle(color: Colors.white70, fontSize: 14),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                "시도 중: $_activeProtocol",
                                style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                              ),
                            ],
                          ),
                        )
                      else
                        Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Icon(Icons.videocam_off_outlined, size: 56, color: Colors.white30),
                              SizedBox(height: 12),
                              Text("블랙박스 Wi-Fi 연결 상태를 확인 후 시작하세요", style: TextStyle(color: Colors.white54, fontSize: 14)),
                            ],
                          ),
                        ),

                      // 하단 상태바
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                          color: Colors.black.withOpacity(0.85),
                          child: Text(
                            _statusText,
                            style: TextStyle(
                              color: _latestFrameBytes != null ? Colors.greenAccent : Colors.amberAccent,
                              fontSize: 11,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 하단 조작 컨트롤러
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
                        _isPlaying ? "수신 중단" : "실차 블랙박스 수신 시작",
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
