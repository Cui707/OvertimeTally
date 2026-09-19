import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'data/overtime_repository.dart';
import 'data/settings_store.dart';
import 'data/sqflite_repository.dart';
import 'pages/home_shell.dart';
import 'providers/overtime_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    OvertimeTallyApp(
      repository: SqfliteOvertimeRepository(),
      settingsStore: JsonFileSettingsStore(),
    ),
  );
}

class OvertimeTallyApp extends StatelessWidget {
  const OvertimeTallyApp({
    super.key,
    required this.repository,
    this.settingsStore,
  });

  final OvertimeRepository repository;
  final SettingsStore? settingsStore;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<OvertimeProvider>(
      create: (_) => OvertimeProvider(
        repository: repository,
        settingsStore: settingsStore,
      )..load(),
      child: MaterialApp(
        title: 'OvertimeTally',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const <Locale>[
          Locale('zh', 'CN'),
          Locale('en', 'US'),
        ],
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.light,
        ),
        home: const HomeShell(),
      ),
    );
  }
}
