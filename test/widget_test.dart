import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easysales_bar/ui/recording_bar.dart';

void main() {
  setUpAll(() async {
    await dotenv.load(fileName: '.env');
  });

  testWidgets('Renderiza controles principales y permite iniciar',
      (tester) async {
    await tester.pumpWidget(const RecordingBarApp());

    expect(find.byTooltip('Iniciar'), findsOneWidget);
    expect(find.byTooltip('Detener'), findsOneWidget);
    expect(find.byTooltip('Configurar'), findsOneWidget);

    await tester.tap(find.byTooltip('Iniciar'));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
