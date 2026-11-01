/// A controlled error that never includes cookie contents.
class SessionCookieException implements Exception {
  const SessionCookieException();
}

bool isSafeSessionValue(String value) {
  if (value.isEmpty || value.length > 4096) return false;
  return value.codeUnits.every(
    (c) => c > 0x20 && c < 0x7f && ![0x22, 0x2c, 0x3b, 0x5c].contains(c),
  );
}

/// Cookie values are opaque: split at the first equals sign, never decode them.
String? parseSessionCookieHeader(String? header) {
  if (header == null || header.isEmpty) return null;
  if (header.length > 65536) throw const SessionCookieException();
  final values = <String>{};
  for (final part in header.split(';')) {
    final separator = part.indexOf('=');
    if (separator < 0 || part.substring(0, separator).trim() != 'sessionid') {
      continue;
    }
    final value = part.substring(separator + 1).trim();
    if (value.isEmpty) continue;
    if (!isSafeSessionValue(value)) throw const SessionCookieException();
    values.add(value);
  }
  if (values.length > 1) throw const SessionCookieException();
  return values.isEmpty ? null : values.single;
}
