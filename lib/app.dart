import 'package:flutter/material.dart';

import 'ui/home_screen.dart';

class AsesoriaApp extends StatelessWidget {
  const AsesoriaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5CB2FF),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AsesorIA',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF0B0C10),
        fontFamily: 'Segoe UI',
      ),
      home: const HomeScreen(),
    );
  }
}
