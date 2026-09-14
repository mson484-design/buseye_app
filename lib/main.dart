import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';

void main() {
  runApp(const BusEyeApp());
}

class BusEyeApp extends StatelessWidget {
  const BusEyeApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BusEye Safety System',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const SafetyMonitorScreen(),
    );
  }
}

class SafetyMonitorScreen extends StatefulWidget {
  const SafetyMonitorScreen({Key? key}) : super(key: key);

  @override
  State<SafetyMonitorScreen> createState() => _SafetyMonitorScreenState();
}

class _SafetyMonitorScreenState extends State<SafetyMonitorScreen> {
  final FlutterTts _flutterTts = FlutterTts();

  double _accelX = 0, _accelY = 0, _accelZ = 0;
  double _currentSpeed = 0.0;
  double _heading = 0.0;

  List<Map<String, dynamic>> _detectedObjects = [];

  String _currentAlertLevel = '안전';
  Color _statusColor = Colors.green;
  DateTime? _lastSpokenTime;

  StreamSubscription? _accelSubscription;
  StreamSubscription? _positionSubscription;

  @override
  void initState() {
    super.initState();
    _initTts();
    _initSensors();
    _startSimulationTimer();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("ko-KR");
    await _flutterTts.setSpeechRate(1.0);
  }

  void _initSensors() {
    _accelSubscription = accelerometerEvents.listen((AccelerometerEvent event) {
      setState(() {
        _accelX = event.x;
        _accelY = event.y;
        _accelZ = event.z;
      });
    });

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationSettingsAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen((Position position) {
      setState(() {
        _currentSpeed = position.speed * 3.6;
        if (position.heading != 0) {
          _heading = position.heading;
        }
      });
    });
  }

  void _startSimulationTimer() {
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) return;
      List<Map<String, dynamic>> simulatedObjects = [
        {'id': 1, 'distance': 8.5, 'angle': 5.0, 'isOpposing': false, 'speed': 45.0, 'name': '전방 차량'},
        {'id': 2, 'distance': 3.2, 'angle': -45.0, 'isOpposing': false, 'speed': 10.0, 'name': '사각지대 측면 보행자'},
        {'id': 3, 'distance': 12.0, 'angle': 160.0, 'isOpposing': true, 'speed': 60.0, 'name': '반대차선 정상 주행 차량'},
        {'id': 4, 'distance': 6.0, 'angle': -170.0, 'isOpposing': true, 'speed': 75.0, 'name': '반대차선 중앙선 침범 차량'},
      ];

      _processSensorFusion(simulatedObjects);
    });
  }

  void _processSensorFusion(List<Map<String, dynamic>> objects) {
    String highestAlert = '안전';
    Color alertColor = Colors.green;
    String alertMessage = '';

    for (var obj in objects) {
      double distance = obj['distance'];
      double angle = obj['angle'];
      bool isOpposing = obj['isOpposing'];

      bool isBlindSpot = (angle.abs() > 30 && angle.abs() < 120) && distance < 5.0;
      bool isWideArea = distance <= 15.0;

      if (!isWideArea && !isBlindSpot) continue;

      if (isOpposing) {
        bool isDangerousOpposing = (angle.abs() > 140 && distance < 8.0);
        if (!isDangerousOpposing) {
          continue;
        } else {
          highestAlert = '위험 (반대방향 충돌 임박)';
          alertColor = Colors.red;
          alertMessage = '반대차선 위험 접근! 주의하세요!';
          break;
        }
      }

      if (distance < 4.0 || isBlindSpot) {
        highestAlert = '3단계 경고: 심각 위험';
        alertColor = Colors.red;
        alertMessage = '충돌 위험! 즉시 브레이크!';
        break;
      } else if (distance < 8.0) {
        if (highestAlert != '3단계 경고: 심각 위험') {
          highestAlert = '2단계 경고: 주의';
          alertColor = Colors.orange;
          alertMessage = '측후방 사각 및 전방 주의';
        }
      } else if (distance < 15.0) {
        if (highestAlert == '안전') {
          highestAlert = '1단계 경고: 인지';
          alertColor = Colors.amber;
          alertMessage = '주변 객체 접근 중';
        }
      }
    }

    setState(() {
      _detectedObjects = objects;
      _currentAlertLevel = highestAlert;
      _statusColor = alertColor;
    });

    if (alertMessage.isNotEmpty) {
      _speakAlert(alertMessage);
    }
  }

  void _speakAlert(String message) async {
    final now = DateTime.now();
    if (_lastSpokenTime == null || now.difference(_lastSpokenTime!).inSeconds > 2) {
      _lastSpokenTime = now;
      await _flutterTts.speak(message);
    }
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    _positionSubscription?.cancel();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BusEye 센서 융합 관제 시스템'),
        backgroundColor: _statusColor,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _statusColor.withOpacity(0.2),
                border: Border.all(color: _statusColor, width: 3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const Text('현재 통합 위험 단계', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  Text(
                    _currentAlertLevel,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _statusColor),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text('차량 속도: ${_currentSpeed.toStringAsFixed(1)} km/h', style: const TextStyle(fontSize: 16)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text('탐지된 주변 객체 리스트', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: _detectedObjects.length,
                itemBuilder: (context, index) {
                  final obj = _detectedObjects[index];
                  bool isOpposing = obj['isOpposing'];
                  double distance = obj['distance'];
                  double angle = obj['angle'];

                  String statusText = '정상 추적';
                  Color textColor = Colors.black;

                  if (isOpposing && angle.abs() <= 140) {
                    statusText = '반대방향 정상 (무시됨)';
                    textColor = Colors.grey;
                  } else if (distance < 5.0) {
                    statusText = '위험 영역 (경고 대상)';
                    textColor = Colors.red;
                  }

                  return Card(
                    child: ListTile(
                      leading: Icon(
                        isOpposing ? Icons.compare_arrows : Icons.radar,
                        color: textColor,
                      ),
                      title: Text(obj['name'], style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
                      subtitle: Text('거리: ${distance}m | 각도: ${angle}° | 속도: ${obj['speed']}km/h'),
                      trailing: Text(statusText, style: TextStyle(color: textColor, fontSize: 12)),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
