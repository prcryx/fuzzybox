import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'config_doc.dart';

/// File format specification and crash-safe serialization engine.
///
/// Magic Header: 4 bytes ASCII 'DCB1' (0x44, 0x43, 0x42, 0x31)
/// Version: 2 bytes (0x0001)
/// Flags: 2 bytes (bitmask for features/options)
/// Timestamp: 8 bytes (created at in epoch ms)
///
/// Log Record Framing:
/// - 1 byte: Record Type (0x01 = Upsert, 0x02 = Delete/Tombstone, 0x03 = Snapshot)
/// - 4 bytes: Payload length in bytes (Big-Endian uint32)
/// - 4 bytes: CRC32 checksum (Big-Endian uint32) of payload
/// - N bytes: UTF-8 JSON payload
class StorageFormat {
  static const List<int> magicBytes = [0x44, 0x43, 0x42, 0x31]; // 'DCB1'
  static const int currentVersion = 1;

  static const int recordTypeUpsert = 0x01;
  static const int recordTypeDelete = 0x02;
  static const int recordTypeSnapshot = 0x03;

  static const int headerSize = 16;
  static const int recordHeaderSize = 9; // 1 (type) + 4 (length) + 4 (crc32)

  // ===========================================================================
  // Pure Dart CRC32 Implementation (IEEE 802.3 standard)
  // Zero external dependencies needed!
  // ===========================================================================
  static final List<int> _crcTable = _generateCrcTable();

  static List<int> _generateCrcTable() {
    final table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c;
    }
    return table;
  }

  /// Computes a standard 32-bit CRC for the provided bytes.
  static int crc32(List<int> bytes) {
    int c = 0xFFFFFFFF;
    for (final byte in bytes) {
      c = _crcTable[(c ^ byte) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  /// Writes the 16-byte magic header to a new file.
  static void writeHeader(RandomAccessFile raf) {
    raf.setPositionSync(0);
    final header = ByteData(headerSize);
    header.setUint8(0, magicBytes[0]);
    header.setUint8(1, magicBytes[1]);
    header.setUint8(2, magicBytes[2]);
    header.setUint8(3, magicBytes[3]);
    header.setUint16(4, currentVersion);
    header.setUint16(6, 0); // flags
    header.setUint64(8, DateTime.now().millisecondsSinceEpoch);
    raf.writeFromSync(header.buffer.asUint8List());
    raf.flushSync();
  }

  /// Validates the 16-byte header of an existing file.
  static bool isValidHeader(RandomAccessFile raf) {
    if (raf.lengthSync() < headerSize) return false;
    raf.setPositionSync(0);
    final bytes = raf.readSync(headerSize);
    if (bytes.length < headerSize) return false;

    for (int i = 0; i < 4; i++) {
      if (bytes[i] != magicBytes[i]) return false;
    }
    return true;
  }

  /// Encodes a document upsert record into framed binary buffer.
  static Uint8List encodeUpsertRecord(ConfigDoc doc) {
    final jsonStr = doc.toJson();
    final payloadBytes = utf8.encode(jsonStr);
    return _frameRecord(recordTypeUpsert, payloadBytes);
  }

  /// Encodes a tombstone delete record into framed binary buffer.
  static Uint8List encodeDeleteRecord(String key) {
    final payloadBytes = utf8.encode(jsonEncode({'k': key}));
    return _frameRecord(recordTypeDelete, payloadBytes);
  }

  static Uint8List _frameRecord(int type, List<int> payload) {
    final length = payload.length;
    final checksum = crc32(payload);

    final buffer = ByteData(recordHeaderSize + length);
    buffer.setUint8(0, type);
    buffer.setUint32(1, length);
    buffer.setUint32(5, checksum);

    final uint8List = buffer.buffer.asUint8List();
    uint8List.setRange(recordHeaderSize, recordHeaderSize + length, payload);
    return uint8List;
  }

  /// Replays an existing file from disk, verifying CRC integrity and reconstructing state.
  ///
  /// Automatically detects truncated or torn writes at the tail and truncates the file
  /// cleanly back to the last valid atomic record.
  static ReplayResult replay(RandomAccessFile raf) {
    final docs = <String, ConfigDoc>{};
    int totalRecords = 0;
    int deadRecords = 0;

    if (!isValidHeader(raf)) {
      writeHeader(raf);
      return ReplayResult(
        documents: docs,
        totalRecords: 0,
        deadRecords: 0,
        validTailOffset: headerSize,
      );
    }

    int currentPos = headerSize;
    final fileLength = raf.lengthSync();
    raf.setPositionSync(currentPos);

    while (currentPos < fileLength) {
      if (currentPos + recordHeaderSize > fileLength) {
        // Incomplete record header at EOF: truncate torn write
        break;
      }

      final headerBytes = raf.readSync(recordHeaderSize);
      if (headerBytes.length < recordHeaderSize) break;

      final headerView = ByteData.sublistView(headerBytes);
      final type = headerView.getUint8(0);
      final length = headerView.getUint32(1);
      final expectedCrc = headerView.getUint32(5);

      if (currentPos + recordHeaderSize + length > fileLength) {
        // Incomplete payload at EOF: power loss mid-write, stop and truncate
        break;
      }

      final payloadBytes = raf.readSync(length);
      if (payloadBytes.length < length) break;

      // Verify CRC32 checksum
      final actualCrc = crc32(payloadBytes);
      if (actualCrc != expectedCrc) {
        // Corrupted payload! Stop replay here to preserve prior consistent state.
        break;
      }

      totalRecords++;
      final jsonStr = utf8.decode(payloadBytes);

      try {
        if (type == recordTypeUpsert) {
          final doc = ConfigDoc.fromJson(jsonStr);
          if (docs.containsKey(doc.key)) {
            deadRecords++;
          }
          docs[doc.key] = doc;
        } else if (type == recordTypeDelete) {
          final data = jsonDecode(jsonStr) as Map<String, dynamic>;
          final key = data['k'] as String;
          if (docs.remove(key) != null) {
            deadRecords++;
          }
          deadRecords++; // The tombstone itself is also dead after replay
        } else if (type == recordTypeSnapshot) {
          final list = jsonDecode(jsonStr) as List;
          docs.clear();
          for (final item in list) {
            final doc = ConfigDoc.fromMap(item as Map<String, dynamic>);
            docs[doc.key] = doc;
          }
          deadRecords = 0;
          totalRecords = docs.length;
        }
      } catch (_) {
        // Corrupted JSON parse error, stop replay
        break;
      }

      currentPos += recordHeaderSize + length;
    }

    // If file ended with corrupted or partial bytes, truncate to valid offset
    if (currentPos < fileLength) {
      raf.truncateSync(currentPos);
      raf.setPositionSync(currentPos);
    }

    return ReplayResult(
      documents: docs,
      totalRecords: totalRecords,
      deadRecords: deadRecords,
      validTailOffset: currentPos,
    );
  }
}

/// Result returned after replaying the WAL file upon initialization.
class ReplayResult {
  final Map<String, ConfigDoc> documents;
  final int totalRecords;
  final int deadRecords;
  final int validTailOffset;

  const ReplayResult({
    required this.documents,
    required this.totalRecords,
    required this.deadRecords,
    required this.validTailOffset,
  });
}
