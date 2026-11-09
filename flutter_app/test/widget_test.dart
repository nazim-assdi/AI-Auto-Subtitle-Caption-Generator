import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_auto_subtitle_generator/main.dart';

void main() {
  testWidgets('premium creator dashboard renders its main workspace', (tester) async {
    await tester.pumpWidget(const CaptionApp());
    await tester.pumpAndSettle();
    expect(find.text('Create something remarkable.'), findsOneWidget);
    expect(find.text('AI CREATOR'), findsOneWidget);
    expect(find.text('YOUR AI VIDEO WORKSPACE'), findsOneWidget);
    expect(find.text('Create a video'), findsOneWidget);
    expect(find.text('Recent project'), findsOneWidget);
    expect(find.text('Quick actions'), findsOneWidget);
    expect(find.text('PRIVATE BY DESIGN  •  LOCAL AI PROCESSING'), findsOneWidget);
  });

  testWidgets('mobile navigation opens project and export workspaces', (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const CaptionApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create').last);
    await tester.pumpAndSettle();
    expect(find.text('New video project'), findsOneWidget);
    expect(find.text('Choose a video file'), findsOneWidget);

    await tester.tap(find.text('Exports').last);
    await tester.pumpAndSettle();
    expect(find.text('Your export library is empty'), findsOneWidget);
    expect(find.text('Export center'), findsOneWidget);
  });
}
