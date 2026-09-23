import 'dart:convert';

import 'package:http/http.dart' as http;

import '../contracts/contracts.dart';

/// Thrown when the server could not be reached or refused the request.
///
/// Distinguished from a rejected operation on purpose: a transport failure means "try
/// again later, keep everything", while a rejection means "this specific operation needs a
/// person to look at it".
class SyncTransportException implements Exception {
  SyncTransportException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'SyncTransportException($message)';
}

/// The client half of the SyncService seam (ADR-005).
///
/// Deliberately thin: it speaks HTTP and nothing else. What to send, in what order, and what
/// to do with the answer lives in SyncService — so replacing this transport (ADR-005 keeps
/// that option open for V2 multi-writer) does not touch the durability logic.
class SyncClient {
  SyncClient({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Map<String, String> _headers(String token) => {
        'content-type': 'application/json',
        'authorization': 'Bearer $token',
        // Declares which contract this build speaks, so a server in its N-1 window can
        // serve an old terminal correctly instead of misparsing it (ADR-009).
        'x-contract-version': kContractVersion,
      };

  Future<PushResponse> push({
    required String token,
    required String terminalId,
    required List<Operation> operations,
  }) async {
    final body = jsonEncode({
      'contractVersion': kContractVersion,
      'terminalId': terminalId,
      'operations': operations.map((o) => o.toJson()).toList(),
    });

    late final http.Response response;
    try {
      response = await _client
          .post(Uri.parse('$baseUrl/sync/push'),
              headers: _headers(token), body: body)
          .timeout(const Duration(seconds: 30));
    } catch (error) {
      throw SyncTransportException('push failed: $error');
    }

    if (response.statusCode >= 400) {
      throw SyncTransportException(
        'push rejected: ${response.body}',
        statusCode: response.statusCode,
      );
    }
    return PushResponse.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<PullResponse> pull({
    required String token,
    required int cursor,
    String? branchId,
  }) async {
    final uri = Uri.parse('$baseUrl/sync/pull').replace(queryParameters: {
      'cursor': cursor.toString(),
      if (branchId != null) 'branchId': branchId,
    });

    late final http.Response response;
    try {
      response = await _client
          .get(uri, headers: _headers(token))
          .timeout(const Duration(seconds: 30));
    } catch (error) {
      throw SyncTransportException('pull failed: $error');
    }

    if (response.statusCode >= 400) {
      throw SyncTransportException(
        'pull rejected: ${response.body}',
        statusCode: response.statusCode,
      );
    }
    return PullResponse.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<LoginResponse> login(LoginRequest request) async {
    late final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl/auth/login'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(request.toJson()),
          )
          .timeout(const Duration(seconds: 20));
    } catch (error) {
      throw SyncTransportException('login failed: $error');
    }

    if (response.statusCode >= 400) {
      // A throttle is the one login failure whose server message is worth carrying back
      // verbatim. Every other failure collapses to "invalid credentials" on purpose — a
      // message that distinguished "no such pharmacy" from "wrong PIN" would enumerate real
      // accounts. A 429 leaks nothing by the same reasoning: the server returns it
      // identically for names that exist and names that do not (ADR-017), so it is reached
      // by attempting rather than by guessing.
      if (response.statusCode == 429) {
        throw SyncTransportException(_messageOf(response.body),
            statusCode: 429);
      }
      throw SyncTransportException('invalid credentials',
          statusCode: response.statusCode);
    }
    return LoginResponse.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// The server's own wording, or a usable fallback if the body is not what we expect.
  static String _messageOf(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final message = json['message'];
      if (message is String && message.isNotEmpty) return message;
    } catch (_) {
      // Fall through: a login screen is not the place to surface a parse error.
    }
    return 'Too many sign-in attempts. Wait a few minutes and try again.';
  }

  void close() => _client.close();
}
