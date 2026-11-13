# Monitor Ruang Server

Aplikasi Flutter untuk Android, terhubung ke ESP32 `esp32-01` melalui EMQX. Masukkan kata sandi akun `Sertifikasi-ClientMobile` pada layar utama. Aplikasi memakai WSS dan menyimpan kata sandi hanya selama sesi koneksi.

- Telemetri menampilkan suhu DHT22, kelembapan, tekanan udara, suhu BMP180, dan status kedua sensor.
- Status perangkat dan kondisi ruangan mengikuti pesan ESP32. Sakelar LED mengikuti status yang dilaporkan ESP32 dan menunggu konfirmasi setelah setiap perintah.
- Untuk OTA, pilih file aplikasi `.ino.bin` yang sesuai dengan perangkat, lalu tekan **Update OTA**. Biarkan aplikasi terbuka sampai ESP32 mengonfirmasi build baru terverifikasi.

## Topik MQTT

Aplikasi subscribe ke `iot/server-room/esp32-01/telemetry` dan `iot/server-room/esp32-01/state/#`. Status yang dipakai mencakup `availability`, `condition`, `led/red`, `led/yellow`, `led/green`, `led/blue`, `firmware`, dan `ota`.

Perintah dikirim melalui `action/led/{red,yellow,green,blue}` dan `action/ota/{begin,chunk,end,verify}` dengan QoS 1 dan Retain OFF. ACL ada di [proyek ESP32](../IoT-Monitoring-Ruang-Server/emqx-acl.conf).

## Build APK

```sh
flutter pub get
flutter analyze
flutter build apk --release
```

APK hasil build ada di `build/app/outputs/flutter-apk/app-release.apk`. Konfigurasi proyek memakai tanda tangan debug untuk pemasangan langsung.
