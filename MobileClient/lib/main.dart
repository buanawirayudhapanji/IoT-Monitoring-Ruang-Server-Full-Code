import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'monitor.dart';

const ink = Color(0xff171715);
const accent = Color(0xffffd64d);
const paper = Color(0xfff5f5f2);
const muted = Color(0xff5c5c55);
const line = Color(0xffdeded8);
const warning = Color(0xfffff3c4);
const pageInset = 20.0;
const panelInset = 16.0;
const panelRadius = 16.0;

void main() => runApp(const ServerRoomApp());

class ServerRoomApp extends StatelessWidget {
  const ServerRoomApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Monitor Ruang Server',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: ink).copyWith(
        primary: ink,
        onPrimary: Colors.white,
        secondary: accent,
        onSecondary: ink,
        surface: Colors.white,
        onSurface: ink,
        onSurfaceVariant: muted,
        outline: line,
        outlineVariant: line,
        error: const Color(0xff705100),
      ),
      scaffoldBackgroundColor: paper,
      fontFamily: 'Roboto',
      cardTheme: const CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: line),
          borderRadius: BorderRadius.all(Radius.circular(panelRadius)),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: accent,
        elevation: 0,
        height: 68,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    ),
    home: const Dashboard(),
  );
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  final monitor = Monitor();
  final password = TextEditingController();
  FirmwareImage? selected;
  String? fileError;
  bool picking = false;
  bool hidePassword = true;
  double? buzzerDraft;
  int selectedTab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) monitor.retryNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    password.dispose();
    monitor.dispose();
    super.dispose();
  }

  Future<void> pickFirmware() async {
    setState(() {
      picking = true;
      fileError = null;
    });
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Pilih firmware ESP32 (.ino.bin)',
        type: FileType.custom,
        allowedExtensions: ['bin'],
      );
      if (file == null || !mounted) return;
      if (!file.name.toLowerCase().endsWith('.ino.bin')) {
        throw const FormatException('Pilih file aplikasi ESP32 .ino.bin.');
      }
      const maxSize = 16 * 1024 * 1024;
      if ((await file.length() ?? 0) > maxSize) {
        throw const FormatException('File firmware terlalu besar.');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > maxSize) {
        throw const FormatException('File firmware terlalu besar.');
      }
      final image = FirmwareImage(file.name, bytes);
      if (mounted) setState(() => selected = image);
    } catch (error) {
      if (mounted) {
        setState(() {
          selected = null;
          fileError = error is FormatException
              ? error.message
              : 'File firmware tidak dapat dibaca.';
        });
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  void login() {
    if (password.text.isEmpty) return;
    final value = password.text;
    password.clear();
    FocusScope.of(context).unfocus();
    monitor.connect(value);
  }

  Future<void> confirmUpdate(FirmwareImage image) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Perbarui firmware ESP32?'),
        content: Text(
          '${image.name}\n\nESP32 akan restart. Biarkan aplikasi terbuka sampai firmware terverifikasi.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Mulai OTA'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) await monitor.update(image);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: monitor,
    builder: (context, _) => Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              key: PageStorageKey(selectedTab),
              padding: const EdgeInsets.fromLTRB(pageInset, 16, pageInset, 24),
              children: [
                _header(),
                if (!monitor.connected &&
                    !monitor.reconnecting &&
                    selectedTab == 0) ...[
                  const SizedBox(height: 16),
                  _connection(),
                ],
                if (monitor.error case final error?) ...[
                  const SizedBox(height: 12),
                  _notice(error, Icons.info_outline),
                ],
                if (selectedTab != 0 &&
                    !monitor.connected &&
                    !monitor.reconnecting) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => selectedTab = 0),
                      icon: const Icon(Icons.link),
                      label: const Text('Ke pengaturan koneksi'),
                    ),
                  ),
                ],
                ...switch (selectedTab) {
                  0 => [
                    const SizedBox(height: 16),
                    _condition(),
                    _heading('Pembacaan sensor', trailing: _readingTime()),
                    _sensors(),
                  ],
                  1 => [
                    _heading('Kipas dan alarm'),
                    _fanAndAlarm(),
                    _heading('Lampu'),
                    _lights(),
                  ],
                  _ => [_heading('Firmware ESP32'), _firmware()],
                },
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: line)),
        ),
        child: NavigationBar(
          selectedIndex: selectedTab,
          onDestinationSelected: (tab) => setState(() {
            selectedTab = tab;
            buzzerDraft = null;
          }),
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Ringkasan',
            ),
            const NavigationDestination(
              icon: Icon(Icons.tune),
              label: 'Kontrol',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: monitor.updating,
                backgroundColor: accent,
                child: const Icon(Icons.system_update_alt),
              ),
              label: 'Firmware',
            ),
          ],
        ),
      ),
    ),
  );

  Widget _header() {
    final deviceStatus = switch (monitor.availability) {
      'online' when monitor.connected => 'Aktif',
      'offline' when monitor.connected => 'Offline',
      _ => 'Belum diketahui',
    };
    return Container(
      padding: const EdgeInsets.all(pageInset),
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(panelRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.dns_outlined, color: accent, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(device, style: TextStyle(color: Colors.white70)),
              ),
              if (monitor.connected || monitor.reconnecting)
                IconButton(
                  tooltip: 'Putuskan koneksi MQTT',
                  onPressed: monitor.updating ? null : monitor.disconnect,
                  color: Colors.white,
                  disabledColor: Colors.white38,
                  icon: const Icon(Icons.link_off),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Monitor Ruang Server',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 27,
              height: 1.15,
              letterSpacing: -0.7,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.circle,
                    size: 8,
                    color: monitor.online ? accent : Colors.white54,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      'ESP32 · $deviceStatus',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ],
              ),
              Text(
                monitor.reconnecting
                    ? 'Menyambungkan ulang…'
                    : monitor.connected
                    ? 'MQTT tersambung'
                    : 'MQTT terputus',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _notice(String message, IconData icon) => Container(
    padding: const EdgeInsets.all(panelInset),
    decoration: BoxDecoration(
      color: warning,
      borderRadius: BorderRadius.circular(panelRadius),
    ),
    child: Row(
      children: [
        Icon(icon, color: ink, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ],
    ),
  );

  Widget _connection() => Card(
    child: Padding(
      padding: const EdgeInsets.all(panelInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Sambungkan MQTT',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: ink,
              fontSize: 17,
            ),
          ),
          const Text(mqttUser, style: TextStyle(color: muted)),
          const SizedBox(height: 12),
          TextField(
            controller: password,
            enabled: !monitor.connecting,
            obscureText: hidePassword,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => login(),
            decoration: InputDecoration(
              labelText: 'Kata sandi MQTT',
              suffixIcon: IconButton(
                tooltip: hidePassword
                    ? 'Tampilkan kata sandi'
                    : 'Sembunyikan kata sandi',
                onPressed: () => setState(() => hidePassword = !hidePassword),
                icon: Icon(
                  hidePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: monitor.connecting ? null : login,
            child: Text(monitor.connecting ? 'Menyambungkan…' : 'Sambungkan'),
          ),
        ],
      ),
    ),
  );

  Widget _heading(String title, {String? trailing}) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 9),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 14,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: ink,
            fontWeight: FontWeight.w800,
            fontSize: 21,
          ),
        ),
        if (trailing != null)
          Text(trailing, style: const TextStyle(color: muted, fontSize: 12)),
      ],
    ),
  );

  String _readingTime() {
    final time = monitor.lastReading;
    if (time == null) return 'Menunggu data';
    final label = monitor.online ? 'Diterima' : 'Data terakhir';
    return '$label ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(time), alwaysUse24HourFormat: true)}';
  }

  static const metrics = [
    (
      key: 'temperature_c',
      label: 'Suhu ruangan',
      unit: '°C',
      sensor: 'dht22',
      icon: Icons.thermostat,
    ),
    (
      key: 'humidity_pct',
      label: 'Kelembapan',
      unit: '%',
      sensor: 'dht22',
      icon: Icons.water_drop_outlined,
    ),
    (
      key: 'pressure_hpa',
      label: 'Tekanan udara',
      unit: 'hPa',
      sensor: 'bmp180',
      icon: Icons.speed,
    ),
    (
      key: 'bmp_temperature_c',
      label: 'Suhu BMP180',
      unit: '°C',
      sensor: 'bmp180',
      icon: Icons.device_thermostat,
    ),
  ];

  Widget _sensors() => LayoutBuilder(
    builder: (context, constraints) => Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final metric in metrics)
          SizedBox(
            width: constraints.maxWidth < 300
                ? constraints.maxWidth
                : (constraints.maxWidth - 10) / 2,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(metric.icon, color: ink, size: 20),
                    const SizedBox(height: 8),
                    Text(
                      metric.label,
                      style: const TextStyle(
                        color: muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _measurement(metric.key, metric.unit),
                      style: const TextStyle(
                        color: ink,
                        fontSize: 25,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      _sensorLabel(metric.sensor),
                      style: const TextStyle(color: muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

  String _measurement(String key, String unit) {
    final value = monitor.telemetry?[key];
    return value is num ? '${value.toStringAsFixed(1)} $unit' : '—';
  }

  String _sensorLabel(String sensor) {
    final statuses = monitor.telemetry?['sensor_status'];
    final status = statuses is Map ? statuses[sensor] : null;
    return switch (status) {
      'ok' => '${sensor.toUpperCase()} · Normal',
      'read_error' => '${sensor.toUpperCase()} · Gagal dibaca',
      _ => sensor.toUpperCase(),
    };
  }

  Widget _condition() {
    final state = monitor.condition?['condition'];
    final issues = monitor.condition?['issues'];
    return Card(
      color: state == 'abnormal' ? warning : null,
      child: Padding(
        padding: const EdgeInsets.all(panelInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  state == 'normal'
                      ? Icons.check_circle_outline
                      : Icons.info_outline,
                  color: ink,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    switch (state) {
                      'normal' => 'Kondisi ruangan normal',
                      'abnormal' => 'Kondisi ruangan di luar batas',
                      _ => 'Menunggu kondisi ruangan',
                    },
                    style: const TextStyle(
                      color: ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (issues is List)
              for (final issue in issues.whereType<Map>())
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _issue(issue),
                    style: const TextStyle(color: muted),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  String _issue(Map issue) {
    if (issue['reason'] == 'read_error') {
      return 'Sensor ${issue['sensor'].toString().toUpperCase()} gagal dibaca.';
    }
    for (final metric in metrics) {
      if (metric.key == issue['parameter']) {
        return '${metric.label} ${issue['value']} ${metric.unit} · batas ${issue['min']}–${issue['max']} ${metric.unit}';
      }
    }
    return 'Peringatan perangkat: ${issue['reason']}';
  }

  Widget _lights() {
    const labels = ['Merah', 'Kuning', 'Hijau', 'Biru'];
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < ledNames.length; i++) ...[
            if (i != 0) const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile(
              secondary: const Icon(Icons.lightbulb_outline),
              title: Text('LED ${labels[i]}'),
              subtitle: Text(switch ((
                monitor.pendingLeds[ledNames[i]],
                monitor.leds[ledNames[i]],
              )) {
                (final bool requested, _) =>
                  'Menunggu konfirmasi ${requested ? 'ON' : 'OFF'}',
                (_, true) => 'Menyala',
                (_, false) => 'Mati',
                _ => 'Status belum diterima',
              }),
              value: monitor.leds[ledNames[i]] ?? false,
              onChanged:
                  monitor.online &&
                      monitor.leds.containsKey(ledNames[i]) &&
                      !monitor.pendingLeds.containsKey(ledNames[i])
                  ? (value) => monitor.setLed(ledNames[i], value)
                  : null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _fanAndAlarm() {
    final automatic = monitor.relayAuto;
    final power = monitor.relayPower;
    final volume = monitor.buzzerVolume;
    final canControl = monitor.online && !monitor.updating;
    final modePending = monitor.controlPending(relayAutoControl);
    final powerPending = monitor.controlPending(relayPowerControl);
    final volumePending = monitor.controlPending(buzzerVolumeControl);

    return Card(
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.thermostat),
            title: const Text('Mode otomatis kipas'),
            subtitle: Text(switch (automatic) {
              _ when modePending => 'Menunggu konfirmasi ESP32',
              true => 'Kipas menyala saat suhu di atas 27 °C',
              false => 'Kontrol manual',
              null => 'Status belum diterima',
            }),
            value: automatic ?? false,
            onChanged:
                canControl && automatic != null && !modePending && !powerPending
                ? monitor.setRelayAuto
                : null,
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.air),
            title: const Text('Kipas'),
            subtitle: Text(switch (power) {
              _ when powerPending => 'Menunggu konfirmasi ESP32',
              true => 'Menyala',
              false => 'Mati',
              null => 'Status belum diterima',
            }),
            value: power ?? false,
            onChanged: canControl && monitor.canSetRelayPower
                ? monitor.setRelayPower
                : null,
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Level buzzer'),
            subtitle: Text(
              volumePending
                  ? 'Menunggu konfirmasi ESP32'
                  : volume == null
                  ? 'Status belum diterima'
                  : 'Aktif: $volume / 100 · Level tinggi mempercepat bip',
            ),
          ),
          Slider(
            value: canControl && volume != null
                ? buzzerDraft ?? volume.toDouble()
                : (volume ?? 0).toDouble(),
            max: 100,
            divisions: 100,
            label: ((buzzerDraft ?? volume ?? 0).round()).toString(),
            semanticFormatterCallback: (value) =>
                'Level buzzer ${value.round()}',
            onChanged: canControl && volume != null && !volumePending
                ? (value) => setState(() => buzzerDraft = value)
                : null,
            onChangeEnd: (value) {
              setState(() => buzzerDraft = null);
              monitor.setBuzzerVolume(value.round());
            },
          ),
        ],
      ),
    );
  }

  Widget _firmware() {
    final firmware = monitor.firmware;
    final image = selected;
    final version = firmware?['version'];
    final versionLabel = version is String && version.trim().isNotEmpty
        ? version
        : null;
    final canUpdate =
        monitor.online &&
        firmware?['verification'] == 'valid' &&
        !monitor.updating &&
        !picking;
    final ota = monitor.otaStatus;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(panelInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(switch (firmware?['verification']) {
              'valid' when versionLabel != null =>
                'Firmware aktif terverifikasi · $versionLabel',
              'valid' => 'Firmware aktif terverifikasi · Versi belum tersedia',
              'pending' => 'Firmware menunggu verifikasi',
              _ => 'Menunggu status firmware',
            }, style: const TextStyle(color: ink, fontWeight: FontWeight.w800)),
            if (ota != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(switch (ota['status']) {
                  'ready' => 'OTA ESP32 · Siap menerima',
                  'receiving' => 'OTA ESP32 · ${ota['received']} byte diterima',
                  'error' => 'OTA ESP32 · Gagal (${ota['reason']})',
                  _ => 'OTA ESP32 · ${ota['status']}',
                }),
              ),
            if (monitor.updateMessage case final message?) ...[
              const SizedBox(height: 9),
              Text(
                message,
                style: TextStyle(
                  color: monitor.updateFailed
                      ? Theme.of(context).colorScheme.error
                      : ink,
                ),
              ),
              if (monitor.updating) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: monitor.progress == 1 ? null : monitor.progress,
                ),
              ],
            ],
            if (image != null) ...[
              const SizedBox(height: 10),
              Text(
                image.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                '${image.bytes.length} byte',
                style: const TextStyle(color: muted),
              ),
            ],
            if (fileError case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.attach_file),
                  onPressed: picking || monitor.updating ? null : pickFirmware,
                  label: Text(picking ? 'Membaca file…' : 'Pilih firmware'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.system_update_alt),
                  onPressed: canUpdate && image != null
                      ? () => confirmUpdate(image)
                      : null,
                  label: const Text('Update OTA'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
