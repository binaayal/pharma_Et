import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_endpoint.dart';
import '../core/payment_accounts.dart';

/// Links out of the app: the public legal pages and the support phone line.
///
/// Both stores require a privacy policy and a way to delete an account to be reachable
/// from inside the app, not only from the store listing (Google Play user-data policy;
/// App Store guideline 5.1.1). The pages live on the public site in both languages.
Uri privacyPolicyUrl(String locale) =>
    Uri.parse('$publicSite/privacy${locale == 'am' ? '#am' : ''}');

Uri deleteAccountUrl(String locale) =>
    Uri.parse('$publicSite/delete-account${locale == 'am' ? '#am' : ''}');

final Uri supportTel = Uri.parse('tel:+251${supportPhone.substring(1)}');

/// Opens [uri] outside the app. A phone with no browser or dialler shows the address instead
/// of failing silently, so the person can still copy it.
Future<void> openLink(BuildContext context, Uri uri) async {
  final opened = await launchUrl(uri, mode: LaunchMode.externalApplication)
      .catchError((_) => false);
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: SelectableText(uri.scheme == 'tel' ? supportPhone : '$uri')));
  }
}
