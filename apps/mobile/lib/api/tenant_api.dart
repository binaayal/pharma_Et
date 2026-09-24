import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../contracts/contracts.dart';

/// The online-only surface of the app: reports, branches and staff, the subscription and
/// its payment proofs, and the anonymous "request an account".
///
/// Separate from `SyncClient` on purpose. Sync is the controlled artifact (`lib/sync/`) and
/// works offline by construction; everything here is a read or a management write that
/// simply needs the network, and failing politely when there is none is the whole job.
class TenantApi {
  TenantApi({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  static const _timeout = Duration(seconds: 20);

  Map<String, String> _headers(String? token) => {
        'content-type': 'application/json',
        'x-contract-version': kContractVersion,
        if (token != null) 'authorization': 'Bearer $token',
      };

  Future<dynamic> _get(String path, String token) async {
    final response = await _client
        .get(Uri.parse('$baseUrl$path'), headers: _headers(token))
        .timeout(_timeout);
    return _decode(response);
  }

  Future<dynamic> _post(String path, Object body, {String? token}) async {
    final response = await _client
        .post(Uri.parse('$baseUrl$path'),
            headers: _headers(token), body: jsonEncode(body))
        .timeout(_timeout);
    return _decode(response);
  }

  dynamic _decode(http.Response response) {
    if (response.statusCode >= 400) {
      throw ApiException(_messageOf(response.body), response.statusCode);
    }
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  static String _messageOf(String body) {
    try {
      final message = (jsonDecode(body) as Map<String, dynamic>)['message'];
      if (message is String && message.isNotEmpty) return message;
      if (message is List && message.isNotEmpty) return message.join(', ');
    } catch (_) {
      // Fall through to a generic message: a raw parse error helps nobody at a counter.
    }
    return 'The server could not do that just now.';
  }

  // --------------------------------------------------------------------- reports

  Future<SalesSummary> salesSummary(String token,
      {required DateTime from, required DateTime to}) async {
    final json = await _get(
        '/reports/sales-summary?from=${from.toUtc().toIso8601String()}'
        '&to=${to.toUtc().toIso8601String()}',
        token) as Map<String, dynamic>;
    return SalesSummary.fromJson(json);
  }

  Future<List<ShiftReport>> cashUps(String token) async {
    final rows = await _get('/reports/cash-up', token) as List<dynamic>;
    return rows
        .map((r) => ShiftReport.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  // ------------------------------------------------------------ branches & staff

  Future<List<BranchInfo>> branches(String token) async {
    final rows = await _get('/branches', token) as List<dynamic>;
    return rows
        .map((r) => BranchInfo.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  Future<BranchInfo> createBranch(String token,
      {required String name, String? address}) async {
    final json = await _post(
        '/branches',
        {
          'name': name,
          if (address != null && address.isNotEmpty) 'address': address,
        },
        token: token) as Map<String, dynamic>;
    return BranchInfo.fromJson(json);
  }

  Future<List<StaffMember>> staff(String token) async {
    final rows = await _get('/users', token) as List<dynamic>;
    return rows
        .map((r) => StaffMember.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  Future<void> inviteStaff(
    String token, {
    required String username,
    required String displayName,
    required String role,
    required String pin,
    required List<String> branchIds,
  }) =>
      _post(
          '/users',
          {
            'username': username,
            'displayName': displayName,
            'role': role,
            'pin': pin,
            'branchIds': branchIds,
          },
          token: token);

  // ---------------------------------------------------------------- subscription

  Future<SubscriptionInfo> subscription(String token) async =>
      SubscriptionInfo.fromJson(
          await _get('/billing/subscription', token) as Map<String, dynamic>);

  /// Uploads the Telebirr / CBE Birr screenshot (Vision §4). Allowed while suspended —
  /// it is the one action that ends a suspension (ADR-016).
  Future<void> submitPaymentProof(
    String token, {
    required List<int> screenshot,
    required String filename,
    required int amountSantim,
    required String note,
  }) async {
    final request = http.MultipartRequest(
        'POST', Uri.parse('$baseUrl/billing/payment-proofs'))
      ..headers['authorization'] = 'Bearer $token'
      ..headers['x-contract-version'] = kContractVersion
      ..fields['amountSantim'] = '$amountSantim'
      ..fields['note'] = note
      // Typed by extension: the server accepts only JPEG, PNG or WebP, and a part sent
      // without a type arrives as application/octet-stream and is refused.
      ..files.add(http.MultipartFile.fromBytes('screenshot', screenshot,
          filename: filename, contentType: imageTypeOf(filename)));
    final streamed = await _client.send(request).timeout(_timeout);
    _decode(await http.Response.fromStream(streamed));
  }

  // --------------------------------------------------------------- onboarding

  /// "Request an account" (ADR-022). Anonymous: it creates a request that a person at the
  /// platform reviews, never an account.
  Future<void> requestAccount({
    required String pharmacyName,
    required String ownerName,
    required String phone,
    required String city,
    required String branchBand,
  }) =>
      _post('/signup-requests', {
        'pharmacyName': pharmacyName,
        'ownerName': ownerName,
        'phone': phone,
        'city': city,
        'branchBand': branchBand,
      });

  void close() => _client.close();
}

/// The media type of a picked image, from its name. Unknown extensions are sent as JPEG,
/// which is what the gallery hands back when it re-encodes.
MediaType imageTypeOf(String filename) {
  final name = filename.toLowerCase();
  if (name.endsWith('.png')) return MediaType('image', 'png');
  if (name.endsWith('.webp')) return MediaType('image', 'webp');
  return MediaType('image', 'jpeg');
}

class ApiException implements Exception {
  ApiException(this.message, this.statusCode);
  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

// ------------------------------------------------------------------- read models

int _int(Object? v) => v == null ? 0 : (v as num).toInt();

class SalesFigures {
  const SalesFigures({
    required this.saleCount,
    required this.grossSantim,
    required this.cashSantim,
    required this.itemsSold,
  });
  factory SalesFigures.fromJson(Map<String, dynamic> j) => SalesFigures(
        saleCount: _int(j['saleCount']),
        grossSantim: _int(j['grossSantim']),
        cashSantim: _int(j['cashSantim']),
        itemsSold: _int(j['itemsSold']),
      );
  final int saleCount;
  final int grossSantim;
  final int cashSantim;
  final int itemsSold;
}

class BranchSales extends SalesFigures {
  const BranchSales({
    required this.branchId,
    required this.branchName,
    required super.saleCount,
    required super.grossSantim,
    required super.cashSantim,
    required super.itemsSold,
  });
  factory BranchSales.fromJson(Map<String, dynamic> j) {
    final f = SalesFigures.fromJson(j);
    return BranchSales(
      branchId: j['branchId'] as String,
      branchName: j['branchName'] as String,
      saleCount: f.saleCount,
      grossSantim: f.grossSantim,
      cashSantim: f.cashSantim,
      itemsSold: f.itemsSold,
    );
  }
  final String branchId;
  final String branchName;
}

class SalesSummary {
  const SalesSummary(
      {required this.branches, required this.total, this.lastSyncedAt});
  factory SalesSummary.fromJson(Map<String, dynamic> j) => SalesSummary(
        branches: (j['branches'] as List<dynamic>)
            .map((b) => BranchSales.fromJson(b as Map<String, dynamic>))
            .toList(),
        total: SalesFigures.fromJson(j['total'] as Map<String, dynamic>),
        lastSyncedAt: j['lastSyncedAt'] == null
            ? null
            : DateTime.parse(j['lastSyncedAt'] as String),
      );
  final List<BranchSales> branches;
  final SalesFigures total;

  /// When the newest record in these figures arrived (BR-8.1: reports state currency).
  final DateTime? lastSyncedAt;
}

class ShiftReport {
  const ShiftReport({
    required this.shiftId,
    required this.branchName,
    required this.userName,
    required this.openedAt,
    required this.closedAt,
    required this.saleCount,
    required this.expectedSantim,
    required this.countedSantim,
    required this.varianceSantim,
    required this.note,
  });
  factory ShiftReport.fromJson(Map<String, dynamic> j) => ShiftReport(
        shiftId: j['shiftId'] as String,
        branchName: (j['branchName'] ?? '') as String,
        userName: (j['userName'] ?? '') as String,
        openedAt: DateTime.parse(j['openedAt'] as String),
        closedAt: j['closedAt'] == null
            ? null
            : DateTime.parse(j['closedAt'] as String),
        saleCount: _int(j['saleCount']),
        expectedSantim: _int(j['serverExpectedSantim']),
        countedSantim:
            j['countedSantim'] == null ? null : _int(j['countedSantim']),
        varianceSantim:
            j['varianceSantim'] == null ? null : _int(j['varianceSantim']),
        note: j['note'] as String?,
      );
  final String shiftId;
  final String branchName;
  final String userName;
  final DateTime openedAt;
  final DateTime? closedAt;
  final int saleCount;
  final int expectedSantim;
  final int? countedSantim;
  final int? varianceSantim;
  final String? note;
}

class BranchInfo {
  const BranchInfo({required this.id, required this.name, this.address});
  factory BranchInfo.fromJson(Map<String, dynamic> j) => BranchInfo(
      id: j['id'] as String,
      name: j['name'] as String,
      address: j['address'] as String?);
  final String id;
  final String name;
  final String? address;
}

class StaffMember {
  const StaffMember({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    required this.branchIds,
  });
  factory StaffMember.fromJson(Map<String, dynamic> j) => StaffMember(
        id: j['id'] as String,
        username: j['username'] as String,
        displayName: j['displayName'] as String,
        role: j['role'] as String,
        branchIds:
            (j['branchIds'] as List<dynamic>? ?? const []).cast<String>(),
      );
  final String id;
  final String username;
  final String displayName;
  final String role;
  final List<String> branchIds;
}

class SubscriptionInfo {
  const SubscriptionInfo({
    required this.state,
    required this.currentPeriodEnd,
    required this.priceSantim,
    required this.suspendedReason,
    required this.daysRemaining,
    required this.pendingProofCount,
  });
  factory SubscriptionInfo.fromJson(Map<String, dynamic> j) => SubscriptionInfo(
        state: (j['state'] ?? 'pending') as String,
        currentPeriodEnd: j['currentPeriodEnd'] == null
            ? null
            : DateTime.parse(j['currentPeriodEnd'] as String),
        priceSantim: _int(j['priceSantim']),
        suspendedReason: j['suspendedReason'] as String?,
        daysRemaining:
            j['daysRemaining'] == null ? null : _int(j['daysRemaining']),
        pendingProofCount: _int(j['pendingProofCount']),
      );
  final String state;
  final DateTime? currentPeriodEnd;
  final int priceSantim;
  final String? suspendedReason;
  final int? daysRemaining;
  final int pendingProofCount;

  bool get suspended => state == 'suspended';
}
