import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:share_plus/share_plus.dart';

import 'ble.dart';
import 'live.dart';
import 'tracker.dart';

// ---------------------------------------------------------------- scan
class ScanPage extends StatefulWidget {
  final Link link;
  const ScanPage({super.key, required this.link});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  String? error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => error = null);
    try {
      if (await FlutterBluePlus.isSupported == false) {
        setState(() => error = 'มือถือเครื่องนี้ไม่รองรับ Bluetooth LE');
        return;
      }
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    } catch (e) {
      setState(() => error = 'สแกนไม่ได้: $e\nเปิดบลูทูธ และอนุญาตสิทธิ์ "อุปกรณ์ใกล้เคียง" ให้แอป');
    }
  }

  @override
  void dispose() {
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  String _name(ScanResult r) {
    final n = r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName;
    return n.isEmpty ? '(ไม่มีชื่อ)' : n;
  }

  bool _likely(ScanResult r) {
    final n = _name(r).toUpperCase();
    return Gsm020.namePrefixes.any((p) => n.startsWith(p.toUpperCase())) || n.contains('SKYRC');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('เลือกอุปกรณ์'), actions: [
        StreamBuilder<bool>(
          stream: FlutterBluePlus.isScanning,
          initialData: false,
          builder: (_, s) => s.data!
              ? const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(icon: const Icon(Icons.refresh), onPressed: _scan),
        ),
      ]),
      body: Column(children: [
        if (error != null) Padding(padding: const EdgeInsets.all(12), child: Text(error!, style: const TextStyle(color: Colors.orange))),
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text('เปิดเครื่อง GSM020 และปิดแอป RC Gears ให้สนิทก่อน GSM020 จะแสดงชื่อ GPSspeed อยู่ด้านบนสุด',
              style: TextStyle(fontSize: 12, color: Colors.white60)),
        ),
        Expanded(
          child: StreamBuilder<List<ScanResult>>(
            stream: FlutterBluePlus.scanResults,
            initialData: const [],
            builder: (_, snap) {
              final list = [...snap.data!]..sort((a, b) {
                  final la = _likely(a) ? 0 : 1, lb = _likely(b) ? 0 : 1;
                  return la != lb ? la - lb : b.rssi - a.rssi;
                });
              return ListView(
                children: list
                    .map((r) => ListTile(
                          leading: Icon(Icons.bluetooth, color: _likely(r) ? Colors.lightBlueAccent : Colors.white38),
                          title: Text(_name(r), style: TextStyle(fontWeight: _likely(r) ? FontWeight.bold : FontWeight.normal)),
                          subtitle: Text('${r.device.remoteId}  ${r.rssi} dBm'),
                          onTap: () {
                            FlutterBluePlus.stopScan();
                            widget.link.connect(r.device);
                            Navigator.pop(context);
                          },
                        ))
                    .toList(),
              );
            },
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- raw packets
class RawPage extends StatelessWidget {
  final Tracker tracker;
  const RawPage({super.key, required this.tracker});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('แพ็กเก็ตดิบ')),
      body: AnimatedBuilder(
        animation: tracker,
        builder: (_, __) => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const Text('ข้อมูลที่รับส่งกับ GSM020 (ไว้ตรวจสอบเมื่อมีปัญหา)',
                style: TextStyle(fontSize: 12, color: Colors.white60)),
            const SizedBox(height: 8),
            ...tracker.raw.map((l) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SelectableText(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                )),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- live share
class LiveSharePage extends StatefulWidget {
  final LiveShare live;
  const LiveSharePage({super.key, required this.live});
  @override
  State<LiveSharePage> createState() => _LiveSharePageState();
}

class _LiveSharePageState extends State<LiveSharePage> {
  late final TextEditingController urlCtl = TextEditingController(text: widget.live.viewerUrl);

  Future<void> _applyUrl() async {
    widget.live.viewerUrl = urlCtl.text.trim();
    await widget.live.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.live;
    return Scaffold(
      appBar: AppBar(title: const Text('แชร์ลิงก์ดูสด')),
      body: AnimatedBuilder(
        animation: l,
        builder: (_, __) => ListView(padding: const EdgeInsets.all(16), children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('ส่งข้อมูลสดขึ้นอินเทอร์เน็ต', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(l.status, style: TextStyle(color: l.connected ? Colors.greenAccent : Colors.amber)),
            value: l.enabled,
            onChanged: (v) => v ? l.start() : l.stop(),
          ),
          const Divider(),
          TextField(
            controller: urlCtl,
            decoration: const InputDecoration(
              labelText: 'ที่อยู่หน้าเว็บสำหรับคนดู',
              hintText: 'https://ชื่อคุณ.github.io/gsm020-tracker/viewer/',
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _applyUrl(),
            onEditingComplete: _applyUrl,
          ),
          const SizedBox(height: 16),
          Row(children: [
            const Text('รหัสห้อง: ', style: TextStyle(color: Colors.white70)),
            SelectableText(l.room, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 2)),
            const Spacer(),
            TextButton(
              onPressed: l.enabled
                  ? null
                  : () async {
                      l.room = LiveShare.newRoom();
                      await l.save();
                      setState(() {});
                    },
              child: const Text('สุ่มรหัสใหม่'),
            ),
          ]),
          const SizedBox(height: 8),
          if (l.link.isNotEmpty) ...[
            SelectableText(l.link, style: const TextStyle(color: Colors.lightBlueAccent)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.share),
                  label: const Text('ส่งลิงก์'),
                  onPressed: () async {
                    await _applyUrl();
                    await Share.share('ดูตำแหน่งและความเร็วสด: ${l.link}');
                  },
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('คัดลอก'),
                onPressed: () async {
                  await _applyUrl();
                  await Clipboard.setData(ClipboardData(text: l.link));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('คัดลอกลิงก์แล้ว')));
                  }
                },
              ),
            ]),
          ] else
            const Text('ใส่ที่อยู่หน้าเว็บสำหรับคนดูก่อน (ดูวิธีตั้งใน README)', style: TextStyle(color: Colors.amber)),
          const SizedBox(height: 20),
          const Text(
            'ใครที่มีลิงก์จะเห็นตำแหน่งของคุณ ส่งให้เฉพาะคนที่ต้องการ และกดสุ่มรหัสใหม่เมื่อไม่อยากให้ลิงก์เดิมใช้ได้อีก '
            'ข้อมูลส่งผ่านเซิร์ฟเวอร์ MQTT สาธารณะ (broker.emqx.io) ไม่ได้เข้ารหัสแบบปลายทาง',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ]),
      ),
    );
  }
}
