import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/api_endpoint.dart';

void main() {
  // 10.0.2.2 is the Android emulator's alias for the host machine. Override for a physical
  // device or a deployed environment:
  //   flutter run --dart-define=API_BASE_URL=http://192.168.1.20:3000/api
  // A release build must name an https:// server, or it refuses to start (api_endpoint.dart).
  const configured = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:3000/api',
  );

  final apiBaseUrl = resolveApiBaseUrl(configured, release: kReleaseMode);
  publicSite = siteFromApi(apiBaseUrl);
  runApp(PharmaEtApp(apiBaseUrl: apiBaseUrl));
}
