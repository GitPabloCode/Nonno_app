import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Chiave per salvare la preferenza del tema
const String _themePrefsKey = 'app_theme_mode';

class ThemeNotifier extends ChangeNotifier {
  late ThemeMode _themeMode;
  SharedPreferences? _prefs;

  // Costruttore: imposta un default e avvia il caricamento
  ThemeNotifier() {
    // Inizia con il tema di sistema come default temporaneo
    _themeMode = ThemeMode.system;
    // Avvia il caricamento asincrono della preferenza salvata
    _loadThemePreference();
  }

  // Getter per ottenere la modalità corrente
  ThemeMode get themeMode => _themeMode;

  // Carica la preferenza salvata da SharedPreferences
  Future<void> _loadThemePreference() async {
    _prefs = await SharedPreferences.getInstance();
    // Leggi la stringa salvata (es. 'light', 'dark', 'system')
    final String? savedTheme = _prefs?.getString(_themePrefsKey);

    // Converti la stringa in ThemeMode
    switch (savedTheme) {
      case 'light':
        _themeMode = ThemeMode.light;
        break;
      case 'dark':
        _themeMode = ThemeMode.dark;
        break;
      case 'system':
      default: // Se non salvato o valore non riconosciuto, usa system
        _themeMode = ThemeMode.system;
        break;
    }
    // Notifica ai listener (come MaterialApp) che il tema potrebbe essere cambiato
    notifyListeners();
  }

  // Imposta una nuova modalità tema e salva la preferenza
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return; // Non fare nulla se la modalità è la stessa

    _themeMode = mode;
    // Notifica subito i listener per aggiornare la UI
    notifyListeners();

    // Salva la preferenza come stringa
    String themeString;
    switch (mode) {
      case ThemeMode.light:
        themeString = 'light';
        break;
      case ThemeMode.dark:
        themeString = 'dark';
        break;
      case ThemeMode.system:
        themeString = 'system';
        break;
    }
    // Attendi che le SharedPreferences siano pronte (se non lo sono già)
    _prefs ??= await SharedPreferences.getInstance();
    // Salva la stringa
    await _prefs?.setString(_themePrefsKey, themeString);
  }

  // Metodo helper per alternare tra chiaro e scuro (ignora system)
  Future<void> toggleTheme() async {
    final newMode =
        _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    await setThemeMode(newMode);
  }
}
