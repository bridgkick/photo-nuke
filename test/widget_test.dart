import 'package:flutter_test/flutter_test.dart';
import 'package:photonuke/main.dart';

void main() {
  testWidgets('PhotoNukeApp renders gallery screen smoke test', (WidgetTester tester) async {
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
