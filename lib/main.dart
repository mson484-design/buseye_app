import 'dart:async';
import 'package:flutter/material.dart';

void main() {
  runApp(const BusEye82AApp());
}

class BusEye82AApp extends StatelessWidget {
  const BusEye82AApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BusEye 82A',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        primaryColor: const Color(0xFF0284C7),
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
  int _speed = 0;
  bool _isMuted = false;
  String _alertMessage = "정상 주행 중 (안전거리 확보)";
  Color _alertColor = Colors.greenAccent;
  Timer? _simTimer;

  @override
  void initState() {
    super.initState();
    _startSpeedSimulation();
  }

  void _startSpeedSimulation() {
    _simTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted) return;
      setState(() {
        _speed = (_speed + 5) % 50;
        if (_speed >= 40) {
          _alertMessage = "과속 경고: 구간 제한속도 준수 요망";
          _alertColor = Colors.redAccent;
        } else if (_speed >= 25) {
          _alertMessage = "우측 사각지대 이륜차 주의";
          _alertColor = Colors.amberAccent;
        } else {
          _alertMessage = "정상 주행 중 (82A 안전 운행)";
          _alertColor = Colors.greenAccent;
        }
      });
    });
  }

  @override
  void dispose() {
    _simTimer?.cancel();
    super.dispose();
  }

  void _triggerAnnouncement(String title, String message, Color color) {
    setState(() {
      _alertMessage = "[$title] $message";
      _alertColor = color;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blueGrey.shade700),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          "BusEye 82A",
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.lightBlueAccent),
                        ),
                        Text(
                          "노선: 82A (실차 모니터링)",
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: _alertColor),
                          ),
                          child: Row(
                            children: [
                              Text(
                                "$_speed",
                                style: TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w900,
                                  color: _alertColor,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Text("km/h", style: TextStyle(fontSize: 12, color: Colors.white70)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          icon: Icon(_isMuted ? Icons.volume_off : Icons.volume_up),
                          color: _isMuted ? Colors.red : Colors.white,
                          onPressed: () {
                            setState(() {
                              _isMuted = !_isMuted;
                            });
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.blueAccent.withOpacity(0.5)),
                        ),
                        child: Stack(
                          children: [
                            const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.videocam_outlined, size: 40, color: Colors.white38),
                                  SizedBox(height: 6),
                                  Text("CAM 1: 전방 추돌 감지", style: TextStyle(color: Colors.white60, fontSize: 12)),
                                ],
                              ),
                            ),
                            Positioned(
                              top: 8,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                color: Colors.red.withOpacity(0.8),
                                child: const Text("LIVE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.blueAccent.withOpacity(0.5)),
                        ),
                        child: Stack(
                          children: [
                            const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.person_pin_outlined, size: 40, color: Colors.white38),
                                  SizedBox(height: 6),
                                  Text("CAM 2: 승객 전도 감지", style: TextStyle(color: Colors.white60, fontSize: 12)),
                                ],
                              ),
                            ),
                            Positioned(
                              top: 8,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                color: Colors.green.withOpacity(0.8),
                                child: const Text("AI ON", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                decoration: BoxDecoration(
                  color: _alertColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _alertColor),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: _alertColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _alertMessage,
                        style: TextStyle(color: _alertColor, fontWeight: FontWeight.bold, fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE11D48),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.record_voice_over, color: Colors.white),
                      label: const Text("승객 전도 방지", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      onPressed: () {
                        _triggerAnnouncement("승객 안내", "손잡이를 꼭 잡아주시기 바랍니다.", Colors.orangeAccent);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD97706),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.two_wheeler, color: Colors.white),
                      label: const Text("우측 오토바이", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      onPressed: () {
                        _triggerAnnouncement("측방 경고", "우측 사각지대에 이륜차가 접근 중입니다.", Colors.redAccent);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.check_circle_outline, color: Colors.white),
                      label: const Text("정상 리셋", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      onPressed: () {
                        _triggerAnnouncement("안내", "정상 주행 상태로 전환되었습니다.", Colors.greenAccent);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
