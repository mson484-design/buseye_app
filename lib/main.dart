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
  double _currentSpeed = 0.0;
  String _currentAlertLevel = '안전 (센서 모니터링 중)';
  Color _statusColor = Colors.green;

  StreamSubscription? _positionSubscription;
  StreamSubscription? _accelSubscription;

  @override
  void initState() {
    super.initState();
    _initTts();
    _initSensors();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("ko-KR");
  }

  void _initSensors() {
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationSettingsAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen((Position position) {
      setState(() {
        _currentSpeed = position.speed * 3.6;
      });
    });

    _accelSubscription = accelerometerEvents.listen((AccelerometerEvent event) {
      // 센서 융합 기반 충돌/급정거 감지 로직 자리
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _accelSubscription?.cancel();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BusEye 안전 관제 시스템'),
        backgroundColor: _statusColor,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _currentAlertLevel,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _statusColor),
            ),
            const SizedBox(height: 20),
            Text(
              '현재 속도: ${_currentSpeed.toStringAsFixed(1)} km/h',
              style: const TextStyle(fontSize: 20),
            ),
          ],
        ),
      ),
    );
  }
}
