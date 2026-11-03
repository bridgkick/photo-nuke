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
}
