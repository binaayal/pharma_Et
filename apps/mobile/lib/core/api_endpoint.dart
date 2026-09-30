/// The server this build talks to, and the rule that it is HTTPS (docs/engineering/security.md).
///
/// A release build carries PINs, session tokens and every sale over this connection. It is
/// set at build time (`--dart-define=API_BASE_URL=…`), and a release built against a plain
/// `http://` URL — a forgotten flag, a copy-pasted dev command — would send all of that in
/// clear text over café Wi-Fi. So a release build refuses to start with one: a crash on the
/// first launch is found by whoever tests the build, while cleartext is found by nobody.
///
/// Debug builds may use HTTP, because the developer's API on the LAN has no certificate.
String resolveApiBaseUrl(String configured, {required bool release}) {
  final uri = Uri.tryParse(configured);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw StateError('API_BASE_URL is not a URL: "$configured"');
  }
  if (release && uri.scheme != 'https') {
    throw StateError(
        'A release build must talk to its server over HTTPS; API_BASE_URL is "$configured". '
        'Build with --dart-define=API_BASE_URL=https://…');
  }
  return configured.endsWith('/')
      ? configured.substring(0, configured.length - 1)
      : configured;
}

/// The public website — the same origin as the API, which serves the console and the legal
/// pages (docs/03 §7). Set once at startup from the API URL.
String publicSite = 'https://pharmaet-staging.fly.dev';

/// `https://host/api` → `https://host`.
String siteFromApi(String apiBaseUrl) {
  final uri = Uri.parse(apiBaseUrl);
  return uri
      .replace(path: '', query: null, fragment: null)
      .toString()
      .replaceAll(RegExp(r'/$'), '');
}
