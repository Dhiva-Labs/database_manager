import 'package:flutter_test/flutter_test.dart';

import 'package:database_manager/main.dart';

void main() {
  testWidgets('App starts and shows home screen', (tester) async {
    await tester.pumpWidget(const DatabaseManagerApp());
    await tester.pump();
    expect(find.text('Database Manager'), findsOneWidget);
  });
}
