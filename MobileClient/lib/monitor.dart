import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'firmware_image.dart';

export 'firmware_image.dart';

part 'firmware_update.dart';
part 'mqtt_connection.dart';

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

  void retryNow() => _retryNow();

  void disconnect() => _close();

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

  Future<void> update(FirmwareImage image) => _updateFirmware(image);

  @override
  void dispose() {
    _disposed = true;
    _close();
    _events.close();
    super.dispose();
  }
}
