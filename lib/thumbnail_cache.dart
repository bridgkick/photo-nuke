import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int thumbnailCacheMinimumMb = 10;
const int thumbnailCacheMaximumMb = 100;
const int thumbnailCacheDefaultMb = 50;

@immutable
class ThumbnailCacheSnapshot {
  final int usedBytes;
  final int budgetBytes;
  final int cachedFiles;
  final bool isFilling;
  final int fillProgress;
  final int fillTotal;

  const ThumbnailCacheSnapshot({
    required this.usedBytes,
    required this.budgetBytes,
    required this.cachedFiles,
    required this.isFilling,
    required this.fillProgress,
    required this.fillTotal,
  });

  double get usageFraction =>
      budgetBytes == 0 ? 0 : (usedBytes / budgetBytes).clamp(0.0, 1.0);

  ThumbnailCacheSnapshot copyWith({
    int? usedBytes,
    int? budgetBytes,
    int? cachedFiles,
    bool? isFilling,
    int? fillProgress,
    int? fillTotal,
  }) {
    return ThumbnailCacheSnapshot(
      usedBytes: usedBytes ?? this.usedBytes,
      budgetBytes: budgetBytes ?? this.budgetBytes,
      cachedFiles: cachedFiles ?? this.cachedFiles,
      isFilling: isFilling ?? this.isFilling,
      fillProgress: fillProgress ?? this.fillProgress,
      fillTotal: fillTotal ?? this.fillTotal,
    );
  }
}

/// Persistent, local-only storage for the small thumbnails used by the grid.
///
/// Cache population is intentionally newest-first. The gallery supplies an
/// AssetPathEntity whose ordering is newest to oldest, so the first page is
/// always the most useful content to keep when the budget is reached.
class ThumbnailCacheService {
  ThumbnailCacheService._();

  static final ThumbnailCacheService instance = ThumbnailCacheService._();

  static const _budgetKey = 'thumbnail_cache_budget_mb';
  static const _directoryName = 'thumbnail_cache_v1';
  static const _thumbnailSize = ThumbnailSize(240, 240);

  final ValueNotifier<ThumbnailCacheSnapshot> snapshot = ValueNotifier(
    const ThumbnailCacheSnapshot(
      usedBytes: 0,
      budgetBytes: thumbnailCacheDefaultMb * 1024 * 1024,
      cachedFiles: 0,
      isFilling: false,
      fillProgress: 0,
      fillTotal: 0,
    ),
  );

  Future<void>? _initialization;
  Directory? _directory;
  SharedPreferences? _preferences;
  int _usedBytes = 0;
  int _cachedFiles = 0;
  int _fillGeneration = 0;
  Future<void>? _fillFuture;

  Future<void> initialize() {
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    _preferences = await SharedPreferences.getInstance();
    final supportDirectory = await getApplicationSupportDirectory();
    _directory = Directory('${supportDirectory.path}/$_directoryName');
    await _directory!.create(recursive: true);
    final budgetMb =
        _preferences!.getInt(_budgetKey) ?? thumbnailCacheDefaultMb;
    final budgetBytes = _megabytesToBytes(
      budgetMb.clamp(thumbnailCacheMinimumMb, thumbnailCacheMaximumMb),
    );
    await _refreshUsage();
    _publish(budgetBytes: budgetBytes);
    await _enforceBudget();
  }

  Future<Uint8List?> getThumbnail(AssetEntity asset) async {
    await initialize();
    final file = _fileFor(asset.id);
    if (!await file.exists()) return null;

    try {
      // Touch the file so eviction removes the least recently used thumbnails.
      await file.setLastModified(DateTime.now());
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasThumbnail(String assetId) async {
    await initialize();
    return _fileFor(assetId).exists();
  }

  Future<void> storeThumbnail(String assetId, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    await initialize();

    final file = _fileFor(assetId);
    final temporary = File('${file.path}.tmp');
    final existed = await file.exists();
    final previousLength = existed ? await file.length() : 0;
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
      _usedBytes += bytes.length - previousLength;
      if (!existed) _cachedFiles++;
      _publish();
      await _enforceBudget();
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<void> setBudgetMegabytes(int megabytes) async {
    await initialize();
    final value = megabytes.clamp(
      thumbnailCacheMinimumMb,
      thumbnailCacheMaximumMb,
    );
    await _preferences!.setInt(_budgetKey, value);
    _publish(budgetBytes: _megabytesToBytes(value));
    await _enforceBudget();
  }

  Future<void> clear() async {
    await initialize();
    final entries = await _directory!.list().toList();
    for (final entry in entries) {
      if (entry is File && entry.path.endsWith('.thumb')) {
        await entry.delete();
      }
    }
    _usedBytes = 0;
    _cachedFiles = 0;
    _publish();
  }

  void startBackgroundFill(AssetPathEntity path, int totalCount) {
    unawaited(
      initialize().then((_) {
        _fillGeneration++;
        final generation = _fillGeneration;
        _fillFuture = _fillNewestFirst(path, totalCount, generation);
        return _fillFuture!;
      }),
    );
  }

  void stopBackgroundFill() {
    _fillGeneration++;
  }

  Future<void> _fillNewestFirst(
    AssetPathEntity path,
    int totalCount,
    int generation,
  ) async {
    var processed = 0;
    _publish(isFilling: true, fillProgress: 0, fillTotal: totalCount);
    try {
      const pageSize = 40;
      for (var page = 0; page * pageSize < totalCount; page++) {
        if (generation != _fillGeneration) return;
        final assets = await path.getAssetListPaged(page: page, size: pageSize);
        if (assets.isEmpty) break;

        for (final asset in assets) {
          if (generation != _fillGeneration) return;
          if (!await hasThumbnail(asset.id)) {
            final bytes = await asset.thumbnailDataWithSize(
              _thumbnailSize,
              quality: 75,
            );
            if (bytes != null) {
              await storeThumbnail(asset.id, bytes);
            }
          }
          processed++;
          _publish(fillProgress: processed, fillTotal: totalCount);
          // Yield between assets so scrolling and gestures remain responsive.
          await Future<void>.delayed(Duration.zero);
          if (snapshot.value.usedBytes >= snapshot.value.budgetBytes) return;
        }

        if (assets.length < pageSize) break;
      }
    } finally {
      if (generation == _fillGeneration) {
        _publish(isFilling: false, fillProgress: processed);
      }
    }
  }

  Future<void> _refreshUsage() async {
    _usedBytes = 0;
    _cachedFiles = 0;
    await for (final entry in _directory!.list()) {
      if (entry is File && entry.path.endsWith('.thumb')) {
        _usedBytes += await entry.length();
        _cachedFiles++;
      }
    }
  }

  Future<void> _enforceBudget() async {
    final budget = snapshot.value.budgetBytes;
    if (_usedBytes <= budget) {
      _publish();
      return;
    }

    final files = <File>[];
    await for (final entry in _directory!.list()) {
      if (entry is File && entry.path.endsWith('.thumb')) files.add(entry);
    }
    files.sort((a, b) {
      final aModified = a.statSync().modified;
      final bModified = b.statSync().modified;
      return aModified.compareTo(bModified);
    });

    for (final file in files) {
      if (_usedBytes <= budget) break;
      final length = await file.length();
      await file.delete();
      _usedBytes -= length;
      _cachedFiles = (_cachedFiles - 1).clamp(0, _cachedFiles);
    }
    _publish();
  }

  File _fileFor(String assetId) {
    final encoded = base64Url.encode(utf8.encode(assetId)).replaceAll('=', '');
    return File('${_directory!.path}/$encoded.thumb');
  }

  int _megabytesToBytes(int megabytes) => megabytes * 1024 * 1024;

  void _publish({
    int? usedBytes,
    int? budgetBytes,
    int? cachedFiles,
    bool? isFilling,
    int? fillProgress,
    int? fillTotal,
  }) {
    _usedBytes = usedBytes ?? _usedBytes;
    _cachedFiles = cachedFiles ?? _cachedFiles;
    snapshot.value = snapshot.value.copyWith(
      usedBytes: _usedBytes,
      budgetBytes: budgetBytes,
      cachedFiles: _cachedFiles,
      isFilling: isFilling,
      fillProgress: fillProgress,
      fillTotal: fillTotal,
    );
  }
}

String formatCacheBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
