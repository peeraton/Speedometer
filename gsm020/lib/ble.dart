import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:latlong2/latlong.dart';

import 'tracker.dart';

/// Owns the GSM020 connection (or the demo generator) and feeds Tracker.
class Link extends ChangeNotifier {
  final Tracker tracker;
  Link(this.tracker);

  BluetoothDevice? device;
  bool connected = false;
  bool demo = false;
  bool _polling = false;
  String status = 'ยังไม่ได้เชื่อมต่อ';
  StreamSubscription? _stateSub;
  Timer? _demoTimer;

  void _set(String s) {
    status = s;
    notifyListeners();
  }

  Guid get _svc => Guid(Gsm020.service);

  static String _short(Guid g) {
    final s = g.toString();
    return s.length >= 8 ? s.substring(4, 8) : s;
  }

  Future<void> connect(BluetoothDevice d) async {
    await stop();
    device = d;
    _set('กำลังเชื่อมต่อ ${d.platformName} ...');
    try {
      _stateSub = d.connectionState.listen((s) {
        connected = s == BluetoothConnectionState.connected;
        if (!connected && device != null) {
          _polling = false;
          _set('การเชื่อมต่อหลุด กดเชื่อมต่อใหม่ได้');
        }
        notifyListeners();
      });
      await d.connect(timeout: const Duration(seconds: 15), autoConnect: false);
      final services = await d.discoverServices();
      final svc = services.where((s) => s.uuid == _svc).firstOrNull;
      if (svc == null) {
        _set('ไม่พบ service ของ GSM020 (fff0) ในอุปกรณ์นี้');
        return;
      }
      BluetoothCharacteristic? find(String u) => svc.characteristics.where((c) => c.uuid == Guid(u)).firstOrNull;

      // 1) replies to our commands
      final n = find(Gsm020.notifyChar);
      if (n != null) {
        final sub = n.onValueReceived.listen((v) => tracker.logRaw('ตอบกลับ', v));
        d.cancelWhenDisconnected(sub);
        try {
          await n.setNotifyValue(true);
        } catch (_) {}
      }

      // 2) start command (time sync) - wakes the GSM020 up, same as RC Gears
      final w = find(Gsm020.writeChar);
      if (w == null) {
        _set('ไม่พบช่องส่งคำสั่ง (fff3)');
        return;
      }
      final cmd = Gsm020.timeSync();
      await w.write(cmd, withoutResponse: !w.properties.write && w.properties.writeWithoutResponse);
      tracker.logRaw('ส่งคำสั่ง', cmd);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // 3) find the characteristic that returns the 16-byte live record
      BluetoothCharacteristic? live;
      for (var attempt = 0; attempt < 4 && live == null; attempt++) {
        for (final c in svc.characteristics) {
          if (!c.properties.read) continue;
          try {
            final v = await c.read();
            tracker.logRaw('อ่าน ${_short(c.uuid)}', v);
            if (Gsm020.isLive(v)) {
              live = c;
              break;
            }
          } catch (_) {}
        }
        if (live == null) await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      if (live == null) {
        _set('เชื่อมต่อได้ แต่ยังไม่พบช่องข้อมูลความเร็ว ลองหยุดแล้วเชื่อมต่อใหม่');
        return;
      }
      _set('เชื่อมต่อแล้ว รอไฟเขียว (GNSS) ที่เครื่อง');
      _poll(live);
    } catch (e) {
      _set('เชื่อมต่อไม่สำเร็จ: $e (ปิดแอป RC Gears ให้สนิทก่อน)');
    }
  }

  /// Poll the live record like RC Gears does (no faster than every 100 ms).
  Future<void> _poll(BluetoothCharacteristic c) async {
    _polling = true;
    int n = 0;
    bool announced = false;
    while (_polling && connected) {
      final sw = Stopwatch()..start();
      try {
        final v = await c.read();
        if (++n % 10 == 0) tracker.logRaw('ข้อมูล', v);
        if (Gsm020.isLive(v)) {
          final r = LiveRecord(v);
          tracker.onLive(r);
          if (r.valid && !announced) {
            announced = true;
            _set('กำลังบันทึก');
          }
        }
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      final wait = 100 - sw.elapsedMilliseconds;
      if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
    }
  }

  /// Point on an oval track (2 x 60 m straights, 20 m bends) at distance [dm].
  static LatLng ovalPoint(double dm, LatLng c) {
    const l1 = 60.0, r = 20.0;
    final per = 2 * l1 + 2 * math.pi * r;
    var d = dm % per;
    double x, y;
    if (d < l1) {
      x = -l1 / 2 + d;
      y = -r;
    } else if ((d -= l1) < math.pi * r) {
      final a = -math.pi / 2 + d / r;
      x = l1 / 2 + r * math.cos(a);
      y = r * math.sin(a);
    } else if ((d -= math.pi * r) < l1) {
      x = l1 / 2 - d;
      y = r;
    } else {
      d -= l1;
      final a = math.pi / 2 + d / r;
      x = -l1 / 2 + r * math.cos(a);
      y = r * math.sin(a);
    }
    final mLon = 111320 * math.cos(c.latitude * math.pi / 180);
    return LatLng(c.latitude + y / 111320, c.longitude + x / mLon);
  }

  /// Demo: GSM020-format records at 4 Hz plus a simulated phone GPS at 1 Hz.
  Future<void> startDemo(LatLng center) async {
    await stop();
    tracker.clear();
    demo = true;
    _set('โหมดทดลอง: ข้อมูลจำลองแบบ GSM020 พร้อม GPS จำลองวิ่งรอบสนามวงรี');
    int k = 0;
    double dist = 0; // 0.1 m units, like the device
    final rnd = math.Random();
    final per = 120 + 2 * math.pi * 20;
    _demoTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      k++;
      final d = (dist / 10) % per;
      final bend = (d > 60 && d < 60 + math.pi * 20) || d > 120 + math.pi * 20;
      final spd = (bend ? 28 : 55) + rnd.nextDouble() * 4;
      dist += spd / 3.6 * 0.25 * 10;
      final sp = (spd * 100).round(), ds = dist.round() & 0xffff;
      tracker.onLive(LiveRecord([6, 1, 12, 0, 0, 0, 0, sp >> 8, sp & 0xff, ds >> 8, ds & 0xff, 0x4d, 0xf0, 0, 0, 0]));
      if (k % 4 == 0) {
        final p = ovalPoint(dist / 10, center);
        double n() => (rnd.nextDouble() - 0.5) * 1.5e-5;
        tracker.onPhoneFix(LatLng(p.latitude + n(), p.longitude + n()), 4);
      }
    });
    notifyListeners();
  }

  Future<void> stop() async {
    _polling = false;
    _demoTimer?.cancel();
    _demoTimer = null;
    demo = false;
    await _stateSub?.cancel();
    _stateSub = null;
    final d = device;
    device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    connected = false;
    _set('หยุดแล้ว');
  }

  bool get active => connected || demo;
}
