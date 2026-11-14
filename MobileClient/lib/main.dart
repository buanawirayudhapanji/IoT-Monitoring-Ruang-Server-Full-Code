import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'dashboard.dart';

export 'app_theme.dart';
export 'dashboard.dart' show Dashboard;

void main() => runApp(const ServerRoomApp());

class ServerRoomApp extends StatelessWidget {
  const ServerRoomApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Monitor Ruang Server',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: const Dashboard(),
  );
}
