import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DatabaseManagerApp());
}

class DatabaseManagerApp extends StatelessWidget {
  const DatabaseManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme:
              ColorScheme.fromSeed(seedColor: Colors.teal, brightness: b),
          useMaterial3: true,
          visualDensity: VisualDensity.compact,
        );
    return MaterialApp(
      title: 'Database Manager',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
