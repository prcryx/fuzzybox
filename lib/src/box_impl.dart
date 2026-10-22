import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'config_doc.dart';
import 'doc_query.dart';
import 'memory_index.dart';
import 'storage_format.dart';

/// Statistics and health metrics for a [FuzzyBox] instance.
class BoxStats {
  final String boxName;
  final int documentCount;
  final int totalLogRecords;
  final int deadRecords;
  final int fileSizeBytes;
  final bool isCompactionRecommended;

  const BoxStats({
    required this.boxName,
    required this.documentCount,
    required this.totalLogRecords,
    required this.deadRecords,
    required this.fileSizeBytes,
    required this.isCompactionRecommended,
  });

  @override
  String toString() =>
      'BoxStats($boxName: docs=$documentCount, dead=$deadRecords, totalRecords=$totalLogRecords, size=${fileSizeBytes}B)';
}

/// The core [FuzzyBox] implementation.
///
/// Combines synchronous O(1) in-memory key-value lookups with structured
/// multi-tag indexing, lightweight query engine, and crash-safe atomic
/// file persistence via pure Dart standard I/O.
class FuzzyBox {
  final String name;
  final String directoryPath;
  final bool autoCompact;
  final int compactionThreshold;

  final MemoryIndex _index = MemoryIndex();
  final StreamController<void> _changeController =
      StreamController<void>.broadcast();
  final Map<String, StreamController<ConfigDoc?>> _keyControllers = {};

  late final File _storageFile;
  late final File _tempFile;
  RandomAccessFile? _raf;

  int _totalRecords = 0;
  int _deadRecords = 0;
  bool _isClosed = false;
  Future<void>? _ongoingIoOperation;

  FuzzyBox._({
    required this.name,
    required this.directoryPath,
    this.autoCompact = true,
    this.compactionThreshold = 100,
  });

  /// Opens or creates a [FuzzyBox] at [directoryPath]/[name].cdb.
  ///
  /// Replays existing log records, validates CRC32 integrity, recovers from
  /// any prior uncompleted writes, and populates the in-memory index.
  static Future<FuzzyBox> open({
    required String name,
    required String directoryPath,
    bool autoCompact = true,
    int compactionThreshold = 100,
  }) async {
    final box = FuzzyBox._(
      name: name,
      directoryPath: directoryPath,
      autoCompact: autoCompact,
      compactionThreshold: compactionThreshold,
    );
    await box._initialize();
    return box;
  }

  Future<void> _initialize() async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    _storageFile = File('$directoryPath/$name.cdb');
    _tempFile = File('$directoryPath/$name.cdb.tmp');

    // Clean up stale temporary compaction file if left from a previous crash
    if (await _tempFile.exists()) {
      try {
        await _tempFile.delete();
      } catch (_) {}
    }

    if (!await _storageFile.exists()) {
      await _storageFile.create();
      _raf = await _storageFile.open(mode: FileMode.write);
      StorageFormat.writeHeader(_raf!);
      _totalRecords = 0;
      _deadRecords = 0;
    } else {
      _raf = await _storageFile.open(mode: FileMode.append);
      final replay = StorageFormat.replay(_raf!);

      for (final doc in replay.documents.values) {
        _index.put(doc);
      }
      _totalRecords = replay.totalRecords;
      _deadRecords = replay.deadRecords;

      // Ensure file pointer is parked at the end of the file for appending
      await _raf!.setPosition(await _storageFile.length());
    }
  }

  // ===========================================================================
  // Synchronous Key-Value Accessors (O(1) Memory Lookups)
  // ===========================================================================

  /// Returns the document for [key], or null if not found.
  ConfigDoc? getDoc(String key) {
    _checkNotClosed();
    return _index.get(key);
  }

  /// Returns the raw value for [key], or null if not found.
  dynamic get(String key) {
    return getDoc(key)?.value;
  }

  /// Returns a [String] value for [key], falling back to [fallback].
  String getString(String key, [String fallback = '']) {
    final doc = getDoc(key);
    if (doc == null) return fallback;
    return doc.getString(null, fallback);
  }

  /// Returns an [int] value for [key], falling back to [fallback].
  int getInt(String key, [int fallback = 0]) {
    final doc = getDoc(key);
    if (doc == null) return fallback;
    return doc.getInt(null, fallback);
  }

  /// Returns a [double] value for [key], falling back to [fallback].
  double getDouble(String key, [double fallback = 0.0]) {
    final doc = getDoc(key);
    if (doc == null) return fallback;
    return doc.getDouble(null, fallback);
  }

  /// Returns a [bool] value for [key], falling back to [fallback].
  bool getBool(String key, [bool fallback = false]) {
    final doc = getDoc(key);
    if (doc == null) return fallback;
    return doc.getBool(null, fallback);
  }

  /// Returns a [Map<String, dynamic>] value for [key].
  Map<String, dynamic> getMap(String key) {
    final doc = getDoc(key);
    if (doc == null) return <String, dynamic>{};
    return doc.asMap();
  }

  /// Returns a [List<dynamic>] value for [key].
  List<dynamic> getList(String key) {
    final doc = getDoc(key);
    if (doc == null) return <dynamic>[];
    return doc.asList();
  }

  /// Checks if [key] exists in the box.
  bool containsKey(String key) {
    _checkNotClosed();
    return _index.containsKey(key);
  }

  /// All stored document keys.
  Iterable<String> get keys {
    _checkNotClosed();
    return _index.keys;
  }

  /// Total count of active documents.
  int get length {
    _checkNotClosed();
    return _index.length;
  }

  /// Whether the storage box contains zero documents.
  bool get isEmpty => length == 0;

  /// Whether the storage box contains one or more documents.
  bool get isNotEmpty => length > 0;

  // ===========================================================================
  // Mutations with Write-Ahead-Log Persistence
  // ===========================================================================

  /// Puts a document with [key] and [value], with optional [tags] and [schema].
  ///
  /// Updates memory index immediately and appends the framed record to disk.
  Future<ConfigDoc> put(
    String key,
    dynamic value, {
    Iterable<String>? tags,
    String? schema,
  }) async {
    _checkNotClosed();

    final existing = _index.get(key);
    final doc = existing != null
        ? existing.copyWith(value: value, tags: tags, schema: schema)
        : ConfigDoc(key: key, value: value, tags: tags, schema: schema);

    return putDoc(doc);
  }

  /// Persists a fully constructed [ConfigDoc].
  Future<ConfigDoc> putDoc(ConfigDoc doc) async {
    _checkNotClosed();

    final isUpdate = _index.containsKey(doc.key);
    _index.put(doc);

    final encoded = StorageFormat.encodeUpsertRecord(doc);
    await _appendRecord(encoded);

    _totalRecords++;
    if (isUpdate) {
      _deadRecords++;
    }

    _notifyKey(doc.key, doc);
    _notifyGeneralChange();

    _checkAutoCompaction();
    return doc;
  }

  /// Inserts or updates multiple key-value entries.
  Future<void> putAll(Map<String, dynamic> entries) async {
    _checkNotClosed();
    for (final entry in entries.entries) {
      await put(entry.key, entry.value);
    }
  }

  /// Deletes a document by [key]. Returns true if a document was removed.
  Future<bool> delete(String key) async {
    _checkNotClosed();
    if (!_index.containsKey(key)) return false;

    _index.remove(key);

    final encoded = StorageFormat.encodeDeleteRecord(key);
    await _appendRecord(encoded);

    _totalRecords++;
    _deadRecords += 2; // the old doc is dead + the tombstone is dead

    _notifyKey(key, null);
    _notifyGeneralChange();

    _checkAutoCompaction();
    return true;
  }

  /// Deletes multiple documents by key. Returns number of removed documents.
  Future<int> deleteAll(Iterable<String> keys) async {
    _checkNotClosed();
    int count = 0;
    for (final key in keys) {
      if (await delete(key)) {
        count++;
      }
    }
    return count;
  }

  /// Clears all documents and writes an empty snapshot to disk.
  Future<void> clear() async {
    _checkNotClosed();
    _index.clear();

    await compact();

    for (final controller in _keyControllers.values) {
      if (!controller.isClosed) {
        controller.add(null);
      }
    }
    _notifyGeneralChange();
  }

  // ===========================================================================
  // Querying & Tag Indices
  // ===========================================================================

  /// Creates a fluent query builder to filter, sort, and paginate documents.
  DocQuery query() {
    _checkNotClosed();
    return DocQuery(
      documentSource: () => _index.allDocuments,
      changeSignal: _changeController.stream,
    );
  }

  /// Instant secondary tag lookup using the in-memory inverted index.
  List<ConfigDoc> getByTag(String tag) {
    _checkNotClosed();
    return _index.getByTag(tag);
  }

  /// Fast prefix search for key hierarchies (e.g. 'ui.theme.').
  List<ConfigDoc> getByPrefix(String prefix) {
    _checkNotClosed();
    return _index.getByPrefix(prefix);
  }

  // ===========================================================================
  // Reactive Streams
  // ===========================================================================

  /// Returns a reactive [Stream] for a specific document key.
  Stream<ConfigDoc?> watchKey(String key) {
    _checkNotClosed();
    final controller = _keyControllers.putIfAbsent(
      key,
      () => StreamController<ConfigDoc?>.broadcast(
        onListen: () {
          _keyControllers[key]?.add(_index.get(key));
        },
      ),
    );
    return controller.stream;
  }

  /// Returns a broadcast [Stream] that emits whenever any storage change occurs.
  Stream<void> watch() {
    _checkNotClosed();
    return _changeController.stream;
  }

  // ===========================================================================
  // Compaction & Maintenance
  // ===========================================================================

  /// Returns health metrics and storage diagnostics.
  Future<BoxStats> getStats() async {
    _checkNotClosed();
    final fileLength = await _storageFile.length();
    final shouldCompact =
        _deadRecords >= compactionThreshold ||
        (_deadRecords > 50 && _deadRecords >= _index.length);

    return BoxStats(
      boxName: name,
      documentCount: _index.length,
      totalLogRecords: _totalRecords,
      deadRecords: _deadRecords,
      fileSizeBytes: fileLength,
      isCompactionRecommended: shouldCompact,
    );
  }

  /// Compacts the log by writing an atomic snapshot of active documents to a temp
  /// file and atomically renaming it over the main file.
  ///
  /// Eliminates dead records and reclaims mobile disk space without downtime.
  Future<void> compact() async {
    _checkNotClosed();

    await _queueIo(() async {
      // 1. Create and write clean snapshot to temp file
      if (await _tempFile.exists()) {
        await _tempFile.delete();
      }
      final tmpRaf = await _tempFile.open(mode: FileMode.write);
      StorageFormat.writeHeader(tmpRaf);

      // Write each active document as an upsert record
      for (final doc in _index.allDocuments) {
        final encoded = StorageFormat.encodeUpsertRecord(doc);
        tmpRaf.writeFromSync(encoded);
      }
      await tmpRaf.flush();
      await tmpRaf.close();

      // 2. Close current raf handle
      await _raf?.close();
      _raf = null;

      // 3. Atomically rename temp file over current storage file
      await _tempFile.rename(_storageFile.path);

      // 4. Reopen file in append mode
      _raf = await _storageFile.open(mode: FileMode.append);
      _totalRecords = _index.length;
      _deadRecords = 0;
    });
  }

  /// Flushes buffered OS bytes to physical storage.
  Future<void> flush() async {
    _checkNotClosed();
    await _raf?.flush();
  }

  /// Closes the box and releases file handles.
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    await _queueIo(() async {
      await _raf?.flush();
      await _raf?.close();
      _raf = null;
    });

    await _changeController.close();
    for (final controller in _keyControllers.values) {
      await controller.close();
    }
    _keyControllers.clear();
  }

  /// Deletes the box data file from disk completely.
  Future<void> deleteFromDisk() async {
    await close();
    if (await _storageFile.exists()) {
      await _storageFile.delete();
    }
    if (await _tempFile.exists()) {
      await _tempFile.delete();
    }
  }

  // ===========================================================================
  // Internal Helpers
  // ===========================================================================

  void _checkNotClosed() {
    if (_isClosed) {
      throw StateError('FuzzyBox "$name" is closed and cannot be accessed.');
    }
  }

  Future<void> _appendRecord(Uint8List recordBytes) async {
    await _queueIo(() async {
      _raf!.writeFromSync(recordBytes);
      await _raf!.flush();
    });
  }

  void _checkAutoCompaction() {
    if (!autoCompact) return;
    if (_deadRecords >= compactionThreshold ||
        (_deadRecords > 50 && _deadRecords >= _index.length)) {
      // Compact in background without blocking current caller
      scheduleMicrotask(() => compact());
    }
  }

  void _notifyKey(String key, ConfigDoc? doc) {
    final controller = _keyControllers[key];
    if (controller != null && !controller.isClosed) {
      controller.add(doc);
    }
  }

  void _notifyGeneralChange() {
    if (!_changeController.isClosed) {
      _changeController.add(null);
    }
  }

  Future<void> _queueIo(Future<void> Function() action) {
    final prev = _ongoingIoOperation ?? Future.value();
    final completer = Completer<void>();
    _ongoingIoOperation = completer.future;

    prev.then((_) async {
      try {
        await action();
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });

    return completer.future;
  }
}
