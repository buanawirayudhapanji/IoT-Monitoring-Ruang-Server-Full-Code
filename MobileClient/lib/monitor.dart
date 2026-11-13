import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

const broker = 'wss://mqtt-wss.wyb.my.id:443/mqtt';
const mqttUser = 'Sertifikasi-ClientMobile';
const device = 'esp32-01';
const root = 'iot/server-room/$device';
const ledNames = ['red', 'yellow', 'green', 'blue'];

String _randomHex(int bytes) {
  final random = Random.secure();
  return List.generate(
    bytes,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

const relayAutoControl = 'relay/auto';
const relayPowerControl = 'relay/power';
const buzzerVolumeControl = 'buzzer/volume';

class FirmwareImage {
  FirmwareImage(this.name, this.bytes) {
    if (bytes.length < 208 ||
        bytes[0] != 0xe9 ||
        ByteData.sublistView(bytes).getUint32(32, Endian.little) !=
            0xabcd5432) {
      throw const FormatException('Pilih file aplikasi ESP32 .ino.bin.');
    }
  }

  final String name;
  final Uint8List bytes;
  String get buildId => bytes
      .sublist(176, 208)
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

typedef _Event = ({String topic, Map<String, dynamic> data, bool retained});

class Monitor extends ChangeNotifier {
  final _events = StreamController<_Event>.broadcast(sync: true);
  MqttServerClient? _client;
  StreamSubscription<dynamic>? _messages;
  final _subscriptions = <String>{};
  bool _disposed = false;

  String? _sessionPassword;
  Timer? _retryTimer;
  int _retryStep = 0;
  bool reconnecting = false;
  bool connecting = false;
  bool get connected => _subscriptions.length == 2;
  String? error;
  String? availability;
  bool get online => connected && availability == 'online';
  Map<String, dynamic>? telemetry;
  DateTime? lastReading;
  Map<String, dynamic>? condition;
  Map<String, dynamic>? firmware;
  Map<String, dynamic>? otaStatus;
  final leds = <String, bool>{};
  final pendingLeds = <String, bool>{};
  final _ledTimers = <String, Timer>{};
  bool? relayAuto;
  bool? relayPower;
  int? buzzerVolume;
  final _controlTimers = <String, Timer>{};
  bool controlPending(String control) => _controlTimers.containsKey(control);
  bool get canSetRelayPower =>
      online &&
      relayAuto == false &&
      relayPower != null &&
      !controlPending(relayAutoControl) &&
      !controlPending(relayPowerControl);

  bool updating = false;
  String? updateMessage;
  bool updateFailed = false;
  double? progress;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> connect(String password) async {
    if (_disposed || _sessionPassword != null) return;
    _sessionPassword = password;
    await _open();
  }

  Future<void> _open() async {
    final password = _sessionPassword;
    if (_disposed || _client != null || password == null) return;
    error = null;
    connecting = true;
    final client =
        MqttServerClient.withPort(broker, 'mobile-${_randomHex(8)}', 443)
          ..useWebSocket = true
          ..websocketProtocols = ['mqtt']
          ..keepAlivePeriod = 15
          ..connectTimeoutPeriod = 8000
          ..disconnectOnNoResponsePeriod = 25;
    client.setProtocolV311();
    _client = client;
    client.onDisconnected = () {
      if (_client == client) {
        final code = client.connectionStatus?.returnCode;
        if (_authRejected(code)) {
          _close('Broker menolak login. Periksa kata sandi dan izin akun.');
        } else {
          _connectionLost();
        }
      }
    };
    client.onSubscribed = (topic) {
      if (_client != client) return;
      _subscriptions.add(topic);
      if (connected) {
        connecting = false;
        reconnecting = false;
        _retryStep = 0;
      }
      _changed();
    };
    client.onSubscribeFail = (topic) {
      if (_client == client) _close('Akses subscribe MQTT ditolak: $topic.');
    };
    _changed();
    try {
      final status = await client.connect(mqttUser, password);
      if (_client != client) return;
      if (status?.state != MqttConnectionState.connected) {
        if (_authRejected(status?.returnCode)) {
          _close('Broker menolak login. Periksa kata sandi dan izin akun.');
        } else {
          _connectionLost();
        }
        return;
      }
      _messages = client.updates!.listen((messages) {
        for (final message in messages) {
          if (_client != client) break;
          final packet = message.payload as MqttPublishMessage;
          _receive(
            message.topic,
            packet.payload.message,
            packet.header!.retain,
          );
        }
      });
      client.subscribe('$root/telemetry', MqttQos.atMostOnce);
      client.subscribe('$root/state/#', MqttQos.atLeastOnce);
      await Future<void>.delayed(const Duration(seconds: 10));
      if (_client == client && !connected) {
        _connectionLost();
      }
    } catch (_) {
      if (_client != client) return;
      if (_authRejected(client.connectionStatus?.returnCode)) {
        _close('Broker menolak login. Periksa kata sandi dan izin akun.');
      } else {
        _connectionLost();
      }
    }
  }

  bool _authRejected(MqttConnectReturnCode? code) =>
      code == MqttConnectReturnCode.badUsernameOrPassword ||
      code == MqttConnectReturnCode.notAuthorized;

  void _connectionLost() {
    reconnecting = true;
    _resetConnection(keepSession: true);
    if (_disposed || _sessionPassword == null) return;
    const delays = [1, 2, 4, 8, 16, 30];
    final seconds = delays[_retryStep];
    if (_retryStep < delays.length - 1) _retryStep++;
    _retryTimer = Timer(Duration(seconds: seconds), retryNow);
  }

  void retryNow() {
    if (!reconnecting || _client != null || _sessionPassword == null) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    unawaited(_open());
  }

  void disconnect() => _close();

  void _close([String? reason]) => _resetConnection(reason: reason);

  void _resetConnection({String? reason, bool keepSession = false}) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!keepSession) {
      _sessionPassword = null;
      reconnecting = false;
      _retryStep = 0;
    }
    final client = _client;
    _client = null;
    _messages?.cancel();
    _messages = null;
    client?.disconnect();
    _subscriptions.clear();
    connecting = false;
    error = reason;
    availability = null;
    if (!keepSession) {
      telemetry = null;
      lastReading = null;
      condition = null;
    }
    firmware = null;
    otaStatus = null;
    leds.clear();
    relayAuto = null;
    relayPower = null;
    buzzerVolume = null;
    _clearControlTimers();
    _clearPendingLeds();
    if (updating) {
      _events.add((topic: 'disconnect', data: {}, retained: false));
    }
    _changed();
  }

  void _clearPendingLeds() {
    for (final timer in _ledTimers.values) {
      timer.cancel();
    }
    _ledTimers.clear();
    pendingLeds.clear();
  }

  void _clearControlTimers() {
    for (final timer in _controlTimers.values) {
      timer.cancel();
    }
    _controlTimers.clear();
  }

  void _receive(String topic, List<int> bytes, bool retained) {
    if (!topic.startsWith('$root/')) return;
    final suffix = topic.substring(root.length + 1);
    final payload = utf8.decode(bytes, allowMalformed: true);
    if (suffix == 'state/availability') {
      if (payload != 'online' && payload != 'offline') return;
      availability = payload;
      if (!online) {
        _clearPendingLeds();
        _clearControlTimers();
      }
    } else if (suffix == 'state/$relayAutoControl' ||
        suffix == 'state/$relayPowerControl') {
      if (payload != 'ON' && payload != 'OFF') return;
      if (suffix == 'state/$relayAutoControl') {
        relayAuto = payload == 'ON';
      } else {
        relayPower = payload == 'ON';
      }
      if (!retained) _controlTimers.remove(suffix.substring(6))?.cancel();
    } else if (suffix == 'state/$buzzerVolumeControl') {
      final level = int.tryParse(payload);
      if (level == null || level < 0 || level > 100) return;
      buzzerVolume = level;
      if (!retained) _controlTimers.remove(buzzerVolumeControl)?.cancel();
    } else if (suffix.startsWith('state/led/')) {
      final color = suffix.split('/').last;
      if (!ledNames.contains(color) || (payload != 'ON' && payload != 'OFF')) {
        return;
      }
      final on = payload == 'ON';
      leds[color] = on;
      if (!retained && pendingLeds[color] == on) {
        pendingLeds.remove(color);
        _ledTimers.remove(color)?.cancel();
      }
    } else {
      final Map<String, dynamic> data;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is! Map<String, dynamic>) return;
        data = decoded;
      } on FormatException {
        return;
      }
      switch (suffix) {
        case 'telemetry':
          telemetry = data;
          lastReading = DateTime.now();
        case 'state/condition':
          condition = data;
        case 'state/firmware':
          firmware = data;
        case 'state/ota':
          otaStatus = data;
        default:
          return;
      }
      _events.add((topic: suffix, data: data, retained: retained));
    }
    _changed();
  }

  void _publish(String suffix, List<int> payload) {
    final client = _client;
    if (!connected || client == null) throw StateError('MQTT terputus.');
    final body = MqttClientPayloadBuilder();
    body.payload!.addAll(payload);
    client.publishMessage(
      '$root/action/$suffix',
      MqttQos.atLeastOnce,
      body.payload!,
      retain: false,
    );
  }

  void setLed(String color, bool on) {
    if (!online || !leds.containsKey(color) || pendingLeds.containsKey(color)) {
      return;
    }
    error = null;
    pendingLeds[color] = on;
    try {
      _publish('led/$color', ascii.encode(on ? 'ON' : 'OFF'));
      _ledTimers[color] = Timer(const Duration(seconds: 8), () {
        pendingLeds.remove(color);
        _ledTimers.remove(color);
        error = 'ESP32 belum mengonfirmasi perintah LED.';
        _changed();
      });
    } catch (_) {
      pendingLeds.remove(color);
      error = 'Perintah LED gagal dikirim.';
    }
    _changed();
  }

  void setRelayAuto(bool on) {
    if (relayAuto == null || controlPending(relayPowerControl)) return;
    _setControl(relayAutoControl, on ? 'ON' : 'OFF', 'mode relay');
  }

  void setRelayPower(bool on) {
    if (!canSetRelayPower) return;
    _setControl(relayPowerControl, on ? 'ON' : 'OFF', 'daya relay');
  }

  void setBuzzerVolume(int level) {
    if (buzzerVolume == null || level < 0 || level > 100) return;
    _setControl(buzzerVolumeControl, level.toString(), 'level buzzer');
  }

  void _setControl(String control, String value, String label) {
    if (!online || updating || controlPending(control)) return;
    error = null;
    try {
      _publish(control, ascii.encode(value));
      _controlTimers[control] = Timer(const Duration(seconds: 8), () {
        _controlTimers.remove(control);
        error = 'ESP32 belum mengonfirmasi $label.';
        _changed();
      });
    } catch (_) {
      error = 'Perintah $label gagal dikirim.';
    }
    _changed();
  }

  Future<void> _waitFor({
    required bool Function(_Event) match,
    required Duration timeout,
    required String description,
    required void Function() send,
    required String transfer,
  }) async {
    final result = Completer<void>();
    final subscription = _events.stream.listen((event) {
      if (result.isCompleted) return;
      if (event.topic == 'disconnect') {
        result.completeError(
          StateError(
            'Koneksi MQTT terputus selama OTA. Mulai ulang unggahan setelah ESP32 siap.',
          ),
        );
      } else if (event.topic == 'state/ota' &&
          event.data['id'] == transfer &&
          event.data['status'] == 'error') {
        result.completeError(
          StateError('ESP32 menolak OTA (${event.data['reason']}).'),
        );
      } else if (match(event)) {
        result.complete();
      }
    });
    try {
      send();
      await result.future.timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException('Waktu tunggu habis saat $description.');
        },
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> update(FirmwareImage image) async {
    if (!online || updating || firmware?['verification'] != 'valid') return;
    updating = true;
    updateFailed = false;
    progress = 0;
    updateMessage = 'Menyiapkan transfer firmware…';
    _changed();
    try {
      final build = image.buildId;
      if (firmware?['build_id'] == build) {
        throw StateError('Firmware ini sudah berjalan di ESP32.');
      }
      final transfer = _randomHex(8);
      final id = ascii.encode(transfer);
      List<int> uint32(int value) =>
          (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

      Future<void> sendPacket(
        String command,
        List<int> body,
        String status,
        int received,
      ) async {
        for (var attempt = 1; attempt <= 3; attempt++) {
          try {
            await _waitFor(
              match: (event) =>
                  event.topic == 'state/ota' &&
                  !event.retained &&
                  event.data['id'] == transfer &&
                  event.data['status'] == status &&
                  event.data['received'] == received,
              timeout: const Duration(seconds: 8),
              description: 'menunggu konfirmasi $command',
              send: () => _publish('ota/$command', body),
              transfer: transfer,
            );
            return;
          } on TimeoutException {
            if (attempt == 3) rethrow;
          }
        }
      }

      final bytes = image.bytes;
      final advertisedSize = firmware?['ota_chunk_size'];
      var chunkSize = advertisedSize is int && advertisedSize >= 1024
          ? min(advertisedSize, 4096)
          : 1024;
      final advertisedWindow = firmware?['ota_window'];
      if (advertisedWindow == 0) {
        throw StateError('ESP32 belum siap menerima OTA. Restart perangkat.');
      }
      var window = advertisedWindow is int && advertisedWindow > 0
          ? min(advertisedWindow, 4)
          : 1;
      final maxSize = firmware?['ota_max_size'];
      if (maxSize is int && bytes.length > maxSize) {
        throw StateError(
          'Firmware ${bytes.length} byte melebihi slot OTA $maxSize byte. '
          'Jika perlu partisi yang lebih besar, unggah sketch terbaru lewat USB.',
        );
      }
      await sendPacket(
        'begin',
        [...id, ...uint32(bytes.length), ...sha256.convert(bytes).bytes],
        'ready',
        0,
      );
      var confirmed = 0;
      var highestSent = 0;
      var consecutiveTimeouts = 0;
      while (confirmed < bytes.length) {
        final start = confirmed;
        final end = min(start + chunkSize * window, bytes.length);
        try {
          await _waitFor(
            match: (event) {
              if (event.topic != 'state/ota' ||
                  event.retained ||
                  event.data['id'] != transfer ||
                  event.data['status'] != 'receiving') {
                return false;
              }
              final received = event.data['received'];
              if (received is! int ||
                  received <= confirmed ||
                  received > highestSent) {
                return false;
              }
              confirmed = received;
              progress = confirmed / bytes.length;
              updateMessage =
                  'Diterima ESP32 $confirmed / ${bytes.length} byte';
              _changed();
              return confirmed >= end;
            },
            timeout: const Duration(seconds: 4),
            description: 'menunggu konfirmasi OTA di $start byte',
            send: () {
              highestSent = max(highestSent, end);
              for (var offset = start; offset < end; offset += chunkSize) {
                final packetEnd = min(offset + chunkSize, end);
                _publish('ota/chunk', [
                  ...id,
                  ...uint32(offset),
                  ...Uint8List.sublistView(bytes, offset, packetEnd),
                ]);
              }
            },
            transfer: transfer,
          );
          consecutiveTimeouts = 0;
        } on TimeoutException {
          consecutiveTimeouts = confirmed > start ? 0 : consecutiveTimeouts + 1;
          // Hitung ulang batas kirim di putaran berikutnya dari offset terkonfirmasi.
          window = 1;
          if (consecutiveTimeouts >= 2) chunkSize = 1024;
          if (consecutiveTimeouts >= 5) {
            throw StateError(
              'Konfirmasi OTA berhenti di $confirmed dari ${bytes.length} byte. '
              'Mulai ulang unggahan setelah ESP32 kembali siap.',
            );
          }
        }
      }

      updateMessage = 'Menunggu restart dan telemetri firmware baru…';
      _changed();
      var pendingBoot = false;
      var freshTelemetry = false;
      await _waitFor(
        match: (event) {
          if (event.retained || event.data['build_id'] != build) return false;
          if (event.topic == 'state/firmware' &&
              (event.data['verification'] == 'pending' ||
                  event.data['verification'] == 'valid')) {
            pendingBoot = true;
          }
          if (event.topic == 'telemetry' &&
              const [
                'temperature_c',
                'humidity_pct',
                'pressure_hpa',
                'bmp_temperature_c',
              ].every(event.data.containsKey)) {
            freshTelemetry = true;
          }
          return pendingBoot && freshTelemetry;
        },
        timeout: const Duration(seconds: 150),
        description: 'menunggu firmware dan telemetri baru',
        send: () => _publish('ota/end', id),
        transfer: transfer,
      );

      updateMessage = 'Memverifikasi firmware baru…';
      _changed();
      if (firmware?['build_id'] != build ||
          firmware?['verification'] != 'valid') {
        await _waitFor(
          match: (event) =>
              event.topic == 'state/firmware' &&
              event.data['build_id'] == build &&
              event.data['verification'] == 'valid',
          timeout: const Duration(seconds: 30),
          description: 'menunggu status firmware valid',
          send: () => _publish('ota/verify', ascii.encode(build)),
          transfer: transfer,
        );
      }
      final activeVersion = firmware?['version'];
      updateMessage = activeVersion is String && activeVersion.isNotEmpty
          ? 'Firmware $activeVersion aktif dan terverifikasi.'
          : 'Firmware baru aktif dan terverifikasi. Versi belum tersedia.';
    } catch (failure) {
      updateFailed = true;
      updateMessage = switch (failure) {
        StateError(:final message) => message.toString(),
        TimeoutException(:final message) => message,
        _ => 'Pembaruan firmware gagal.',
      };
    } finally {
      updating = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _close();
    _events.close();
    super.dispose();
  }
}
