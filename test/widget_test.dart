import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photonuke/main.dart';
import 'package:photo_manager/photo_manager.dart';

AssetEntity testAsset(String id, {int day = 1}) => AssetEntity(
  id: id,
  typeInt: AssetType.image.index,
  width: 100,
  height: 100,
  createDateSecond: DateTime(2026, 11, day).millisecondsSinceEpoch ~/ 1000,
);

void main() {
  test('pagination reloads a prefix instead of using stale page offsets', () {
    final pagination = GalleryPagination(pageSize: 3)
      ..reset(total: 8, loaded: 3);
    expect(pagination.nextPrefixEnd, 6);

    // One item before the unloaded page was deleted. The provider now has
    // seven rows, and the next request must still begin at zero.
    pagination.applyDeletionCount(1);
    expect(pagination.totalCount, 7);
    expect(pagination.nextPrefixEnd, 6);
    expect(pagination.hasMore, isTrue);
  });

  test(
    'prefix merge preserves active tombstone slots and does not duplicate ids',
    () {
      final current = [testAsset('a'), testAsset('b'), testAsset('c')];
      final fetched = [testAsset('b'), testAsset('c'), testAsset('d')];
      final merged = mergePrefixPreservingTombstones(
        current: current,
        fetched: fetched,
        stableIds: {'a'},
        idOf: (asset) => asset.id,
      );
      expect(merged.map((asset) => asset.id), ['a', 'b', 'c', 'd']);
    },
  );

  test('burndown deadline resets and waits for active nukes', () {
    final start = DateTime(2026, 11, 2, 19, 0);
    final first = burndownDeadline(start, const Duration(seconds: 3));
    final second = burndownDeadline(
      start.add(const Duration(seconds: 1)),
      const Duration(seconds: 3),
    );
    expect(second, start.add(const Duration(seconds: 4)));
    expect(
      isBurndownReady(
        now: first.add(const Duration(seconds: 1)),
        deadline: first,
        hasActiveNuke: true,
      ),
      isFalse,
    );
    expect(
      isBurndownReady(
        now: first.add(const Duration(seconds: 1)),
        deadline: first,
        hasActiveNuke: false,
      ),
      isTrue,
    );
  });

  test('cancelling a nuke resets only an active burndown deadline', () {
    final now = DateTime(2026, 11, 2, 19, 0, 1);
    final deadline = now.subtract(const Duration(seconds: 1));

    expect(
      resetBurndownDeadline(
        now: now,
        deadline: deadline,
        duration: const Duration(seconds: 3),
      ),
      now.add(const Duration(seconds: 3)),
    );
    expect(
      resetBurndownDeadline(
        now: now,
        deadline: null,
        duration: const Duration(seconds: 3),
      ),
      isNull,
    );
  });

  testWidgets('countdown renders, second tap cancels, and tombstone renders', (
    tester,
  ) async {
    var completed = 0;
    final asset = testAsset('countdown');
    var pending = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 160,
            child: StatefulBuilder(
              builder: (context, setState) {
                return PhotoThumbnailTile(
                  asset: asset,
                  isPending: pending,
                  isDeleting: false,
                  isDeleted: false,
                  onTap: () => setState(() => pending = false),
                  onCountdownComplete: () => completed++,
                );
              },
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('nuke-countdown')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(completed, 0);

    // A second tap cancels a fresh countdown before its deadline.
    pending = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 160,
            child: StatefulBuilder(
              builder: (context, setState) {
                return PhotoThumbnailTile(
                  asset: asset,
                  isPending: pending,
                  isDeleting: false,
                  isDeleted: false,
                  onTap: () => setState(() => pending = false),
                  onCountdownComplete: () => completed++,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(PhotoThumbnailTile));
    await tester.pump();
    expect(find.byKey(const ValueKey('nuke-countdown')), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(completed, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 160,
            child: PhotoThumbnailTile(
              asset: asset,
              isPending: false,
              isDeleting: false,
              isDeleted: true,
              onTap: () {},
              onCountdownComplete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('deleted-tombstone')), findsOneWidget);
  });

  testWidgets('PhotoNukeApp renders gallery screen smoke test', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PhotoNukeApp());

    // Verify app title and header bar exist
    expect(find.text('PHOTONUKE'), findsOneWidget);
    expect(find.text('TAP TO NUKE'), findsOneWidget);
  });

  group('Scroll handle date estimation unit tests', () {
    test('formatDateMonthYear formats month and year correctly', () {
      final date = DateTime(2024, 7, 15);
      expect(formatDateMonthYear(date), 'Jul 2024');

      final dateDec = DateTime(2021, 12, 1);
      expect(formatDateMonthYear(dateDec), 'Dec 2021');
    });

    test('estimateDateForFraction interpolates with anchors', () {
      final anchors = [
        DateRangeAnchor(index: 0, date: DateTime(2026, 11, 1)),
        DateRangeAnchor(index: 500, date: DateTime(2025, 6, 1)),
        DateRangeAnchor(index: 1000, date: DateTime(2023, 1, 1)),
      ];

      // Top of list (fraction 0.0) -> index 0
      final topDate = estimateDateForFraction(
        fraction: 0.0,
        totalCount: 1001,
        anchors: anchors,
        loadedDates: [],
      );
      expect(topDate, 'Nov 2026');

      // Middle of list (fraction 0.5) -> index 500
      final midDate = estimateDateForFraction(
        fraction: 0.5,
        totalCount: 1001,
        anchors: anchors,
        loadedDates: [],
      );
      expect(midDate, 'Jun 2025');

      // Bottom of list (fraction 1.0) -> index 1000
      final bottomDate = estimateDateForFraction(
        fraction: 1.0,
        totalCount: 1001,
        anchors: anchors,
        loadedDates: [],
      );
      expect(bottomDate, 'Jan 2023');
    });

    test('estimateDateForFraction falls back to loadedDates if no anchors', () {
      final dates = [
        DateTime(2026, 10, 1),
        DateTime(2026, 9, 1),
        DateTime(2026, 8, 1),
      ];

      final topDate = estimateDateForFraction(
        fraction: 0.0,
        totalCount: 0,
        anchors: [],
        loadedDates: dates,
      );
      expect(topDate, 'Oct 2026');

      final bottomDate = estimateDateForFraction(
        fraction: 1.0,
        totalCount: 0,
        anchors: [],
        loadedDates: dates,
      );
      expect(bottomDate, 'Aug 2026');
    });
  });

  group('Issue #16 date sorting and teleport scroll tests', () {
    test('buildGalleryFilterOption configures correct sort column by platform', () {
      final filter = buildGalleryFilterOption();
      if (Platform.isAndroid) {
        expect(filter, isA<CustomFilter>());
        final custom = filter as CustomFilter;
        final child = custom.childMap();
        final orderBy = child['orderBy'] as List;
        expect(orderBy, isNotEmpty);
        expect(orderBy.first['column'], 'datetaken');
        expect(orderBy.first['isAsc'], isFalse);
      } else {
        expect(filter, isA<FilterOptionGroup>());
        final group = filter as FilterOptionGroup;
        expect(group.orders, isNotEmpty);
        expect(group.orders.first.type, OrderOptionType.createDate);
        expect(group.orders.first.asc, isFalse);
      }
    });

    test('estimateFirstVisibleGridIndex calculates correct row and item index', () {
      // 360 width, paddingLeft 4, paddingRight 32 -> usableWidth = 324
      // 3 columns, spacing = 4 -> itemWidth = (324 - 8) / 3 = 105.333
      // rowStep = 105.333 + 4 = 109.333
      // Offset 0 -> item 0
      expect(estimateFirstVisibleGridIndex(scrollOffset: 0, gridWidth: 360), 0);

      // Offset 115 (past row 0) -> row 1 -> item 3
      expect(estimateFirstVisibleGridIndex(scrollOffset: 115, gridWidth: 360), 3);

      // Offset 555 (past row 4) -> row 5 -> item 15
      expect(estimateFirstVisibleGridIndex(scrollOffset: 555, gridWidth: 360), 15);

      // Negative offset clamped to 0
      expect(estimateFirstVisibleGridIndex(scrollOffset: -50, gridWidth: 360), 0);
    });

    test('calculateGalleryScrollFraction scales by totalCount not batch size', () {
      // Library with 1001 items, currently scrolled to row 5 (item 15)
      final fraction = calculateGalleryScrollFraction(
        scrollOffset: 555,
        gridWidth: 360,
        totalCount: 1001,
      );

      // Fraction is item 15 / 1000 = 0.015, NOT 15 / 79 (~0.19)
      expect(fraction, closeTo(0.015, 0.001));

      // At top (offset 0)
      expect(
        calculateGalleryScrollFraction(
          scrollOffset: 0,
          gridWidth: 360,
          totalCount: 1001,
        ),
        0.0,
      );

      // Empty or 1 item collection returns 0.0 safely
      expect(
        calculateGalleryScrollFraction(
          scrollOffset: 100,
          gridWidth: 360,
          totalCount: 0,
        ),
        0.0,
      );
      expect(
        calculateGalleryScrollFraction(
          scrollOffset: 100,
          gridWidth: 360,
          totalCount: 1,
        ),
        0.0,
      );
    });

    test('calculateTargetGridScrollOffset computes accurate scroll position', () {
      // Row 0 starts at paddingTop = 4.0
      expect(
        calculateTargetGridScrollOffset(
          targetIndex: 0,
          gridWidth: 360,
          maxScrollExtent: 2000,
        ),
        4.0,
      );

      // Item 15 is row 5: 4 + 5 * 109.333333 = 550.666666
      expect(
        calculateTargetGridScrollOffset(
          targetIndex: 15,
          gridWidth: 360,
          maxScrollExtent: 2000,
        ),
        closeTo(550.67, 0.1),
      );

      // Clamped to maxScrollExtent
      expect(
        calculateTargetGridScrollOffset(
          targetIndex: 500,
          gridWidth: 360,
          maxScrollExtent: 1000,
        ),
        1000.0,
      );
    });

    testWidgets('Scroll notification updates dragPositionFraction based on total collection size', (
      tester,
    ) async {
      final controller = ScrollController();
      double fraction = 0.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 600,
              child: NotificationListener<ScrollNotification>(
                onNotification: (scrollInfo) {
                  fraction = calculateGalleryScrollFraction(
                    scrollOffset: scrollInfo.metrics.pixels,
                    gridWidth: 360,
                    totalCount: 2001,
                  );
                  return false;
                },
                child: GridView.builder(
                  controller: controller,
                  padding: const EdgeInsets.only(
                    left: 4,
                    top: 4,
                    bottom: 4,
                    right: 32,
                  ),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  itemCount: 80,
                  itemBuilder: (context, index) => Container(key: ValueKey('item_$index')),
                ),
              ),
            ),
          ),
        ),
      );

      // Scroll to row 5 (offset 555)
      controller.jumpTo(555);
      await tester.pump();

      // With totalCount=2001, item 15 should yield fraction ~15/2000 = 0.0075
      expect(fraction, closeTo(15 / 2000, 0.001));
    });
  });
}
