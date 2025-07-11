import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nonno_app/screens/all_apps_screen.dart';
import 'package:nonno_app/screens/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:developer' as developer;

class MainScaffold extends StatefulWidget {
  const MainScaffold({Key? key}) : super(key: key);

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold>
    with WidgetsBindingObserver {
  int _selectedIndex = 0; // Indice del tab selezionato
  List<Map<String, String>> _favoriteApps =
      []; // Stato centralizzato per i preferiti
  bool _isLoading = true; // Flag per caricamento iniziale preferiti

  static const String _favAppsPrefsKey =
      'favoriteApps'; // Chiave SharedPreferences

  @override
  void initState() {
    super.initState();
    _setOrientationPortrait(); // Blocca orientamento
    WidgetsBinding.instance.addObserver(this);
    _loadFavoriteApps(); // Carica i preferiti all'avvio
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Funzione helper per impostare l'orientamento verticale
  void _setOrientationPortrait() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _setOrientationPortrait(); // Riassicura orientamento
    if (state == AppLifecycleState.resumed) {
      // Potresti voler ricaricare i preferiti qui se possono cambiare esternamente
      // _loadFavoriteApps();
      developer.log("MainScaffold resumed");
    }
  }

  // Carica i preferiti da SharedPreferences
  Future<void> _loadFavoriteApps() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_favAppsPrefsKey);
      List<Map<String, String>> loadedFavorites = [];
      if (jsonString != null) {
        final List<dynamic> jsonList = jsonDecode(jsonString);
        loadedFavorites = List<Map<String, String>>.from(
          jsonList
              .map((e) {
                final map = Map<String, dynamic>.from(e);
                return {
                  'appName': map['appName'] as String? ?? 'App',
                  'packageName': map['packageName'] as String? ?? '',
                };
              })
              .where((fav) => fav['packageName']!.isNotEmpty),
        );
      }
      if (mounted) {
        setState(() {
          _favoriteApps = loadedFavorites;
          _isLoading = false;
        });
      }
    } catch (e) {
      developer.log(
        "Errore caricamento preferiti in MainScaffold: $e",
        error: e,
      );
      if (mounted) {
        setState(
          () => _isLoading = false,
        ); // Assicurati di fermare il caricamento anche in caso di errore
      }
    }
  }

  // Salva i preferiti in SharedPreferences
  Future<void> _saveFavoriteApps(
    List<Map<String, String>> favoritesToSave,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Salva solo appName e packageName
      final listToSave =
          favoritesToSave
              .map(
                (fav) => {
                  'appName': fav['appName'],
                  'packageName': fav['packageName'],
                },
              )
              .toList();
      final jsonString = jsonEncode(listToSave);
      await prefs.setString(_favAppsPrefsKey, jsonString);
      developer.log("Preferiti salvati da MainScaffold");
    } catch (e) {
      developer.log(
        "Errore salvataggio preferiti in MainScaffold: $e",
        error: e,
      );
    }
  }

  // Callback chiamata da AllAppsScreenContent quando i preferiti cambiano
  void _onFavoritesUpdated(List<Map<String, String>> updatedFavorites) {
    if (!mounted) return;
    developer.log(
      "MainScaffold: Ricevuti ${updatedFavorites.length} preferiti aggiornati",
    );
    setState(() {
      _favoriteApps = updatedFavorites; // Aggiorna lo stato centrale
    });
    _saveFavoriteApps(updatedFavorites); // Salva immediatamente le modifiche
  }

  // Gestisce il tap sulla BottomNavigationBar
  void _onItemTapped(int index) {
    if (!mounted) return;
    setState(() {
      _selectedIndex = index; // Cambia il tab visualizzato
    });
  }

  // Gestisce il tasto Indietro del sistema
  Future<bool> _onWillPop() async {
    if (_selectedIndex != 0) {
      // Se non siamo sulla schermata Home (indice 0),
      // torna alla schermata Home invece di chiudere l'app.
      setState(() {
        _selectedIndex = 0;
      });
      return false; // Impedisce la chiusura dell'app
    }
    // Se siamo già sulla schermata Home, impedisci comunque la chiusura
    // (comportamento tipico di un launcher)
    developer.log(
      "WillPopScope: Back button press bloccato su Home (MainScaffold)",
    );
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Lista dei widget da mostrare nel body, corrispondenti agli indici dei tab
    final List<Widget> widgetOptions = <Widget>[
      // Contenuto per il Tab 0 (Home)
      HomeScreenContent(
        favoriteApps: _favoriteApps, // Passa lo stato dei preferiti
        isLoading: _isLoading, // Passa lo stato di caricamento
      ),
      // Contenuto per il Tab 1 (Tutte le App)
      AllAppsScreenContent(
        // Passa i preferiti attuali per inizializzare lo stato interno di AllApps
        currentFavorites: List.from(_favoriteApps),
        // Passa la callback per notificare gli aggiornamenti
        onFavoritesUpdated: _onFavoritesUpdated,
      ),
    ];

    return WillPopScope(
      onWillPop: _onWillPop, // Gestisce il tasto back
      child: Scaffold(
        backgroundColor: theme.colorScheme.background,
        // Il body cambia in base all'indice selezionato
        body: IndexedStack(
          // IndexedStack mantiene lo stato dei widget non visibili
          index: _selectedIndex,
          children: widgetOptions,
        ),
        // La BottomNavigationBar è ora gestita qui
        bottomNavigationBar: BottomNavigationBar(
          items: const <BottomNavigationBarItem>[
            BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
            BottomNavigationBarItem(
              icon: Icon(Icons.apps),
              label: 'Tutte le App',
            ),
          ],
          currentIndex: _selectedIndex,
          selectedItemColor: theme.colorScheme.primary,
          unselectedItemColor: Colors.grey[600],
          showUnselectedLabels: false,
          onTap: _onItemTapped,
          type: BottomNavigationBarType.fixed,
        ),
      ),
    );
  }
}
