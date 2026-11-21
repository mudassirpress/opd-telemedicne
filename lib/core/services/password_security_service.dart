// lib/core/services/password_security_service.dart

import 'package:bcrypt/bcrypt.dart';
import 'package:flutter/foundation.dart';

/// Central service for secure password hashing and verification using BCrypt.
/// Designed for zero-downtime migration: supports BCrypt-hashed passwords while
/// maintaining seamless backward-compatibility for legacy accounts.
class PasswordSecurityService {
  PasswordSecurityService._();

  /// Default BCrypt work factor (cost). 10 is standard for mobile/web security & performance.
  static const int _defaultRounds = 10;

  /// Hashes a plain-text password using BCrypt with salt rounds.
  static String hashPassword(String plainPassword) {
    if (plainPassword.isEmpty) return '';
    try {
      final salt = BCrypt.gensalt(logRounds: _defaultRounds);
      return BCrypt.hashpw(plainPassword.trim(), salt);
    } catch (e) {
      debugPrint('⚠️ [PasswordSecurityService] BCrypt hash failed: $e');
      return plainPassword.trim();
    }
  }

  /// Verifies whether the entered password matches the stored password.
  /// Seamlessly supports:
  /// 1. BCrypt hashes (`$2a$`, `$2b$`, `$2y$`).
  /// 2. Backward compatibility for legacy plain-text passwords so existing users are NOT locked out.
  static bool verifyPassword(String enteredPassword, String storedPasswordOrHash) {
    final cleanEntered = enteredPassword.trim();
    final cleanStored = storedPasswordOrHash.trim();

    if (cleanEntered.isEmpty || cleanStored.isEmpty) return false;

    // 1. If stored password is a BCrypt hash
    if (isBCryptHash(cleanStored)) {
      try {
        return BCrypt.checkpw(cleanEntered, cleanStored);
      } catch (e) {
        debugPrint('⚠️ [PasswordSecurityService] BCrypt check failed: $e');
        return false;
      }
    }

    // 2. Backward compatibility for legacy plain-text passwords
    return cleanEntered == cleanStored;
  }

  /// Checks if the stored password string is already a BCrypt hash.
  static bool isBCryptHash(String storedPassword) {
    return storedPassword.startsWith(r'$2a$') ||
        storedPassword.startsWith(r'$2b$') ||
        storedPassword.startsWith(r'$2y$');
  }

  /// Returns true if the stored password is an unhashed legacy password that
  /// should be upgraded to BCrypt upon next successful login.
  static bool needsRehash(String storedPassword) {
    return !isBCryptHash(storedPassword.trim());
  }
}

