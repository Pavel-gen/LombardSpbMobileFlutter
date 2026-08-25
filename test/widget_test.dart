import 'package:flutter_test/flutter_test.dart';

import 'package:lombardspb/main.dart';

void main() {
  testWidgets('Landing screen shows main title', (WidgetTester tester) async {
    await tester.pumpWidget(const LombardApp());
    await tester.pump();

    expect(find.text('Ломбард'), findsOneWidget);
  });
}
