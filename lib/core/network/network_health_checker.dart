// lib/core/network/network_health_checker.dart

import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Authoritative real-time network and backend reachability checker.
///
/// Bypasses false positives from:
///  - Wi-Fi or cellular radio connected without internet access.
///  - Captive portals (hotels, hospitals, public Wi-Fi) returning HTTP 200/302 HTML.
///  - Zero-balance cellular data packages where ISP blocks external TCP traffic.
///  - DNS lookup or backend server outages.
class NetworkHealthChecker {
  static final NetworkHealthChecker _instance = NetworkHealthChecker._internal();
  factory NetworkHealthChecker() => _instance;
  NetworkHealthChecker._internal();

  final Connectivity _connectivity = Connectivity();

  /// Primary health endpoint: Dedicated Firebase Cloud Function ping endpoint.
  static final Uri _primaryHealthEndpoint = Uri.parse(
    'https://asia-south1-opd-telemedicine.cloudfunctions.net/pingPresenceHealth',
  );

  /// Fast fallback: Standard HTTP 204 No Content generator.
  static final Uri _fallbackEndpoint = Uri.parse(
    'https://clients3.google.com/generate_204',
  );

  // Short caching to prevent network congestion from multiple simultaneous calls
  bool? _lastCheckResult;
  DateTime? _lastCheckTime;
  static const Duration _cacheDuration = Duration(seconds: 4);

  /// Performs authoritative active internet reachability verification.
  ///
  /// Returns `true` ONLY if real packets travel to and from the backend or verified host.
  Future<bool> hasActiveInternet({bool forceRefresh = false}) async {
    final now = DateTime.now();
    if (!forceRefresh &&
        _lastCheckResult != null &&
        _lastCheckTime != null &&
        now.difference(_lastCheckTime!) < _cacheDuration) {
      return _lastCheckResult!;
    }

    try {
      // 1. Radio interface check (fast fail if offline)
      final connectivityResult = await _connectivity.checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        _cache(false);
        return false;
      }

      // 2. Fast DNS lookup to verify domain resolution
      try {
        final hostLookup = await InternetAddress.lookup('clients3.google.com')
            .timeout(const Duration(milliseconds: 1500));
        if (hostLookup.isEmpty || hostLookup.first.rawAddress.isEmpty) {
          _cache(false);
          return false;
        }
      } on SocketException catch (_) {
        _cache(false);
        return false;
      } on TimeoutException catch (_) {
        // Continue to HTTP attempt in case local DNS cache or direct IP is functional
      }

      // 3. Active HTTP request to verify packet transfer and bypass captive portal redirects
      bool verified = false;

      // Try fallback 204 endpoint first (lowest latency)
      try {
        final response = await http
            .get(_fallbackEndpoint)
            .timeout(const Duration(milliseconds: 2000));
        // A real connection returns 204 No Content. Captive portals return 200 or 302 with HTML
        if (response.statusCode == 204) {
          verified = true;
        }
      } catch (_) {
        // Fall back to primary health endpoint
      }

      if (!verified) {
        try {
          final response = await http
              .get(_primaryHealthEndpoint)
              .timeout(const Duration(milliseconds: 2500));
          if (response.statusCode == 200) {
            verified = true;
          }
        } catch (_) {
          verified = false;
        }
      }

      _cache(verified);
      return verified;
    } catch (e) {
      debugPrint('NetworkHealthChecker error: $e');
      _cache(false);
      return false;
    }
  }

  void _cache(bool result) {
    _lastCheckResult = result;
    _lastCheckTime = DateTime.now();
  }
}
