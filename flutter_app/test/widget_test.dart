import 'package:flutter_test/flutter_test.dart';
import 'package:ai_auto_subtitle_generator/main.dart';

void main() {
  testWidgets('app displays the AI subtitle generator home screen', (tester) async {
    await tester.pumpWidget(const CaptionApp());
    expect(find.text('AI Auto-Subtitle Generator'), findsOneWidget);
    expect(find.text('ভিডিও নির্বাচন করুন'), findsOneWidget);
  });
}
