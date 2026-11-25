import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tracker.dart';

/// Publishes the live run to a public MQTT broker so the web viewer
/// (viewer/index.html) can follow it from anywhere with the share link.
///
/// Topics:  gsm020tracker/<room>/live   one JSON sample, ~5 per second
///          gsm020tracker/<room>/track  retained snapshot for late joiners
class LiveShare extends ChangeNotifier {
  static const broker = 'broker.emqx.io';
  static const port = 8883; // MQTT over TLS (viewer uses wss://...:8084/mqtt)
  static const topicRoot = 'gsm020tracker';

  final Tracker tracker;
  LiveShare(this.tracker) {
    tracker.addListener(_onData);
  }

  bool enabled = false;
  String room = '';
  String viewerUrl = '';
  String status = 'ปิดอยู่';
  MqttServerClient? _c;
  DateTime _lastLive = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTrack = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastCount = 0;

  String get link => viewerUrl.isEmpty ? '' : '${viewerUrl.endsWith('/') ? viewerUrl : '$viewerUrl/'}#$room';
  bool get connected => _c?.connectionStatus?.state == MqttConnectionState.connected;

  static String newRoom() {
    const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = math.Random.secure();
    return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    room = p.getString('room') ?? newRoom();
    viewerUrl = p.getString('viewerUrl') ?? '';
    await p.setString('room', room);
    notifyListeners();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('room', room);
    await p.setString('viewerUrl', viewerUrl);
  }

  void _set(String s) {
    status = s;
    notifyListeners();
  }

  Future<void> start() async {
    if (enabled) return;
    enabled = true;
    _set('กำลังเชื่อมต่อเซิร์ฟเวอร์ ...');
    final id = 'gsm020-$room-${math.Random().nextInt(1 << 30)}';
    final c = MqttServerClient.withPort(broker, id, port)
      ..secure = true
      ..keepAlivePeriod = 30
      ..autoReconnect = true
      ..logging(on: false)
      ..onDisconnected = (() => _set(enabled ? 'หลุดจากเซิร์ฟเวอร์ กำลังต่อใหม่ ...' : 'ปิดอยู่'))
      ..onAutoReconnected = (() => _set('กำลังแชร์สด'))
      ..connectionMessage = MqttConnectMessage().withClientIdentifier(id).startClean();
    _c = c;
    try {
      await c.connect();
      _set(connected ? 'กำลังแชร์สด' : 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้');
      _publishTrack();
    } catch (e) {
      _set('เชื่อมต่อเซิร์ฟเวอร์ไม่ได้: $e');
      c.disconnect();
    }
  }

  Future<void> stop() async {
    if (!enabled) return;
    enabled = false;
    if (connected) {
      _pub('live', jsonEncode({'end': true}));
      _pub('track', '', retain: true); // clear the retained snapshot
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    _c?.disconnect();
    _c = null;
    _set('ปิดอยู่');
  }

  void _pub(String sub, String payload, {bool retain = false}) {
    final c = _c;
    if (c == null || !connected) return;
    final b = MqttClientPayloadBuilder()..addUTF8String(payload);
    c.publishMessage('$topicRoot/$room/$sub', MqttQos.atMostOnce, b.payload!, retain: retain);
  }

  double _r(double v, int d) => double.parse(v.toStringAsFixed(d));

  void _onData() {
    if (!enabled || !connected) return;
    final n = tracker.points.length;
    if (n == 0) {
      if (_lastCount != 0) _publishTrack(); // run was reset
      _lastCount = 0;
      return;
    }
    if (n == _lastCount) return;
    _lastCount = n;
    final now = DateTime.now();
    if (now.difference(_lastLive).inMilliseconds >= 200) {
      _lastLive = now;
      final p = tracker.points.last;
      // live marker = latest phone fix; the smoothed path arrives in the track snapshot
      final pp = tracker.phonePos;
      final fresh = pp != null && tracker.phonePosTime != null && now.difference(tracker.phonePosTime!).inSeconds < 5;
      _pub('live', jsonEncode({
        't': p.time.millisecondsSinceEpoch,
        if (fresh) 'lat': _r(pp!.latitude, 7),
        if (fresh) 'lon': _r(pp!.longitude, 7),
        'spd': _r(p.speedKmh, 1),
        'acc': _r(p.accel / kG, 2),
        'max': _r(tracker.maxSpeed, 1),
        'avg': _r(tracker.avgSpeed, 1),
        'dist': tracker.distance.round(),
        'sats': tracker.sats,
      }));
    }
    if (now.difference(_lastTrack).inSeconds >= 5) _publishTrack();
  }

  /// Retained snapshot: rows of [t (ms epoch), speed, lat?, lon?].
  void _publishTrack() {
    _lastTrack = DateTime.now();
    final pts = tracker.points;
    const maxPts = 1500;
    final step = pts.length > maxPts ? (pts.length / maxPts).ceil() : 1;
    List<num> row(TrackPoint p) => [
          p.time.millisecondsSinceEpoch,
          _r(p.speedKmh, 1),
          if (p.pos != null) ...[_r(p.pos!.latitude, 6), _r(p.pos!.longitude, 6)],
        ];
    final list = <List<num>>[];
    for (var i = 0; i < pts.length; i += step) {
      list.add(row(pts[i]));
    }
    if (pts.isNotEmpty && (pts.length - 1) % step != 0) list.add(row(pts.last));
    _pub('track', jsonEncode({'max': _r(tracker.maxSpeed, 1), 'dist': tracker.distance.round(), 'pts': list}), retain: true);
  }
}
