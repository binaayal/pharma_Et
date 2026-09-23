import 'package:flutter/material.dart';

import 'app.dart';

void main() {
  // 10.0.2.2 is the Android emulator's alias for the host machine. Override for a physical
  // device or a deployed environment:
  //   flutter run --dart-define=API_BASE_URL=http://192.168.1.20:3000/api
  const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:3000/api',
  );

  runApp(const PharmaEtApp(apiBaseUrl: apiBaseUrl));
}
