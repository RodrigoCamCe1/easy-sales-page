// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:easysales_bar/main.dart';

void main() {
  testWidgets('Muestra los controles y valida la instrucción de API key', (tester) async {
    await tester.pumpWidget(const EasySalesBarApp());

    expect(find.byTooltip('Iniciar'), findsOneWidget);
    expect(find.byTooltip('Detener'), findsOneWidget);
    expect(find.byTooltip('Configurar'), findsOneWidget);
    expect(find.text('Presiona iniciar para comenzar'), findsOneWidget);

    await tester.tap(find.byTooltip('Iniciar'));
    await tester.pump();
    expect(find.textContaining('OPENAI_API_KEY'), findsOneWidget);
  });
}
