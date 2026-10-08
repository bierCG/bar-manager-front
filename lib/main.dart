import 'package:flutter/material.dart';

import 'telas/tela_login.dart';
import 'telas/tela_barman.dart';
import 'telas/tela_cozinha.dart';
import 'telas/tela_pontovisual.dart';

void main() {
  runApp(
    MaterialApp(
      title: 'Sistema de Pedidos Maneiro',
      debugShowCheckedModeBanner: false,

      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          elevation: 0,
          centerTitle: true,
        ),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF5722),
          surface: Color(0xFF1E1E1E),
        ),
      ),

      initialRoute: '/',
      routes: {
        '/': (context) => const TelaLogin(),
        '/barman': (context) => const TelaBarman(),
        '/cozinha': (context) => const TelaCozinha(),
        '/pontovisual': (context) => const PontoVisual(),
      },
    ),
  );
}