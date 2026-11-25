import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ble.dart';
import 'live.dart';
import 'pages.dart';
import 'tracker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GSM020 Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF3FA7FF),
        scaffoldBackgroundColor: const Color(0xFF0F1216),
      ),
      home: const HomePage(),
    );
  }
}

const _stops = [Color(0xFF2ECC71), Color(0xFFF1C40F), Color(0xFFE67E22), Color(0xFFE74C3C)];
Color speedColor(double v, double max) {
  final r = max > 0 ? (v / max).clamp(0.0, 1.0) : 0.0;
  final x = r * (_stops.length - 1);
  final i = math.min(_stops.length - 2, x.floor());
  return Color.lerp(_stops[i], _stops[i + 1], x - i)!;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final tracker = Tracker();
  late final Link link = Link(tracker);
  late final LiveShare live = LiveShare(tracker);
  final mapCtl = MapController();
  bool mapReady = false, follow = true;
  StreamSubscription<Position>? _gpsSub;
  TrackPoint? selected;

  @override
  void initState() {
    super.initState();
    tracker.addListener(_onData);
    link.addListener(_onLink);
    live.load();
    live.addListener(() {
      if (mounted) setState(() {});
    });
  }

  void _onLink() {
    if (!mounted) return;
    (link.active || live.enabled) ? WakelockPlus.enable() : WakelockPlus.disable();
    setState(() {});
  }

  void _onData() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    link.stop();
    live.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  // ---------- phone GPS for the map ----------
  Future<void> _stopGps() async {
    await _gpsSub?.cancel();
    setState(() {
      _gpsSub = null;
      tracker.phonePos = null;
    });
  }

  Future<void> _startGps() async {
    if (_gpsSub != null || link.demo) return;
    if (!await Geolocator.isLocationServiceEnabled()) {
      _snack('เปิดตำแหน่ง (Location) ของมือถือก่อน จึงจะมีเส้นทางบนแผนที่');
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _snack('ไม่ได้รับสิทธิ์ใช้ตำแหน่ง');
      return;
    }
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0),
    ).listen((p) {
      tracker.onPhoneFix(LatLng(p.latitude, p.longitude), p.accuracy);
      if (follow && mapReady) mapCtl.move(tracker.phonePos!, math.max(mapCtl.camera.zoom, 17));
    });
    if (mounted) setState(() {});
  }

  Future<void> _toggleGps() => _gpsSub != null ? _stopGps() : _startGps();

  String _mapInfo() {
    final t = tracker;
    if (link.demo) return 'โหมดทดลอง: จำลอง GPS วิ่งรอบสนามวงรี';
    if (_gpsSub == null) return 'GPS มือถือปิดอยู่ กดปุ่มด้านขวาเพื่อเปิด (ต้องเปิดจึงจะมีเส้นทาง)';
    if (t.phoneAcc == null) return 'กำลังหาตำแหน่งมือถือ ...';
    final acc = t.phoneAcc!.round();
    if (t.phoneAcc! > Tracker.gpsMaxErr) return 'GPS มือถือคลาดเคลื่อน ±$acc m (ต้องไม่เกิน ${Tracker.gpsMaxErr.round()} m) ออกไปที่โล่ง';
    if (t.points.isEmpty) return 'GPS มือถือ ±$acc m พร้อมแล้ว รอ GSM020 จับสัญญาณ (ไฟเขียว)';
    if (!t.hasPositions) return 'GPS มือถือ ±$acc m กำลังเริ่มวาดเส้นทาง ...';
    return 'GPS มือถือ ±$acc m';
  }

  /// Speed numbers every ~25 m along the route, plus a top-speed tag.
  List<Marker> _speedLabels() {
    final out = <Marker>[];
    double lastD = -1e9;
    TrackPoint? best;
    for (final p in tracker.points) {
      if (p.pos == null) continue;
      if (best == null || p.speedKmh > best.speedKmh) best = p;
      if (p.distM - lastD < 25) continue;
      lastD = p.distM;
      out.add(Marker(
        point: p.pos!,
        width: 44,
        height: 22,
        alignment: Alignment.topCenter,
        child: _tag(p.speedKmh.toStringAsFixed(0), speedColor(p.speedKmh, tracker.maxSpeed), Colors.black87),
      ));
    }
    if (best != null) {
      out.add(Marker(
        point: best.pos!,
        width: 110,
        height: 24,
        alignment: Alignment.topCenter,
        child: _tag('สูงสุด ${best.speedKmh.toStringAsFixed(1)}', Colors.white, Colors.redAccent),
      ));
    }
    return out;
  }

  Widget _tag(String text, Color bg, Color border) => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(7), border: Border.all(color: border, width: 1.5)),
          child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: border == Colors.redAccent ? Colors.redAccent : Colors.black87)),
        ),
      );

  // ---------- map ----------
  List<Polyline> _polylines() {
    final pts = tracker.points.where((p) => p.pos != null).toList();
    if (pts.length < 2) return [];
    const buckets = 12;
    final max = tracker.maxSpeed <= 0 ? 1.0 : tracker.maxSpeed;
    int bucketOf(double v) => ((v / max).clamp(0.0, 1.0) * (buckets - 1)).round();
    final out = <Polyline>[];
    var run = <LatLng>[pts[0].pos!];
    var b = bucketOf(pts[1].speedKmh);
    for (var i = 1; i < pts.length; i++) {
      final bi = bucketOf(pts[i].speedKmh);
      if (pts[i].time.difference(pts[i - 1].time).inMilliseconds > 3000) {
        if (run.length > 1) out.add(Polyline(points: run, strokeWidth: 5, color: speedColor(b / (buckets - 1) * max, max)));
        run = [pts[i].pos!];
        b = bi;
        continue;
      }
      if (bi != b) {
        out.add(Polyline(points: run, strokeWidth: 5, color: speedColor(b / (buckets - 1) * max, max)));
        run = [pts[i - 1].pos!];
        b = bi;
      }
      run.add(pts[i].pos!);
    }
    out.add(Polyline(points: run, strokeWidth: 5, color: speedColor(b / (buckets - 1) * max, max)));
    return out;
  }

  void _onMapTap(LatLng at) {
    const d = Distance();
    TrackPoint? best;
    double bestD = double.infinity;
    for (final p in tracker.points) {
      if (p.pos == null) continue;
      final m = d(p.pos!, at);
      if (m < bestD) {
        bestD = m;
        best = p;
      }
    }
    final z = mapReady ? mapCtl.camera.zoom : 15;
    final mPerPx = 156543.03 * math.cos(at.latitude * math.pi / 180) / math.pow(2, z);
    setState(() => selected = (best != null && bestD <= mPerPx * 30) ? best : null);
  }

  // ---------- export ----------
  Future<void> _export(bool gpx) async {
    if (tracker.points.isEmpty) {
      _snack('ยังไม่มีข้อมูล');
      return;
    }
    if (gpx && !tracker.hasPositions) {
      _snack('ยังไม่มีพิกัด (ต้องเปิด GPS มือถือระหว่างวิ่ง)');
      return;
    }
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(RegExp(r'[:T]'), '-');
    final f = File('${dir.path}/gsm020_$stamp.${gpx ? 'gpx' : 'csv'}');
    await f.writeAsString(gpx ? tracker.toGpx() : tracker.toCsv());
    await Share.shareXFiles([XFile(f.path)], text: 'GSM020 run');
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  // ---------- UI ----------
  Widget _stat(String v, String l) => Expanded(
        child: Container(
          margin: const EdgeInsets.all(3),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(color: const Color(0xFF181D24), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(v, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold, fontFeatures: [FontFeature.tabularFigures()])),
            Text(l, style: const TextStyle(fontSize: 11, color: Colors.white60)),
          ]),
        ),
      );

  String _elapsed() {
    final s = tracker.startTime;
    final l = tracker.last;
    if (s == null || l == null) return '0:00';
    final sec = l.time.difference(s).inSeconds;
    return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = tracker;
    final last = t.last;
    final gpsOn = _gpsSub != null;
    final gnssText = !link.active ? 'ยังไม่ได้เชื่อมต่อ' : (t.gnssOk ? 'GNSS พร้อม' : (t.gnssHold ? 'สัญญาณหลุด' : 'รอสัญญาณ...'));
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Icon(Icons.circle, size: 12, color: link.active ? Colors.greenAccent : Colors.redAccent),
          const SizedBox(width: 8),
          const Text('GSM020 Tracker'),
          if (live.connected) ...[
            const SizedBox(width: 6),
            const Text('LIVE', style: TextStyle(fontSize: 11, color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ],
        ]),
        actions: [
          IconButton(
              icon: Icon(Icons.podcasts, color: live.connected ? Colors.greenAccent : null),
              tooltip: 'แชร์ลิงก์ดูสด',
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LiveSharePage(live: live)))),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'csv') _export(false);
              if (v == 'gpx') _export(true);
              if (v == 'clear') {
                t.clear();
                setState(() => selected = null);
              }
              if (v == 'demo') {
                _stopGps();
                final c = mapReady ? mapCtl.camera.center : const LatLng(13.7563, 100.5018);
                if (mapReady) mapCtl.move(c, 18);
                setState(() => follow = false);
                link.startDemo(c);
              }
              if (v == 'raw') Navigator.push(context, MaterialPageRoute(builder: (_) => RawPage(tracker: t)));
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('เริ่มรอบใหม่')),
              PopupMenuItem(value: 'csv', child: Text('ส่งออก CSV')),
              PopupMenuItem(value: 'gpx', child: Text('ส่งออก GPX')),
              PopupMenuItem(value: 'demo', child: Text('โหมดทดลอง')),
              PopupMenuItem(value: 'raw', child: Text('แพ็กเก็ตดิบ')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          // big speed + GNSS state
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text((last?.speedKmh ?? 0).toStringAsFixed(1),
                  style: const TextStyle(fontSize: 64, height: 1, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
              const Padding(padding: EdgeInsets.only(left: 6, bottom: 8), child: Text('km/h', style: TextStyle(color: Colors.white60))),
              const Spacer(),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(gnssText, style: TextStyle(fontWeight: FontWeight.bold, color: t.gnssOk ? Colors.greenAccent : Colors.amber)),
                Text('ดาวเทียม ${t.sats} ดวง', style: const TextStyle(fontSize: 12, color: Colors.white60)),
              ]),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(9, 6, 9, 0),
            child: Column(children: [
              Row(children: [
                _stat(t.maxSpeed.toStringAsFixed(1), 'สูงสุด km/h'),
                _stat(t.avgSpeed.toStringAsFixed(1), 'เฉลี่ย km/h'),
                _stat(((last?.accel ?? 0) / kG).toStringAsFixed(2), 'ความเร่ง g'),
              ]),
              Row(children: [
                _stat(t.distance.toStringAsFixed(0), 'ระยะทาง m'),
                _stat(_elapsed(), 'เวลา'),
                _stat(t.maxAccelG.toStringAsFixed(2), 'ความเร่งสูงสุด g'),
              ]),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Text(link.status, style: const TextStyle(fontSize: 12, color: Colors.amber), maxLines: 2),
          ),
          // speed chart
          Container(
            height: 140,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: const Color(0xFF181D24), borderRadius: BorderRadius.circular(12)),
            child: CustomPaint(painter: SpeedChart(t.points, t.maxSpeed), size: Size.infinite),
          ),
          // map
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 0),
            child: Row(children: [
              const Expanded(child: Text('แผนที่ (GPS มือถือ + ระยะจาก GSM020)', style: TextStyle(fontSize: 12, color: Colors.white60))),
              TextButton.icon(
                onPressed: _toggleGps,
                icon: Icon(gpsOn ? Icons.gps_fixed : Icons.gps_off, size: 18, color: gpsOn ? Colors.greenAccent : null),
                label: Text(gpsOn ? 'GPS มือถือ: เปิด' : 'GPS มือถือ: ปิด'),
              ),
            ]),
          ),
          if (_mapInfo().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
              child: Align(alignment: Alignment.centerLeft, child: Text(_mapInfo(), style: const TextStyle(fontSize: 12, color: Colors.amber))),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(children: [
                  FlutterMap(
                    mapController: mapCtl,
                    options: MapOptions(
                      initialCenter: const LatLng(13.7563, 100.5018),
                      initialZoom: 15,
                      onMapReady: () => mapReady = true,
                      onTap: (_, ll) => _onMapTap(ll),
                      onPositionChanged: (_, hasGesture) {
                        if (hasGesture && follow) setState(() => follow = false);
                      },
                    ),
                    children: [
                      TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.gsm020_tracker'),
                      PolylineLayer(polylines: _polylines()),
                      MarkerLayer(markers: _speedLabels()),
                      CircleLayer(circles: [
                        if (t.phonePos != null)
                          CircleMarker(point: t.phonePos!, radius: 7, color: Colors.white, borderColor: Colors.black, borderStrokeWidth: 2),
                        if (selected?.pos != null)
                          CircleMarker(point: selected!.pos!, radius: 9, color: speedColor(selected!.speedKmh, t.maxSpeed), borderColor: Colors.white, borderStrokeWidth: 3),
                      ]),
                    ],
                  ),
                  const Positioned(right: 6, bottom: 4, child: Text('© OpenStreetMap', style: TextStyle(fontSize: 9, color: Colors.black54))),
                  if (!follow)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: FloatingActionButton.small(
                        heroTag: 'follow',
                        onPressed: () {
                          setState(() => follow = true);
                          if (t.phonePos != null && mapReady) mapCtl.move(t.phonePos!, mapCtl.camera.zoom);
                        },
                        child: const Icon(Icons.my_location),
                      ),
                    ),
                  if (selected != null)
                    Positioned(
                      left: 8,
                      right: 8,
                      top: 8,
                      child: Card(
                        child: ListTile(
                          leading: Icon(Icons.speed, color: speedColor(selected!.speedKmh, t.maxSpeed), size: 32),
                          title: Text('${selected!.speedKmh.toStringAsFixed(1)} km/h', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                          subtitle: Text('ความเร่ง ${(selected!.accel / kG).toStringAsFixed(2)} g   ระยะ ${selected!.distM.toStringAsFixed(0)} m'),
                          trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => selected = null)),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('เชื่อมต่อ GSM020'),
                  onPressed: () {
                    _startGps();
                    Navigator.push(context, MaterialPageRoute(builder: (_) => ScanPage(link: link)));
                  },
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(icon: const Icon(Icons.stop), label: const Text('หยุด'), onPressed: link.stop),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Speed-over-time line, coloured by speed; shows the most recent ~5 minutes.
class SpeedChart extends CustomPainter {
  final List<TrackPoint> pts;
  final double maxSpeed;
  final int count;
  SpeedChart(this.pts, this.maxSpeed) : count = pts.length;

  @override
  void paint(Canvas c, Size s) {
    const l = 34.0, r = 8.0, tp = 10.0, b = 18.0;
    final top = math.max(10.0, (maxSpeed / 10).ceil() * 10.0);
    final grid = Paint()
      ..color = const Color(0xFF2A313B)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = tp + (s.height - tp - b) * i / 4;
      c.drawLine(Offset(l, y), Offset(s.width - r, y), grid);
      final tx = TextPainter(
        text: TextSpan(text: '${(top * (1 - i / 4)).round()}', style: const TextStyle(fontSize: 10, color: Colors.white54)),
        textDirection: TextDirection.ltr,
      )..layout();
      tx.paint(c, Offset(4, y - 6));
    }
    final view = pts.length > 1200 ? pts.sublist(pts.length - 1200) : pts;
    if (view.length < 2) return;
    final ta = view.first.time.millisecondsSinceEpoch;
    final span = math.max(1, view.last.time.millisecondsSinceEpoch - ta);
    double x(TrackPoint p) => l + (s.width - l - r) * (p.time.millisecondsSinceEpoch - ta) / span;
    double y(double v) => tp + (s.height - tp - b) * (1 - v / top);
    final line = Paint()
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < view.length; i++) {
      line.color = speedColor(view[i].speedKmh, maxSpeed);
      c.drawLine(Offset(x(view[i - 1]), y(view[i - 1].speedKmh)), Offset(x(view[i]), y(view[i].speedKmh)), line);
    }
    final lbl = TextPainter(
      text: TextSpan(text: '${(span / 1000).round()} วินาทีล่าสุด', style: const TextStyle(fontSize: 10, color: Colors.white54)),
      textDirection: TextDirection.ltr,
    )..layout();
    lbl.paint(c, Offset(s.width - r - lbl.width, s.height - 15));
  }

  @override
  bool shouldRepaint(SpeedChart old) => old.count != count || old.maxSpeed != maxSpeed;
}
