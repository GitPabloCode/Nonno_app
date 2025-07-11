import 'package:flutter/material.dart';
import 'package:provider/provider.dart'; // Importa provider
import 'screens/main_scaffold.dart';
import 'providers/theme_notifier.dart'; // Importa il tuo notifier

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Non è necessario caricare il tema qui, lo farà il Notifier stesso

  // Esegui l'app, fornendo il ThemeNotifier all'albero dei widget
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeNotifier(), // Crea l'istanza del notifier
      child: const MyApp(), // Il resto dell'app sarà figlio del provider
    ),
  );
}

// MyApp ora deve ascoltare il ThemeNotifier per applicare il tema
class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Guarda (watch) il ThemeNotifier per ottenere la themeMode corrente
    // Quando il notifier chiama notifyListeners(), questo widget si ricostruirà
    final themeNotifier = context.watch<ThemeNotifier>();

    return MaterialApp(
      title: 'Nonno App',

      // *** IMPOSTAZIONI TEMA ***
      themeMode: themeNotifier.themeMode, // Usa la modalità dal notifier
      // TEMA CHIARO (Light Theme)
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light, // Specifica luminosità chiara
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal, // Colore seme per generare palette chiara
          brightness: Brightness.light,
        ),
        fontFamily: 'Roboto', // Assumendo che tu abbia incluso Roboto
        appBarTheme: AppBarTheme(
          // Stili AppBar per tema chiaro
          backgroundColor: Colors.teal[700],
          foregroundColor: Colors.white,
          elevation: 4.0,
          centerTitle: true,
        ),
        cardTheme: CardTheme(
          // Esempio stile Card chiaro
          elevation: 0.5,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8.0),
          ),
          // color: Colors.white, // Potrebbe essere generato da colorScheme
          clipBehavior: Clip.antiAlias,
        ),
        // Definisci altri stili specifici per il tema chiaro se necessario
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),

      // TEMA SCURO (Dark Theme)
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark, // Specifica luminosità scura
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal, // Usa lo stesso seme ma genera palette scura
          brightness: Brightness.dark,
        ),
        fontFamily: 'Roboto', // Usa lo stesso font
        appBarTheme: AppBarTheme(
          // Stili AppBar per tema scuro (potrebbero differire)
          backgroundColor: Colors.teal[800], // Leggermente diverso?
          foregroundColor: Colors.white,
          elevation: 4.0,
          centerTitle: true,
        ),
        cardTheme: CardTheme(
          // Esempio stile Card scuro
          elevation: 1, // Magari un'ombra leggermente diversa
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8.0),
          ),
          // Il colore sarà generato scuro da colorScheme
          clipBehavior: Clip.antiAlias,
        ),
        // Definisci altri stili specifici per il tema scuro (es. colori testo/icone)
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),

      home: const MainScaffold(),
      debugShowCheckedModeBanner: false,
    );
  }
}
