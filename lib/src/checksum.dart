import 'dart:convert';

/// Cross-platform deterministic 32-bit FNV-1a state checksum builder (identical on VM, AOT & JS).
final class StateChecksum {
  static const int _offsetBasis = 0x811c9dc5;
  static const int _prime = 0x01000193;

  int _hash = _offsetBasis;

  int get value => _hash;

  void reset() {
    _hash = _offsetBasis;
  }

  void addByte(int byte) {
    _hash = (_hash ^ (byte & 0xff)) & 0xffffffff;
    // Split 16-bit multiplication so result matches exact 32-bit unsigned arithmetic even on 53-bit JS doubles.
    final lo = _hash & 0xffff;
    final hi = (_hash >> 16) & 0xffff;
    final prodLo = lo * _prime;
    final prodHi = ((hi * _prime) & 0xffff) << 16;
    _hash = (prodLo + prodHi) & 0xffffffff;
  }

  void addBool(bool v) => addByte(v ? 1 : 0);

  void addInt32(int v) {
    addByte(v);
    addByte(v >> 8);
    addByte(v >> 16);
    addByte(v >> 24);
  }

  void addQuantizedDouble(double v, {int scale = 1000}) {
    if (v.isNaN) {
      addInt32(0x7fffffff);
      return;
    }
    if (v.isInfinite) {
      addInt32(v.isNegative ? -0x7ffffffe : 0x7ffffffe);
      return;
    }
    addInt32((v * scale).round());
  }

  void addBytes(List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      addByte(bytes[i]);
    }
  }

  void addString(String text) {
    final encoded = utf8.encode(text);
    addInt32(encoded.length);
    addBytes(encoded);
  }

  int finalize() => _hash;

  static int combine(Iterable<int> hashes) {
    final builder = StateChecksum();
    for (final h in hashes) {
      builder.addInt32(h);
    }
    return builder.finalize();
  }
}
