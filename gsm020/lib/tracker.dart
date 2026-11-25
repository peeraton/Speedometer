import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

const double kG = 9.80665;

// ---------------------------------------------------------------------------
// SkyRC GSM020 protocol (decoded from the RC Gears app's own BLE logs)
//
//   Advertised name: "GPSspeed"
//   Service 0xFFF0:  0xFFF3 write, 0xFFF4 notify (command replies)
//   Start:           write a time-sync command right after connecting
//   Live data:       16-byte READ, polled ~4-10x per second
//     [0]     fix state (0 = none, 4/6 = fixed)
//     [1]     mode
//     [2]     satellites
//     [6]     1 = hold / no fresh fix
//     [7..8]  speed    uint16 big-endian, km/h x100
//     [9..10] distance uint16 big-endian, m x10 (wraps at 6553.5 m)
//   The device does NOT send latitude/longitude.
// ---------------------------------------------------------------------------
class Gsm020 {
  static const service = '0000fff0-0000-1000-8000-00805f9b34fb';
  static const writeChar = '0000fff3-0000-1000-8000-00805f9b34fb';
  static const notifyChar = '0000fff4-0000-1000-8000-00805f9b34fb';
  static const namePrefixes = ['GPSspeed', 'GNSS', 'GSM'];

  /// Time-sync command; checksum = (sum of bytes[2..14] + 1) & 0xFF.
  static List<int> timeSync([DateTime? at]) {
    final d = (at ?? DateTime.now()).toUtc();
    final b = <int>[0x0f, 0x0e, 0x0b, 0x00, d.second, d.minute, d.hour, d.day, d.month, d.year >> 8, d.year & 0xff, 0, 0, 0, 0];
    final sum = b.sublist(2).fold<int>(0, (a, c) => a + c);
    return [...b, (sum + 1) & 0xff, 0xff, 0xff];
  }

  static bool isLive(List<int> b) => b.length == 16 && b[0] < 0x20 && b[15] == 0;
}

class LiveRecord {
  final int fix, mode, sats, hold;
  final double speedKmh;
  final int distRaw;
  LiveRecord(List<int> b)
      : fix = b[0],
        mode = b[1],
        sats = b[2],
        hold = b[6],
        speedKmh = ((b[7] << 8) | b[8]) / 100.0,
        distRaw = (b[9] << 8) | b[10];
  bool get valid => fix > 0 && hold == 0;
}

class TrackPoint {
  final DateTime time;
  final double speedKmh;
  final double accel; // m/s^2
  final double distM;
  LatLng? pos; // filled in later from phone GPS fixes (see onPhoneFix)
  TrackPoint(this.time, this.speedKmh, this.accel, this.distM, this.pos);
}

class Tracker extends ChangeNotifier {
  final List<TrackPoint> points = [];
  final List<String> raw = [];
  double maxSpeed = 0, maxAccelG = 0, distance = 0;
  int sats = 0;
  bool gnssOk = false, gnssHold = false;
  DateTime? startTime;

  /// Latest phone position (set by the GPS stream in main.dart).
  LatLng? phonePos;
  DateTime? phonePosTime;

  double _accF = 0;
  final List<_Fix> _fixes = [];
  int _assignIdx = 0;
  int? _lastDistRaw;
  int _distBase = 0;

  double get avgSpeed => points.isEmpty ? 0 : points.map((p) => p.speedKmh).reduce((a, b) => a + b) / points.length;
  TrackPoint? get last => points.isEmpty ? null : points.last;
  bool get hasPositions => points.any((p) => p.pos != null);

  void clear() {
    points.clear();
    maxSpeed = 0;
    maxAccelG = 0;
    distance = 0;
    _accF = 0;
    _lastDistRaw = null;
    _distBase = 0;
    startTime = null;
    _fixes.clear();
    _assignIdx = 0;
    usedFixes = 0;
    notifyListeners();
  }

  void logRaw(String tag, List<int> data) {
    final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final t = DateTime.now();
    final ts = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    raw.insert(0, '$ts $tag $hex');
    if (raw.length > 80) raw.removeLast();
  }

  void onLive(LiveRecord r) {
    sats = r.sats;
    gnssOk = r.valid;
    gnssHold = r.hold != 0;
    if (!r.valid) {
      notifyListeners();
      return;
    }
    final now = DateTime.now();
    startTime ??= now;
    if (_lastDistRaw != null && r.distRaw + 30000 < _lastDistRaw!) _distBase += 65536; // 16-bit wrap
    _lastDistRaw = r.distRaw;
    distance = (_distBase + r.distRaw) / 10.0;

    final prev = last;
    double acc = 0;
    if (prev != null) {
      final dt = now.difference(prev.time).inMilliseconds / 1000.0;
      if (dt > 0.02) {
        _accF = 0.35 * ((r.speedKmh - prev.speedKmh) / 3.6 / dt) + 0.65 * _accF;
        acc = _accF;
      }
    }
    points.add(TrackPoint(now, r.speedKmh, acc, distance, null));
    if (r.speedKmh > maxSpeed) maxSpeed = r.speedKmh;
    if (acc.abs() / kG > maxAccelG) maxAccelG = acc.abs() / kG;
    notifyListeners();
  }

  // ---------------- positions from phone GPS ----------------
  // Each sample between two GPS fixes is placed on a Catmull-Rom curve through
  // the fixes, at the fraction of GSM020 distance travelled between them
  // (time is used if the car barely moved). Positions lag ~1-2 s behind live.
  static const gpsMaxErr = 50.0; // metres
  double? phoneAcc;
  int usedFixes = 0;

  void onPhoneFix(LatLng p, double accuracyM) {
    phonePos = p;
    phonePosTime = DateTime.now();
    phoneAcc = accuracyM;
    if (accuracyM <= gpsMaxErr) {
      usedFixes++;
      _fixes.add(_Fix(phonePosTime!, p, points.isEmpty ? 0 : points.last.distM));
      if (_fixes.length > 400) {
        _fixes.removeRange(0, _fixes.length - 400);
      }
      if (_fixes.length >= 3) _assignSegment(_fixes.length - 3);
    }
    notifyListeners();
  }

  static double _cr(double p0, double p1, double p2, double p3, double u) {
    final u2 = u * u, u3 = u2 * u;
    return 0.5 * (2 * p1 + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2 + (-p0 + 3 * p1 - 3 * p2 + p3) * u3);
  }

  void _assignSegment(int k) {
    final p1 = _fixes[k], p2 = _fixes[k + 1];
    final p0 = k > 0 ? _fixes[k - 1] : p1;
    final p3 = k + 2 < _fixes.length ? _fixes[k + 2] : p2;
    final gap = p2.t.difference(p1.t).inMilliseconds > 5000; // GPS dropout: don't invent a path
    final dd = p2.d - p1.d;
    final dt = math.max(1, p2.t.difference(p1.t).inMilliseconds);
    while (_assignIdx < points.length && points[_assignIdx].time.isBefore(p2.t)) {
      final s = points[_assignIdx++];
      if (s.time.isBefore(p1.t) || gap) continue;
      var u = dd > 0.3 ? (s.distM - p1.d) / dd : s.time.difference(p1.t).inMilliseconds / dt;
      u = u.clamp(0.0, 1.0).toDouble();
      s.pos = LatLng(
        _cr(p0.p.latitude, p1.p.latitude, p2.p.latitude, p3.p.latitude, u),
        _cr(p0.p.longitude, p1.p.longitude, p2.p.longitude, p3.p.longitude, u),
      );
    }
  }

  String toCsv() {
    final b = StringBuffer('time,speed_kmh,accel_ms2,accel_g,distance_m,lat,lon\n');
    for (final p in points) {
      b.writeln('${p.time.toIso8601String()},${p.speedKmh.toStringAsFixed(2)},${p.accel.toStringAsFixed(3)},'
          '${(p.accel / kG).toStringAsFixed(3)},${p.distM.toStringAsFixed(1)},'
          '${p.pos?.latitude.toStringAsFixed(7) ?? ''},${p.pos?.longitude.toStringAsFixed(7) ?? ''}');
    }
    return b.toString();
  }

  String toGpx() {
    final b = StringBuffer('<?xml version="1.0"?>\n'
        '<gpx version="1.1" creator="GSM020 Tracker" xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>\n');
    for (final p in points.where((p) => p.pos != null)) {
      b.writeln('<trkpt lat="${p.pos!.latitude}" lon="${p.pos!.longitude}">'
          '<time>${p.time.toUtc().toIso8601String()}</time>'
          '<desc>${p.speedKmh.toStringAsFixed(1)} km/h</desc></trkpt>');
    }
    b.write('</trkseg></trk></gpx>\n');
    return b.toString();
  }
}

class _Fix {
  final DateTime t;
  final LatLng p;
  final double d; // GSM020 distance (m) at the moment of this fix
  _Fix(this.t, this.p, this.d);
}
