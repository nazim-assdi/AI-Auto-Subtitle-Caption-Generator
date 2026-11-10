import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_auto_subtitle_generator/main.dart';

void main() {
  testWidgets('premium creator dashboard renders its main workspace', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const CaptionApp());
    await tester.pumpAndSettle();

    expect(find.text('Create something remarkable.'), findsOneWidget);
    expect(find.text('AI CREATOR'), findsOneWidget);
    expect(find.text('YOUR AI VIDEO WORKSPACE'), findsOneWidget);
    expect(find.text('Create a video'), findsOneWidget);
    expect(find.text('Recent project'), findsOneWidget);
    expect(find.text('Quick actions'), findsOneWidget);
    expect(find.text('PRIVATE BY DESIGN  •  LOCAL AI PROCESSING'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile navigation opens Create, Export and Settings without overflow', (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const CaptionApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create').last);
    await tester.pumpAndSettle();
    expect(find.text('New video project'), findsOneWidget);
    expect(find.text('Add your source video'), findsOneWidget);
    expect(find.text('CAPTION APPEARANCE'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Exports').last);
    await tester.pumpAndSettle();
    expect(find.text('Your asset library is ready'), findsOneWidget);
    expect(find.text('Export center'), findsAtLeastNWidgets(2));
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    expect(find.text('AI processing service'), findsOneWidget);
    expect(find.text('BACKEND ENDPOINT'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
