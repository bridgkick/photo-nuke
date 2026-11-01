import 'package:flutter_test/flutter_test.dart';
import 'package:photonuke/main.dart';

void main() {
  testWidgets('PhotoNukeApp renders gallery screen smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const PhotoNukeApp());

    // Verify app title and header bar exist
    expect(find.text('PHOTONUKE'), findsOneWidget);
    expect(find.text('TAP TO NUKE'), findsOneWidget);
  });
}
