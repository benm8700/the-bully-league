import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Phone normalisation + hashing for "friends from contacts" (2026-11-19).
///
/// MUST match functions/phoneSignup.js `normalizeE164` and
/// functions/contactMatch.js `phoneHash` exactly, or nobody ever matches.
/// The app sends only these hashes to the server - never names, emails or
/// readable numbers.

/// E.164 for a number as typed in an address book, or null. A leading + is
/// trusted; otherwise a bare 10-digit (or 1 + 10-digit) number is taken as
/// US. Anything else is skipped rather than guessed.
String? normalizeE164(String raw) {
  final trimmed = raw.trim();
  final hasPlus = trimmed.startsWith('+');
  final digits = trimmed.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 8 || digits.length > 15) return null;
  if (hasPlus) return '+$digits';
  if (digits.length == 10) return '+1$digits';
  if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
  return null;
}

/// sha256 hex of an E.164 number.
String phoneHash(String e164) => sha256.convert(utf8.encode(e164)).toString();
