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
  int _selectedIndex = 0;
  List<Map<String, String>> _favoriteApps = [];
  bool _isLoading = true;

  static const String _favAppsPrefsKey = 'favoriteApps';

  @override
  void initState() {
    super.initState();
    _setOrientationPortrait();
    WidgetsBinding.instance.addObserver(this);
    _loadFavoriteApps();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _setOrientationPortrait() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _setOrientationPortrait();
    if (state == AppLifecycleState.resumed) {
      developer.log("MainScaffold resumed");
    }
  }

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
      developer.log(
        "MainScaffold: caricati ${loadedFavorites.length} preferiti da disco.",
      );
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
        setState(() => _isLoading = false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // FIX: _saveFavoriteApps viene chiamato SOLO da _onFavoritesUpdated, che a
  // sua volta viene chiamata solo quando:
  //   1. L'utente tocca la stella esplicitamente.
  //   2. Un'app viene realmente disinstallata (evento package_removed).
  // Mai durante il semplice caricamento/refresh della lista app.
  // ---------------------------------------------------------------------------
  Future<void> _saveFavoriteApps(
    List<Map<String, String>> favoritesToSave,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
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
      developer.log(
        "MainScaffold: salvati ${favoritesToSave.length} preferiti su disco.",
      );
    } catch (e) {
      developer.log(
        "Errore salvataggio preferiti in MainScaffold: $e",
        error: e,
      );
    }
  }

  void _onFavoritesUpdated(List<Map<String, String>> updatedFavorites) {
    if (!mounted) return;
    developer.log(
      "MainScaffold: ricevuti ${updatedFavorites.length} preferiti aggiornati dall'utente.",
    );
    setState(() {
      _favoriteApps = updatedFavorites;
    });
    // Salva immediatamente: questa callback è chiamata solo per azioni utente
    // o disinstallazioni reali, mai per un semplice refresh della lista app.
    _saveFavoriteApps(updatedFavorites);
  }

  void _onItemTapped(int index) {
    if (!mounted) return;
    setState(() {
      _selectedIndex = index;
    });
  }

  Future<bool> _onWillPop() async {
    if (_selectedIndex != 0) {
      setState(() {
        _selectedIndex = 0;
      });
      return false;
    }
    developer.log(
      "WillPopScope: Back button press bloccato su Home (MainScaffold)",
    );
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final List<Widget> widgetOptions = <Widget>[
      HomeScreenContent(favoriteApps: _favoriteApps, isLoading: _isLoading),
      AllAppsScreenContent(
        currentFavorites: List.from(_favoriteApps),
        onFavoritesUpdated: _onFavoritesUpdated,
      ),
    ];

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: theme.colorScheme.background,
        body: IndexedStack(index: _selectedIndex, children: widgetOptions),
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
