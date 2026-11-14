part of 'monitor.dart';

extension _FirmwareUpdate on Monitor {
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

  Future<void> _updateFirmware(FirmwareImage image) async {
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
}
