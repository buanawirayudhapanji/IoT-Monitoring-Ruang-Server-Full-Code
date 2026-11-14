import 'dart:typed_data';

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
