part of 'monitor.dart';

extension _MqttConnection on Monitor {
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

  void _retryNow() {
    if (!reconnecting || _client != null || _sessionPassword == null) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    unawaited(_open());
  }

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
}
