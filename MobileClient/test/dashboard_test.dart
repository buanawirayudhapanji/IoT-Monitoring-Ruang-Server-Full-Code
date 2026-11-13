import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:server_room_monitor/main.dart';

void main() {
  testWidgets(
    'dashboard shows unknown device and disables controls before login',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 780));
      await tester.pumpWidget(const ServerRoomApp());
      expect(find.text('ESP32 · Belum diketahui'), findsOneWidget);
      expect(find.text('MQTT terputus'), findsOneWidget);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Suhu BMP180'),
        220,
        scrollable: list,
      );
      expect(find.text('Suhu BMP180'), findsOneWidget);
      await tester.tap(find.text('Kontrol'));
      await tester.pumpAndSettle();
      expect(find.text('Mode otomatis kipas'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      await tester.scrollUntilVisible(
        find.text('LED Biru'),
        220,
        scrollable: list,
      );
      expect(
        tester
            .widgetList<SwitchListTile>(find.byType(SwitchListTile))
            .every((tile) => tile.onChanged == null),
        isTrue,
      );
      await tester.tap(find.text('Firmware'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Update OTA'),
        220,
        scrollable: list,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Update OTA'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
