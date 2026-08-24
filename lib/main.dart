import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const BusEyeApp());
}

class BusEyeApp extends StatelessWidget {
  const BusEyeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BusEye Commercial AI Edge Engine',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B1120),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // 네이티브 통신 채널
  static const platform = MethodChannel('com.buseye.safety/engine');

  bool isSystemRunning = false;
  String alertText = "정상 주행 모니터링 중";
  Color alertColor = Colors.cyanAccent;
  String alertSub = "블랙박스 사각지대 실시간 감시";

  @override
  void initState() {
    super.initState();
    _startNativeSafetyEngine();
  }

  // 백그라운드 엔진 구동 (네트워크 격리, 사각지대 AI, 오디오 제어 시작)
  Future<void> _startNativeSafetyEngine() async {
    try {
      await platform.invokeMethod('startSafetySystem', {
        'ssid': 'BUS_DASHCAM_WIFI',
      });
      setState(() {
        isSystemRunning = true;
      });
    } catch (e) {
      debugPrint("네이티브 엔진 가동 실패: $e");
    }
  }

  void _triggerAlert(String text, Color color, String sub) {
    setState(() {
      alertText = text;
      alertColor = color;
      alertSub = sub;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Row(
          children: [
            Icon(Icons.remove_red_eye, color: Colors.cyanAccent),
            SizedBox(width: 8),
            Text('BusEye AI Edge Engine', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isSystemRunning ? Colors.green[800] : Colors.grey[700],
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              isSystemRunning ? 'ENGINE ON' : 'CONNECTING',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
            ),
          )
        ],
      ),
      body: Column(
        children: [
          // 상단 경고 배너
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: alertColor.withOpacity(0.15),
            child: Column(
              children: [
                Text(
                  alertText,
                  style: TextStyle(color: alertColor, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                if (alertSub.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(alertSub, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ]
              ],
            ),
          ),

          // 4채널 사각지대 뷰 시뮬레이션 그리드
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                children: [
                  _buildCameraBox("CH1: 전방 도로", Icons.directions_bus, Colors.blue),
                  _buildCameraBox("CH2: 실내 승객석", Icons.people, Colors.green),
                  _buildCameraBox("CH3: 우측/하차문 사각지대", Icons.sensor_door, Colors.orange),
                  _buildCameraBox("CH4: 후방 및 사이드", Icons.camera_rear, Colors.purple),
                ],
              ),
            ),
          ),

          // 하단 시뮬레이션 및 테스트 버튼 바
          Container(
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red[800]),
                    onPressed: () => _triggerAlert("승객 미착석 상태 - 급출발 주의!", Colors.redAccent, "실내 승객 안전 사고 방지"),
                    child: const Text("미착석", style: TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orange[900]),
                    onPressed: () => _triggerAlert("우측 사각지대 오토바이 주의", Colors.orangeAccent, "우회전 보행자/이륜차 감지"),
                    child: const Text("오토바이", style: TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[800]),
                    onPressed: () => _triggerAlert("정상 주행 모니터링 중", Colors.cyanAccent, "블랙박스 사각지대 실시간 감시"),
                    child: const Text("리셋", style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraBox(String title, IconData icon, MaterialColor color) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        border: Border.all(color: color.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 6,
            left: 6,
            child: Text(title, style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ),
          Center(
            child: Icon(icon, size: 42, color: color.withOpacity(0.6)),
          ),
          const Positioned(
            bottom: 6,
            right: 6,
            child: Text("AI 감시중", style: TextStyle(fontSize: 10, color: Colors.greenAccent)),
          )
        ],
      ),
    );
  }
}
