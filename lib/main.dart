import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PhotoNukeApp());
}

class PhotoNukeApp extends StatelessWidget {
  const PhotoNukeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PhotoNuke',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D0E15),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF2E63),
          secondary: Color(0xFF08D9D6),
          surface: Color(0xFF1A1C28),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF121420),
          elevation: 0,
        ),
      ),
      home: const GalleryNukeScreen(),
    );
  }
}

class DateRangeAnchor {
  final int index;
  final DateTime date;

  DateRangeAnchor({required this.index, required this.date});
}

/// Keeps pagination offsets relative to the current media-store snapshot.
///
/// A page number is not stable after an item before that page is deleted.  The
/// gallery therefore always reloads a longer prefix (starting at zero) when
/// it asks for the next batch.  This small value object keeps that invariant
/// explicit and makes it difficult for a deletion to make us skip an item.
class GalleryPagination {
  GalleryPagination({this.pageSize = 80});

  final int pageSize;
  int totalCount = 0;
  int loadedSourceCount = 0;

  bool get hasMore => loadedSourceCount < totalCount;

  void reset({required int total, required int loaded}) {
    totalCount = max(0, total);
    loadedSourceCount = loaded.clamp(0, totalCount).toInt();
  }

  /// The end offset for the next prefix request.  The start is always zero.
  int get nextPrefixEnd => min(totalCount, loadedSourceCount + pageSize);

  void applySnapshot({required int total, required int loaded}) {
    totalCount = max(0, total);
    loadedSourceCount = loaded.clamp(0, totalCount).toInt();
  }

  void applyDeletionCount(int count) {
    totalCount = max(0, totalCount - count);
    loadedSourceCount = min(loadedSourceCount, totalCount);
  }
}

/// Merge a fresh media-store prefix into the visible list without moving an
/// active tombstone/deletion slot. MediaStore offset pages shift immediately
/// after a deletion, so the visible list must be rebuilt from a prefix rather
/// than appended from a stale page number.
List<T> mergePrefixPreservingTombstones<T>({
  required List<T> fetched,
  required List<T> current,
  required Set<String> stableIds,
  required String Function(T item) idOf,
}) {
  final available = fetched.where((item) => !stableIds.contains(idOf(item)));
  final iterator = available.iterator;
  final merged = <T>[];

  for (final item in current) {
    if (stableIds.contains(idOf(item))) {
      merged.add(item);
    } else if (iterator.moveNext()) {
      merged.add(iterator.current);
    } else {
      break;
    }
  }
  while (iterator.moveNext()) {
    merged.add(iterator.current);
  }
  return merged;
}

DateTime burndownDeadline(DateTime now, Duration duration) => now.add(duration);

DateTime? resetBurndownDeadline({
  required DateTime now,
  required DateTime? deadline,
  required Duration duration,
}) => deadline == null ? null : burndownDeadline(now, duration);

bool isBurndownReady({
  required DateTime now,
  required DateTime? deadline,
  required bool hasActiveNuke,
}) => deadline != null && !now.isBefore(deadline) && !hasActiveNuke;

String formatDateMonthYear(DateTime date) {
  const monthNames = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final month = monthNames[date.month - 1];
  return '$month ${date.year}';
}

String estimateDateForFraction({
  required double fraction,
  required int totalCount,
  required List<DateRangeAnchor> anchors,
  required List<DateTime> loadedDates,
}) {
  if (anchors.isNotEmpty && totalCount > 0) {
    final targetIndex = (fraction * (totalCount - 1)).clamp(0, totalCount - 1);
    DateRangeAnchor closest = anchors.first;
    int minDiff = (closest.index - targetIndex).abs().toInt();

    for (final anchor in anchors) {
      final diff = (anchor.index - targetIndex).abs().toInt();
      if (diff < minDiff) {
        minDiff = diff;
        closest = anchor;
      }
    }
    return formatDateMonthYear(closest.date);
  }

  if (loadedDates.isNotEmpty) {
    final idx = (fraction * (loadedDates.length - 1)).round().clamp(
      0,
      loadedDates.length - 1,
    );
    return formatDateMonthYear(loadedDates[idx]);
  }

  return '';
}

/// MediaStore sort expression mirroring photo_manager's Android 10+ (API 29+)
/// `createDateTime`: `DATE_TAKEN` (ms), or `DATE_ADDED` (s) when `DATE_TAKEN`
/// is NULL/0. Screenshots, messenger images and downloads often have no
/// `DATE_TAKEN`; sorting by the raw column puts them all at the end (SQLite
/// sorts NULL lowest), which made the teleporter jump between years.
const String androidEffectiveDateSortExpression =
    'COALESCE(NULLIF(datetaken, 0), date_added * 1000)';

/// Builds the gallery sort filter ensuring query sort order matches the dates
/// reported by `AssetEntity.createDateTime`, so the list is strictly
/// newest-to-oldest and the teleporter moves predictably back in time.
///
/// On Android, `FilterOptionGroup` orders by `DATE_ADDED` whereas
/// `createDateTime` reads `DATE_TAKEN` (falling back to `DATE_ADDED`) on API
/// 29+, and only `DATE_ADDED` below API 29. The query therefore sorts by the
/// same effective value. `_id` is a stable tiebreaker so equal timestamps keep
/// the same order across the separate range queries used for paging.
///
/// [simpleColumnsOnly] avoids SQL expressions for MediaStore implementations
/// that reject them; it is only used as a fallback.
PMFilter buildGalleryFilterOption({
  bool? isAndroid,
  int? androidSdkInt,
  bool simpleColumnsOnly = false,
}) {
  if (isAndroid ?? Platform.isAndroid) {
    final List<OrderByItem> orderBy;
    if (androidSdkInt != null && androidSdkInt < 29) {
      orderBy = const [OrderByItem.desc('date_added')];
    } else if (simpleColumnsOnly) {
      orderBy = const [
        OrderByItem.desc('datetaken'),
        OrderByItem.desc('date_added'),
      ];
    } else {
      orderBy = const [OrderByItem.desc(androidEffectiveDateSortExpression)];
    }
    return CustomFilter.sql(
      where: '',
      orderBy: [...orderBy, const OrderByItem.desc('_id')],
    );
  }

  return FilterOptionGroup(
    orders: const [
      OrderOption(type: OrderOptionType.createDate, asc: false),
    ],
  );
}

/// Estimates the index of the first visible asset item in the 3-column grid
/// based on the current [scrollOffset] and layout dimensions.
int estimateFirstVisibleGridIndex({
  required double scrollOffset,
  required double gridWidth,
  int crossAxisCount = 3,
  double crossAxisSpacing = 4.0,
  double mainAxisSpacing = 4.0,
  double paddingTop = 4.0,
  double paddingLeft = 4.0,
  double paddingRight = 32.0,
}) {
  final usableWidth = gridWidth - paddingLeft - paddingRight;
  if (usableWidth <= 0) return 0;
  final totalSpacing = (crossAxisCount - 1) * crossAxisSpacing;
  final itemWidth = (usableWidth - totalSpacing) / crossAxisCount;
  if (itemWidth <= 0) return 0;
  final rowHeight = itemWidth;
  final rowStep = rowHeight + mainAxisSpacing;

  final effectiveOffset = (scrollOffset - paddingTop).clamp(0.0, double.infinity);
  final rowIndex = (effectiveOffset / rowStep).floor();
  return rowIndex * crossAxisCount;
}

/// Calculates the normalized scroll fraction (0.0 to 1.0) scaled relative to
/// the collection's [totalCount] rather than currently loaded batch size.
double calculateGalleryScrollFraction({
  required double scrollOffset,
  required double gridWidth,
  required int totalCount,
  int crossAxisCount = 3,
  double crossAxisSpacing = 4.0,
  double mainAxisSpacing = 4.0,
  double paddingTop = 4.0,
  double paddingLeft = 4.0,
  double paddingRight = 32.0,
}) {
  if (totalCount <= 1) return 0.0;
  final firstVisibleIndex = estimateFirstVisibleGridIndex(
    scrollOffset: scrollOffset,
    gridWidth: gridWidth,
    crossAxisCount: crossAxisCount,
    crossAxisSpacing: crossAxisSpacing,
    mainAxisSpacing: mainAxisSpacing,
    paddingTop: paddingTop,
    paddingLeft: paddingLeft,
    paddingRight: paddingRight,
  );
  return (firstVisibleIndex / (totalCount - 1)).clamp(0.0, 1.0);
}

/// Calculates the target scroll offset when teleporting to [targetIndex] in the grid.
double calculateTargetGridScrollOffset({
  required int targetIndex,
  required double gridWidth,
  required double maxScrollExtent,
  int crossAxisCount = 3,
  double crossAxisSpacing = 4.0,
  double mainAxisSpacing = 4.0,
  double paddingTop = 4.0,
  double paddingLeft = 4.0,
  double paddingRight = 32.0,
}) {
  final usableWidth = gridWidth - paddingLeft - paddingRight;
  if (usableWidth <= 0) return 0.0;
  final totalSpacing = (crossAxisCount - 1) * crossAxisSpacing;
  final itemWidth = (usableWidth - totalSpacing) / crossAxisCount;
  if (itemWidth <= 0) return 0.0;
  final rowHeight = itemWidth;
  final rowStep = rowHeight + mainAxisSpacing;

  final targetRow = targetIndex ~/ crossAxisCount;
  final targetOffset = paddingTop + (targetRow * rowStep);
  return targetOffset.clamp(0.0, maxScrollExtent);
}

class GalleryNukeScreen extends StatefulWidget {
  const GalleryNukeScreen({super.key});

  @override
  State<GalleryNukeScreen> createState() => _GalleryNukeScreenState();
}

class _GalleryNukeScreenState extends State<GalleryNukeScreen>
    with WidgetsBindingObserver {
  static const Duration _nukeCountdownDuration = Duration(seconds: 3);

  PermissionState _permissionState = PermissionState.notDetermined;
  bool _isLoading = true;
  List<AssetEntity> _assets = [];

  /// Photos waiting for their three-second countdown to finish.
  final Set<String> _pendingNukeIds = {};

  /// Photos whose platform deletion request is in flight.
  final Set<String> _deletingIds = {};

  /// Deleted photos stay in this set until the burndown reflow removes them.
  final Set<String> _deletedIds = {};
  Timer? _burndownTicker;
  DateTime? _burndownDeadline;
  int _nukedCount = 0;
  bool _hasMore = true;
  bool _isLoadingMore = false;
  AssetPathEntity? _currentPath;
  final GalleryPagination _pagination = GalleryPagination();
  bool _canManageMedia = true;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollAreaKey = GlobalKey();
  int _totalAssetCount = 0;
  int _assetGeneration = 0;
  List<DateRangeAnchor> _dateAnchors = [];
  bool _isDraggingHandle = false;
  double _dragPositionFraction = 0.0;
  String? _hoverDateText;
  bool _isTeleporting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissionAndLoad();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkMediaManagement();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _burndownTicker?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  double get _burndownProgress {
    final deadline = _burndownDeadline;
    if (deadline == null) return 0.0;
    return (deadline.difference(DateTime.now()).inMilliseconds /
            _nukeCountdownDuration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  bool get _hasActiveNuke =>
      _pendingNukeIds.isNotEmpty || _deletingIds.isNotEmpty;

  void _startBurndown() {
    _burndownDeadline = burndownDeadline(
      DateTime.now(),
      _nukeCountdownDuration,
    );
    _burndownTicker ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;

      final deadline = _burndownDeadline;
      if (deadline == null) return;

      if (!isBurndownReady(
        now: DateTime.now(),
        deadline: deadline,
        hasActiveNuke: _hasActiveNuke,
      )) {
        setState(() {});
        return;
      }

      // Do not reflow while a countdown or a platform delete is still active.
      // The next completed delete starts a fresh full burndown.
      if (_hasActiveNuke) {
        setState(() {});
        return;
      }

      _burndownDeadline = null;
      _burndownTicker?.cancel();
      _burndownTicker = null;
      _reflowDeletedAssets();
    });
    if (mounted) setState(() {});
  }

  void _reflowDeletedAssets() {
    if (_deletedIds.isEmpty) return;

    // Keep the old prefix length before reducing the count. If an item from
    // the loaded prefix was deleted, the next item shifts into its slot and
    // must be fetched before we decide that pagination is complete.
    final prefixEndBeforeDeletion = _pagination.loadedSourceCount;
    final removedCount =
        _assets.where((asset) => _deletedIds.contains(asset.id)).length;
    setState(() {
      _assets.removeWhere((asset) => _deletedIds.contains(asset.id));
      _deletedIds.clear();
      _assetGeneration++;
      _pagination.applyDeletionCount(removedCount);
      _totalAssetCount = _pagination.totalCount;
      _hasMore = _pagination.hasMore;
      _dateAnchors = [];
    });
    unawaited(
      _refreshLoadedPrefix(end: prefixEndBeforeDeletion).whenComplete(() {
        unawaited(_precalculateDateAnchors());
      }),
    );
  }

  Future<void> _refreshLoadedPrefix({int? end}) async {
    final path = _currentPath;
    if (path == null || _assets.isEmpty || _pagination.totalCount <= 0) {
      return;
    }

    final generation = _assetGeneration;
    final stableIds = {..._deletedIds, ..._deletingIds};
    final requestedEnd = min(
      _pagination.totalCount,
      max(end ?? _assets.length, _assets.length),
    );

    try {
      final fetched = await path.getAssetListRange(start: 0, end: requestedEnd);
      if (!mounted || generation != _assetGeneration || path != _currentPath) {
        return;
      }

      final refreshed = mergePrefixPreservingTombstones(
        fetched: fetched,
        current: _assets,
        stableIds: stableIds,
        idOf: (asset) => asset.id,
      );
      setState(() {
        _assets = refreshed;
        _pagination.applySnapshot(
          total: _pagination.totalCount,
          loaded:
              fetched.where((asset) => !stableIds.contains(asset.id)).length,
        );
        _hasMore = _pagination.hasMore;
      });
    } catch (e) {
      if (kDebugMode) {
        print('Error refreshing gallery prefix: $e');
      }
    }
  }

  Future<void> _checkMediaManagement() async {
    try {
      final canManage = await PhotoManager.canManageMedia();
      if (mounted) {
        setState(() => _canManageMedia = canManage);
      }
    } catch (_) {
      // Non-Android platforms or errors fall back safely
    }
  }

  Future<void> _requestManageMedia() async {
    try {
      await PhotoManager.requestManageMedia();
      await _checkMediaManagement();
    } catch (_) {}
  }

  Future<void> _requestPermissionAndLoad() async {
    setState(() => _isLoading = true);

    try {
      final state = await PhotoManager.requestPermissionExtend();
      if (!mounted) return;

      setState(() => _permissionState = state);

      if (state.isAuth || state.hasAccess) {
        await _checkMediaManagement();
        await _loadInitialAssets();
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error requesting permission: $e');
      }
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<int?> _androidSdkInt() async {
    if (!Platform.isAndroid) return null;
    try {
      return int.tryParse(await PhotoManager.systemVersion());
    } catch (_) {
      return null;
    }
  }

  Future<(AssetPathEntity, int, List<AssetEntity>)?> _queryGallery(
    PMFilter filter,
  ) async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: filter,
    );
    if (paths.isEmpty) return null;
    final path = paths.first;
    final total = await path.assetCountAsync;
    final assets = await path.getAssetListPaged(page: 0, size: 80);
    return (path, total, assets);
  }

  Future<void> _loadInitialAssets() async {
    try {
      final sdkInt = await _androidSdkInt();
      (AssetPathEntity, int, List<AssetEntity>)? snapshot;
      try {
        snapshot = await _queryGallery(
          buildGalleryFilterOption(androidSdkInt: sdkInt),
        );
      } catch (e) {
        if (!Platform.isAndroid) rethrow;
        if (kDebugMode) {
          print('Effective-date sort rejected, using column sort: $e');
        }
        snapshot = await _queryGallery(
          buildGalleryFilterOption(
            androidSdkInt: sdkInt,
            simpleColumnsOnly: true,
          ),
        );
      }

      if (snapshot == null) {
        if (mounted) {
          setState(() {
            _assets = [];
            _isLoading = false;
          });
        }
        return;
      }

      final (path, total, assets) = snapshot;
      _currentPath = path;
      _assetGeneration++;

      if (mounted) {
        setState(() {
          _totalAssetCount = total;
          _assets = assets;
          _pagination.reset(total: total, loaded: assets.length);
          _hasMore = _pagination.hasMore;
          _isLoading = false;
        });
      }

      // Precalculate date anchors across the collection in background
      _precalculateDateAnchors();
    } catch (e) {
      if (kDebugMode) {
        print('Error loading assets: $e');
      }
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _precalculateDateAnchors() async {
    if (_currentPath == null || _totalAssetCount <= 0) return;
    final path = _currentPath!;
    final generation = _assetGeneration;
    final totalCount = _totalAssetCount;

    try {
      final List<DateRangeAnchor> anchors = [];
      const int samplePoints = 25;
      final Set<int> indicesToFetch = {};

      indicesToFetch.add(0);
      if (_totalAssetCount > 1) {
        indicesToFetch.add(_totalAssetCount - 1);
      }

      for (int i = 1; i < samplePoints; i++) {
        final int targetIndex = (_totalAssetCount * i / samplePoints).round();
        if (targetIndex >= 0 && targetIndex < _totalAssetCount) {
          indicesToFetch.add(targetIndex);
        }
      }

      final sortedIndices = indicesToFetch.toList()..sort();
      for (final index in sortedIndices) {
        final list = await path.getAssetListRange(start: index, end: index + 1);
        if (list.isNotEmpty) {
          anchors.add(
            DateRangeAnchor(index: index, date: list.first.createDateTime),
          );
        }
      }

      if (mounted &&
          anchors.isNotEmpty &&
          generation == _assetGeneration &&
          path == _currentPath &&
          totalCount == _totalAssetCount) {
        setState(() {
          _dateAnchors = anchors;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error precalculating date anchors: $e');
      }
    }
  }

  String _estimateDateForFraction(double fraction) {
    return estimateDateForFraction(
      fraction: fraction,
      totalCount: _totalAssetCount,
      anchors: _dateAnchors,
      loadedDates: _assets.map((a) => a.createDateTime).toList(),
    );
  }

  Future<void> _handleTeleport(double fraction) async {
    if (_totalAssetCount <= 0 && _assets.isEmpty) return;
    setState(() => _isTeleporting = true);
    final generation = _assetGeneration;
    final path = _currentPath;

    try {
      final total = _totalAssetCount > 0 ? _totalAssetCount : _assets.length;
      final targetIndex = (fraction * (total - 1)).round().clamp(0, total - 1);

      if (targetIndex >= _assets.length && path != null) {
        final endItem = min(
          total,
          max(targetIndex + 1, _pagination.loadedSourceCount),
        );

        final fetched = await path.getAssetListRange(start: 0, end: endItem);

        if (mounted && generation == _assetGeneration && path == _currentPath) {
          final stableIds = {..._deletedIds, ..._deletingIds};
          final newAssets = mergePrefixPreservingTombstones(
            fetched: fetched,
            current: _assets,
            stableIds: stableIds,
            idOf: (asset) => asset.id,
          );
          setState(() {
            _assets = newAssets;
            _pagination.applySnapshot(
              total: total,
              loaded:
                  fetched
                      .where((asset) => !stableIds.contains(asset.id))
                      .length,
            );
            _hasMore = _pagination.hasMore;
          });
        }
      }

      if (!mounted) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;

        final RenderBox? box =
            _scrollAreaKey.currentContext?.findRenderObject() as RenderBox?;
        final gridWidth = box?.size.width ?? 360.0;
        final maxScroll = _scrollController.position.maxScrollExtent;
        final targetScroll = calculateTargetGridScrollOffset(
          targetIndex: targetIndex,
          gridWidth: gridWidth,
          maxScrollExtent: maxScroll,
        );
        _scrollController.jumpTo(targetScroll);
      });
    } catch (e) {
      if (kDebugMode) {
        print('Error during teleport: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isTeleporting = false);
      }
    }
  }

  void _onHandlePanStart(DragStartDetails details) {
    final RenderBox? box =
        _scrollAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final localY = box.globalToLocal(details.globalPosition).dy;
    final fraction = (localY / box.size.height).clamp(0.0, 1.0);
    HapticFeedback.selectionClick();

    setState(() {
      _isDraggingHandle = true;
      _dragPositionFraction = fraction;
      _hoverDateText = _estimateDateForFraction(fraction);
    });
  }

  void _onHandlePanUpdate(DragUpdateDetails details) {
    final RenderBox? box =
        _scrollAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final localY = box.globalToLocal(details.globalPosition).dy;
    final fraction = (localY / box.size.height).clamp(0.0, 1.0);
    final newDateText = _estimateDateForFraction(fraction);

    if (newDateText != _hoverDateText) {
      HapticFeedback.selectionClick();
    }

    setState(() {
      _dragPositionFraction = fraction;
      _hoverDateText = newDateText;
    });
  }

  void _onHandlePanEnd(DragEndDetails details) {
    final fraction = _dragPositionFraction;
    setState(() {
      _isDraggingHandle = false;
      _hoverDateText = null;
    });
    _handleTeleport(fraction);
  }

  Future<void> _loadMoreAssets() async {
    if (_isLoadingMore || !_hasMore || _currentPath == null) return;
    _isLoadingMore = true;
    final generation = _assetGeneration;
    final path = _currentPath!;

    try {
      // Never request a later offset page from the old snapshot. Deleting an
      // earlier item shifts every later page and would otherwise skip assets.
      final end = _pagination.nextPrefixEnd;
      final fetched = await path.getAssetListRange(start: 0, end: end);

      if (mounted && generation == _assetGeneration && path == _currentPath) {
        final stableIds = {..._deletedIds, ..._deletingIds};
        final newAssets = mergePrefixPreservingTombstones(
          fetched: fetched,
          current: _assets,
          stableIds: stableIds,
          idOf: (asset) => asset.id,
        );
        setState(() {
          _assets = newAssets;
          _pagination.applySnapshot(
            total: _totalAssetCount,
            loaded:
                fetched.where((asset) => !stableIds.contains(asset.id)).length,
          );
          _hasMore = _pagination.hasMore;
        });
      }
    } finally {
      _isLoadingMore = false;
    }
  }

  void _toggleNukeCountdown(AssetEntity asset) {
    if (_deletingIds.contains(asset.id) || _deletedIds.contains(asset.id)) {
      return;
    }

    if (_pendingNukeIds.contains(asset.id)) {
      HapticFeedback.selectionClick();
      _assetGeneration++;
      setState(() {
        _pendingNukeIds.remove(asset.id);
        _burndownDeadline = resetBurndownDeadline(
          now: DateTime.now(),
          deadline: _burndownDeadline,
          duration: _nukeCountdownDuration,
        );
      });
      return;
    }

    HapticFeedback.selectionClick();
    setState(() => _pendingNukeIds.add(asset.id));
  }

  Future<void> _nukeAsset(AssetEntity asset) async {
    if (!_pendingNukeIds.remove(asset.id) || _deletingIds.contains(asset.id)) {
      return;
    }

    // Trigger the impact only when the countdown actually reaches zero.
    HapticFeedback.heavyImpact();
    // Invalidate any in-flight telemetry/teleport merge. Otherwise a fetch
    // started just before this delete could replace the new tombstone slot.
    _assetGeneration++;
    setState(() => _deletingIds.add(asset.id));

    try {
      // Delete/Trash the asset from the gallery
      final List<String> result = await PhotoManager.editor.deleteWithIds([
        asset.id,
      ]);

      // Keep a black tombstone in the same grid slot until the burndown reflows.
      if (result.contains(asset.id) || result.isNotEmpty) {
        if (mounted) {
          setState(() {
            _deletingIds.remove(asset.id);
            _deletedIds.add(asset.id);
            _nukedCount++;
          });
          _startBurndown();
        }
      } else {
        // User cancelled deletion or platform didn't return id
        if (mounted) {
          setState(() => _deletingIds.remove(asset.id));
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error nuking asset: $e');
      }
      if (mounted) {
        setState(() => _deletingIds.remove(asset.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text(
              'PHOTONUKE',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: 2.0,
                color: Color(0xFFFF2E63),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFFF2E63).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFF2E63), width: 1),
              ),
              child: const Text(
                'TAP TO NUKE',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                  color: Color(0xFFFF2E63),
                ),
              ),
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2132),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF08D9D6), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.local_fire_department,
                  color: Color(0xFF08D9D6),
                  size: 18,
                ),
                const SizedBox(width: 4),
                Text(
                  '$_nukedCount NUKED',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: Color(0xFF08D9D6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF2E63)),
      );
    }

    if (!_permissionState.isAuth && !_permissionState.hasAccess) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.no_photography_outlined,
                size: 72,
                color: Color(0xFFFF2E63),
              ),
              const SizedBox(height: 16),
              const Text(
                'GALLERY ACCESS REQUIRED',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'PhotoNuke needs permission to display your photos and purge targets on tap.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF2E63),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                onPressed: () async {
                  await PhotoManager.openSetting();
                },
                icon: const Icon(Icons.settings),
                label: const Text('OPEN SETTINGS'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _requestPermissionAndLoad,
                child: const Text('RETRY PERMISSION CHECK'),
              ),
            ],
          ),
        ),
      );
    }

    if (_assets.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 64,
              color: Color(0xFF08D9D6),
            ),
            SizedBox(height: 16),
            Text(
              'ALL TARGETS NEUTRALIZED',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'No photos found in gallery. Your device is clean!',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (_burndownDeadline != null)
          SizedBox(
            height: 4,
            width: double.infinity,
            child: LinearProgressIndicator(
              value: _burndownProgress,
              backgroundColor: const Color(0xFF25283A),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFFFF2E63),
              ),
            ),
          ),
        if (!_canManageMedia)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFF2E63).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFF2E63), width: 1),
            ),
            child: Row(
              children: [
                const Icon(Icons.flash_on, color: Color(0xFFFF2E63), size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Instant delete requires Media Management access to bypass confirmation dialogs.',
                    style: TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xFFFF2E63),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _requestManageMedia,
                  child: const Text(
                    'ENABLE',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double handleTrackHeight = max(
                10.0,
                constraints.maxHeight - 48.0,
              );
              final double handleTop = (handleTrackHeight *
                      _dragPositionFraction)
                  .clamp(0.0, handleTrackHeight);

              return Stack(
                key: _scrollAreaKey,
                children: [
                  NotificationListener<ScrollNotification>(
                    onNotification: (scrollInfo) {
                      if (!_isDraggingHandle) {
                        final RenderBox? box =
                            _scrollAreaKey.currentContext?.findRenderObject()
                                as RenderBox?;
                        final gridWidth = box?.size.width ?? constraints.maxWidth;
                        final fraction = calculateGalleryScrollFraction(
                          scrollOffset: scrollInfo.metrics.pixels,
                          gridWidth: gridWidth,
                          totalCount: _totalAssetCount > 0
                              ? _totalAssetCount
                              : _assets.length,
                        );
                        if ((fraction - _dragPositionFraction).abs() > 0.005) {
                          setState(() {
                            _dragPositionFraction = fraction;
                          });
                        }
                      }
                      if (scrollInfo.metrics.pixels >=
                          scrollInfo.metrics.maxScrollExtent - 400) {
                        _loadMoreAssets();
                      }
                      return false;
                    },
                    child: GridView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.only(
                        left: 4,
                        top: 4,
                        bottom: 4,
                        right: 32,
                      ),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 4,
                            mainAxisSpacing: 4,
                          ),
                      itemCount: _assets.length,
                      itemBuilder: (context, index) {
                        final asset = _assets[index];
                        final isPending = _pendingNukeIds.contains(asset.id);
                        final isDeleting = _deletingIds.contains(asset.id);
                        final isDeleted = _deletedIds.contains(asset.id);
                        return PhotoThumbnailTile(
                          key: ValueKey(asset.id),
                          asset: asset,
                          isPending: isPending,
                          isDeleting: isDeleting,
                          isDeleted: isDeleted,
                          onTap: () => _toggleNukeCountdown(asset),
                          onCountdownComplete: () => _nukeAsset(asset),
                        );
                      },
                    ),
                  ),

                  // Floating teleport date label in middle of screen
                  if (_isDraggingHandle && _hoverDateText != null)
                    Center(
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: _isDraggingHandle ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 150),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF121420,
                              ).withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: const Color(0xFF08D9D6),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xFF08D9D6,
                                  ).withValues(alpha: 0.4),
                                  blurRadius: 24,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'TELEPORT TO',
                                  style: TextStyle(
                                    color: Color(0xFFFF2E63),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 2.0,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _hoverDateText!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Right-edge scroll handle touch zone & visual slider
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: 32,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragDown: (details) {
                        _onHandlePanStart(
                          DragStartDetails(
                            globalPosition: details.globalPosition,
                          ),
                        );
                      },
                      onVerticalDragStart: _onHandlePanStart,
                      onVerticalDragUpdate: _onHandlePanUpdate,
                      onVerticalDragEnd: _onHandlePanEnd,
                      onVerticalDragCancel: () {
                        setState(() {
                          _isDraggingHandle = false;
                          _hoverDateText = null;
                        });
                      },
                      child: Stack(
                        children: [
                          // Subtle track line
                          Positioned(
                            right: 4,
                            top: 12,
                            bottom: 12,
                            width: 3,
                            child: Container(
                              decoration: BoxDecoration(
                                color:
                                    _isDraggingHandle
                                        ? const Color(
                                          0xFF08D9D6,
                                        ).withValues(alpha: 0.3)
                                        : Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),

                          // Scroll handle pill
                          Positioned(
                            top: handleTop,
                            right: 2,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              width: _isDraggingHandle ? 14 : 8,
                              height: _isDraggingHandle ? 48 : 36,
                              decoration: BoxDecoration(
                                color:
                                    _isDraggingHandle
                                        ? const Color(0xFFFF2E63)
                                        : const Color(
                                          0xFF08D9D6,
                                        ).withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: [
                                  BoxShadow(
                                    color: (_isDraggingHandle
                                            ? const Color(0xFFFF2E63)
                                            : const Color(0xFF08D9D6))
                                        .withValues(alpha: 0.6),
                                    blurRadius: _isDraggingHandle ? 10 : 4,
                                    spreadRadius: _isDraggingHandle ? 1 : 0,
                                  ),
                                ],
                              ),
                              child:
                                  _isDraggingHandle
                                      ? const Center(
                                        child: Icon(
                                          Icons.unfold_more,
                                          size: 12,
                                          color: Colors.white,
                                        ),
                                      )
                                      : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Loading indicator during jump/teleport
                  if (_isTeleporting)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.3),
                        child: const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF08D9D6),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class PhotoThumbnailTile extends StatefulWidget {
  final AssetEntity asset;
  final bool isPending;
  final bool isDeleting;
  final bool isDeleted;
  final VoidCallback onTap;
  final VoidCallback onCountdownComplete;

  const PhotoThumbnailTile({
    super.key,
    required this.asset,
    required this.isPending,
    required this.isDeleting,
    required this.isDeleted,
    required this.onTap,
    required this.onCountdownComplete,
  });

  @override
  State<PhotoThumbnailTile> createState() => _PhotoThumbnailTileState();
}

class _PhotoThumbnailTileState extends State<PhotoThumbnailTile>
    with TickerProviderStateMixin {
  late final AnimationController _countdownController;
  late final AnimationController _shatterController;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _opacityAnimation;
  Uint8List? _thumbData;
  bool _thumbLoaded = false;

  @override
  void initState() {
    super.initState();
    _countdownController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted && widget.isPending) {
        widget.onCountdownComplete();
      }
    });
    if (widget.isPending) {
      _countdownController.forward();
    }
    _shatterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.35).animate(
      CurvedAnimation(parent: _shatterController, curve: Curves.easeOutBack),
    );

    _opacityAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _shatterController,
        curve: const Interval(0.2, 1.0, curve: Curves.easeIn),
      ),
    );

    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    try {
      final data = await widget.asset.thumbnailDataWithSize(
        const ThumbnailSize(240, 240),
        quality: 85,
      );
      if (mounted) {
        setState(() {
          _thumbData = data;
          _thumbLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _thumbLoaded = true);
      }
    }
  }

  @override
  void didUpdateWidget(covariant PhotoThumbnailTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPending && !oldWidget.isPending) {
      _countdownController.forward(from: 0);
    } else if (!widget.isPending && oldWidget.isPending) {
      _countdownController.stop();
      _countdownController.reset();
    }
    if (widget.isDeleting && !oldWidget.isDeleting) {
      _shatterController.forward();
    } else if (!widget.isDeleting &&
        oldWidget.isDeleting &&
        !widget.isDeleted) {
      _shatterController.reset();
    }
  }

  @override
  void dispose() {
    _countdownController.dispose();
    _shatterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.isDeleting || widget.isDeleted ? null : widget.onTap,
      child: AnimatedBuilder(
        animation: Listenable.merge([_countdownController, _shatterController]),
        builder: (context, child) {
          final isAnimating = widget.isDeleting && _shatterController.value > 0;
          final remainingSeconds =
              (3 - (_countdownController.value * 3).floor()).clamp(1, 3);
          return Transform.scale(
            scale: isAnimating ? _scaleAnimation.value : 1.0,
            child: Opacity(
              opacity: isAnimating ? _opacityAnimation.value : 1.0,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color:
                          widget.isDeleted
                              ? Colors.black
                              : const Color(0xFF1C1E2B),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    clipBehavior: Clip.antiAlias,
                    key:
                        widget.isDeleted
                            ? const ValueKey('deleted-tombstone')
                            : null,
                    child:
                        widget.isDeleted
                            ? const SizedBox.expand()
                            : _thumbData != null
                            ? Image.memory(
                              _thumbData!,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            )
                            : (_thumbLoaded
                                ? const Center(
                                  child: Icon(
                                    Icons.broken_image,
                                    color: Colors.white24,
                                  ),
                                )
                                : const Center(
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFFFF2E63),
                                    ),
                                  ),
                                )),
                  ),
                  if (widget.isPending)
                    Container(
                      key: const ValueKey('nuke-countdown'),
                      color: Colors.black.withValues(alpha: 0.55),
                      child: Center(
                        child: SizedBox(
                          width: 64,
                          height: 64,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: 1.0 - _countdownController.value,
                                strokeWidth: 5,
                                backgroundColor: Colors.white24,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFFFF2E63),
                                ),
                              ),
                              Text(
                                '$remainingSeconds',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (isAnimating)
                    CustomPaint(
                      painter: ShatterPopPainter(
                        progress: _shatterController.value,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class ShatterPopPainter extends CustomPainter {
  final double progress;
  static final List<double> _randomAngles = List.generate(
    12,
    (i) => (i * 2 * pi / 12) + (i % 2 == 0 ? 0.1 : -0.1),
  );

  ShatterPopPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxDist = size.width * 0.7;

    // Flash glow ring
    final glowPaint =
        Paint()
          ..color = const Color(
            0xFFFF2E63,
          ).withValues(alpha: (1.0 - progress).clamp(0.0, 1.0))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * (1.0 - progress);

    canvas.drawCircle(center, (size.width / 2) * progress, glowPaint);

    // Radiating shatter fragments
    for (int i = 0; i < _randomAngles.length; i++) {
      final angle = _randomAngles[i];
      final dist = progress * maxDist * (0.8 + (i % 3) * 0.2);
      final particleCenter = Offset(
        center.dx + cos(angle) * dist,
        center.dy + sin(angle) * dist,
      );

      final particleRadius = (6.0 - progress * 4.0).clamp(1.0, 6.0);
      final particlePaint =
          Paint()
            ..color = (i % 2 == 0
                    ? const Color(0xFFFF2E63)
                    : const Color(0xFF08D9D6))
                .withValues(alpha: (1.0 - progress).clamp(0.0, 1.0))
            ..style = PaintingStyle.fill;

      canvas.drawCircle(particleCenter, particleRadius, particlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant ShatterPopPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
