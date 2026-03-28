import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nonno_app/native/native_methods.dart';
import 'dart:developer' as developer;

// -----------------------------------------------------------------------------
// Widget AllAppsScreenContent
// Schermata che mostra tutte le app installate, con ricerca e preferiti.
// -----------------------------------------------------------------------------
class AllAppsScreenContent extends StatefulWidget {
  final List<Map<String, String>> currentFavorites;
  final Function(List<Map<String, String>>) onFavoritesUpdated;

  const AllAppsScreenContent({
    Key? key,
    required this.currentFavorites,
    required this.onFavoritesUpdated,
  }) : super(key: key);

  @override
  State<AllAppsScreenContent> createState() => _AllAppsScreenContentState();
}

// -----------------------------------------------------------------------------
// Stato per AllAppsScreenContent
// -----------------------------------------------------------------------------
class _AllAppsScreenContentState extends State<AllAppsScreenContent>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // --- Stato Interno UI & Dati App ---
  List<Map<String, dynamic>> _allAppsWithData = [];
  List<Map<String, dynamic>> _filteredSortedApps = [];
  final TextEditingController _searchController = TextEditingController();
  late Set<String> _favoritePackages;
  Map<String, int> _clickCounts = {};
  bool _isDeleteMode = false;
  bool _isLoading = true;
  late AnimationController _swingController;
  late Animation<double> _swingAnimation;
  final Map<String, String?> _iconPathCache = {};

  // --- Gestione Salvataggio Click Counts Ottimizzato ---
  static const String _clickCountsPrefsKey = 'app_click_counts';
  Timer? _saveClickCountsTimer;
  bool _clickCountsChangedSinceLastSave = false;

  // --- Gestione Ricerca ---
  bool _isSearchLoading = false;
  String _lastSearchQuery = "";
  final _debounceTimer = Debouncer(milliseconds: 400);

  // --- Gestione Eventi Installazione/Rimozione App ---
  static const _packageEventChannel = EventChannel(
    'com.example.nonno_app/package_events',
  );
  StreamSubscription? _packageEventSubscription;

  // ---------------------------------------------------------------------------
  // LIFECYCLE
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Inizializza i preferiti dalla lista passata da MainScaffold.
    // Questa è la fonte di verità persistente — non verrà mai sovrascritta
    // automaticamente durante il caricamento delle app.
    _favoritePackages =
        widget.currentFavorites
            .map((fav) => fav['packageName'] ?? '')
            .where((pkg) => pkg.isNotEmpty)
            .toSet();

    _isLoading = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadInitialData(showLoadingIndicator: false);
      }
    });

    _searchController.addListener(_debounceSearchListener);

    _swingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _swingAnimation = Tween<double>(
      begin: -0.025,
      end: 0.025,
    ).chain(CurveTween(curve: Curves.easeInOut)).animate(_swingController);

    _listenToPackageEvents();

    developer.log(
      "AllAppsScreenContent initState completato",
      name: "AllAppsScreenContent",
    );
  }

  @override
  void dispose() {
    developer.log("AllAppsScreenContent dispose", name: "AllAppsScreenContent");
    WidgetsBinding.instance.removeObserver(this);
    _searchController.removeListener(_debounceSearchListener);
    _searchController.dispose();
    _swingController.dispose();
    _packageEventSubscription?.cancel();
    _debounceTimer.dispose();
    _saveClickCountsTimer?.cancel();
    _saveClickCountsNowIfChanged();
    super.dispose();
  }

  void _debounceSearchListener() {
    final query = _searchController.text.trim();
    _debounceTimer.run(() {
      if (query != _lastSearchQuery) {
        _lastSearchQuery = query;
        _applyFilterAndSort(query);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      developer.log(
        "AllAppsScreenContent resumed, ricarico dati",
        name: "AllAppsScreenContent",
      );
      _loadInitialData(showLoadingIndicator: !_allAppsWithData.isNotEmpty);
    } else if (state == AppLifecycleState.paused) {
      developer.log(
        "AllAppsScreenContent paused, salvo click counts se cambiati",
        name: "AllAppsScreenContent",
      );
      _saveClickCountsNowIfChanged();
    }
  }

  // ---------------------------------------------------------------------------
  // EVENTCHANNEL — Aggiunta/Rimozione App Esterna
  // ---------------------------------------------------------------------------

  void _listenToPackageEvents() {
    _packageEventSubscription?.cancel();
    _packageEventSubscription = _packageEventChannel
        .receiveBroadcastStream()
        .listen(
          _handlePackageEvent,
          onError: (error) {
            developer.log(
              "Errore EventChannel: $error",
              name: "AllAppsScreenContent",
            );
          },
          onDone: () {
            developer.log(
              "EventChannel stream chiuso.",
              name: "AllAppsScreenContent",
            );
          },
        );
    developer.log(
      'In ascolto per eventi pacchetto...',
      name: 'AllAppsScreenContent',
    );
  }

  void _handlePackageEvent(dynamic event) {
    developer.log(
      'Evento pacchetto ricevuto: $event',
      name: 'AllAppsScreenContent',
    );
    if (event is Map) {
      final String eventType = event['event'] ?? '';
      final String? packageName = event['packageName'];

      if (packageName != null && packageName.isNotEmpty) {
        if (eventType == 'package_removed') {
          if (mounted) {
            bool favoriteRemoved = false;
            bool countsRemoved = false;
            setState(() {
              _allAppsWithData.removeWhere(
                (a) => a['packageName'] == packageName,
              );
              _iconPathCache.remove(packageName);

              // ----------------------------------------------------------------
              // FIX: rimuovi il preferito dall'insieme locale. Poiché questo
              // evento viene dall'utente che ha DAVVERO disinstallato l'app,
              // è sicuro rimuoverlo e notificare il padre perché salvi.
              // ----------------------------------------------------------------
              if (_favoritePackages.contains(packageName)) {
                _favoritePackages.remove(packageName);
                favoriteRemoved = true;
              }
              if (_clickCounts.containsKey(packageName)) {
                _clickCounts.remove(packageName);
                countsRemoved = true;
              }
              _applyFilterAndSort(_searchController.text.trim());
            });

            // Salva i preferiti solo se un'app è stata realmente disinstallata
            if (favoriteRemoved) {
              widget.onFavoritesUpdated(getUpdatedFavoritesData());
            }
            if (countsRemoved) {
              _clickCountsChangedSinceLastSave = true;
              _saveClickCountsNowIfChanged();
            }
          }
        } else if (eventType == 'package_added' ||
            eventType == 'package_changed') {
          developer.log(
            'Pacchetto $packageName aggiunto/modificato, ricarico dati.',
            name: 'AllAppsScreenContent',
          );
          _loadInitialData(showLoadingIndicator: _allAppsWithData.isEmpty);
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // CARICAMENTO DATI
  // ---------------------------------------------------------------------------

  Future<void> _loadClickCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_clickCountsPrefsKey);
      if (jsonString != null) {
        final decodedMap = jsonDecode(jsonString) as Map<String, dynamic>;
        _clickCounts = decodedMap.map(
          (key, value) => MapEntry(key, value as int? ?? 0),
        );
      } else {
        _clickCounts = {};
      }
      _clickCountsChangedSinceLastSave = false;
      developer.log("Click counts caricati.", name: "AllAppsScreenContent");
    } catch (e, stacktrace) {
      developer.log(
        "Errore caricamento click counts: $e",
        name: 'AllAppsScreenContent',
        error: e,
        stackTrace: stacktrace,
      );
      _clickCounts = {};
    }
  }

  Future<void> _saveClickCountsNowIfChanged() async {
    if (!_clickCountsChangedSinceLastSave) {
      developer.log(
        "Salvataggio click counts saltato (nessuna modifica).",
        name: "AllAppsScreenContent",
      );
      return;
    }
    developer.log("Salvataggio click counts...", name: "AllAppsScreenContent");
    _saveClickCountsTimer?.cancel();
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(_clickCounts);
      await prefs.setString(_clickCountsPrefsKey, jsonString);
      _clickCountsChangedSinceLastSave = false;
    } catch (e, stacktrace) {
      developer.log(
        "Errore salvataggio click counts: $e",
        name: 'AllAppsScreenContent',
        error: e,
        stackTrace: stacktrace,
      );
    }
  }

  void _scheduleSaveClickCounts() {
    if (!_clickCountsChangedSinceLastSave) return;
    _saveClickCountsTimer?.cancel();
    _saveClickCountsTimer = Timer(const Duration(seconds: 15), () {
      _saveClickCountsNowIfChanged();
    });
  }

  // ---------------------------------------------------------------------------
  // CARICAMENTO INIZIALE
  //
  // FIX PRINCIPALE: la sincronizzazione dei preferiti aggiorna SOLO l'insieme
  // in memoria (_favoritePackages). NON chiama mai onFavoritesUpdated() qui,
  // quindi non scrive mai sui preferiti persistenti durante il caricamento.
  //
  // I preferiti vengono scritti su disco ESCLUSIVAMENTE quando l'utente tocca
  // la stella (_toggleFavorite) oppure quando un'app viene davvero disinstallata
  // (evento package_removed da EventChannel).
  //
  // Questo elimina il bug in cui getInstalledApps() restituisce una lista
  // incompleta (es. YouTube / DAZN con split APK, profilo lavoro, avvio lento)
  // e l'app credeva erroneamente che quei preferiti fossero stati disinstallati.
  // ---------------------------------------------------------------------------
  Future<void> _loadInitialData({bool showLoadingIndicator = true}) async {
    developer.log(
      "Esecuzione _loadInitialData...",
      name: "AllAppsScreenContent",
    );

    try {
      final results = await Future.wait([
        getInstalledApps(),
        _loadClickCounts(),
      ]);

      if (!mounted) return;

      final List<Map<String, String>> apps =
          results[0] as List<Map<String, String>>;

      final List<Map<String, dynamic>> appsWithData =
          apps.map((app) {
            final pkg = app['packageName'] ?? '';
            return {...app, 'clickCount': _clickCounts[pkg] ?? 0};
          }).toList();

      // Pre-fetch dei percorsi delle icone
      final Map<String, String?> currentIconPaths = {};
      List<Future> iconPathFutures = [];
      for (var app in appsWithData) {
        final pkg = app['packageName'] as String?;
        if (pkg != null && pkg.isNotEmpty) {
          iconPathFutures.add(
            getAppIconPath(pkg)
                .then((path) {
                  if (mounted) {
                    currentIconPaths[pkg] = path.isNotEmpty ? path : null;
                  }
                })
                .catchError((e) {
                  developer.log(
                    "Errore getAppIconPath per $pkg: $e",
                    name: "AllAppsScreenContent",
                  );
                  if (mounted) {
                    currentIconPaths[pkg] = null;
                  }
                }),
          );
        }
      }

      await Future.wait(iconPathFutures);
      developer.log("Percorsi icone ottenuti.", name: "AllAppsScreenContent");

      if (!mounted) return;

      setState(() {
        _allAppsWithData = appsWithData;
        _iconPathCache.clear();
        _iconPathCache.addAll(currentIconPaths);

        // ----------------------------------------------------------------
        // FIX: sincronizzazione preferiti SOLO in memoria.
        //
        // Se getInstalledApps() restituisce una lista incompleta (situazione
        // comune con split APK, profilo lavoro, o caricamento lento di Android),
        // NON vogliamo rimuovere definitivamente i preferiti dalla memoria
        // persistente. Aggiorniamo solo _favoritePackages in-memory, senza
        // chiamare onFavoritesUpdated() → nessuna scrittura su disco.
        //
        // La pulizia dei preferiti viene fatta SOLO quando:
        //   1. L'utente tocca la stella esplicitamente (_toggleFavorite).
        //   2. Android segnala una disinstallazione reale (package_removed).
        // ----------------------------------------------------------------
        if (appsWithData.length > 10) {
          // Guarda di sicurezza: se la lista è troppo corta, salta del tutto
          // la pulizia per evitare falsi positivi.
          _favoritePackages.removeWhere(
            (pkg) => !_allAppsWithData.any((app) => app['packageName'] == pkg),
          );
          // NON chiamiamo widget.onFavoritesUpdated() qui.
          // I preferiti rimossi rimarranno assenti dalla UI (nessuna stella
          // visibile) perché l'app non è in _allAppsWithData, ma non verranno
          // cancellati dal disco finché l'utente non torna ad avere l'app
          // installata o non avviene un evento package_removed reale.
        }

        _isLoading = false;
        _applyFilterAndSort(_searchController.text.trim());

        developer.log(
          "Stato aggiornato, _isLoading = false.",
          name: "AllAppsScreenContent",
        );
      });
    } catch (e, s) {
      developer.log(
        "Errore _loadInitialData: $e",
        name: "AllAppsScreenContent",
        stackTrace: s,
      );
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // RICERCA e ORDINAMENTO
  // ---------------------------------------------------------------------------

  void _applyFilterAndSort(String query) {
    if (!mounted) return;
    setState(() => _isSearchLoading = true);

    final lowercaseQuery = query.trim().toLowerCase();
    List<Map<String, dynamic>> filtered;

    if (lowercaseQuery.isEmpty) {
      filtered = List.from(_allAppsWithData);
    } else {
      filtered =
          _allAppsWithData.where((app) {
            final name = (app['appName'] as String? ?? '').toLowerCase();
            final pkg = (app['packageName'] as String? ?? '').toLowerCase();
            return name.contains(lowercaseQuery) ||
                pkg.contains(lowercaseQuery);
          }).toList();
    }

    filtered.sort((a, b) {
      final countA = a['clickCount'] as int? ?? 0;
      final countB = b['clickCount'] as int? ?? 0;
      int compare = countB.compareTo(countA);
      if (compare == 0) {
        final nameA = a['appName'] as String? ?? '';
        final nameB = b['appName'] as String? ?? '';
        compare = nameA.toLowerCase().compareTo(nameB.toLowerCase());
      }
      return compare;
    });

    Future.microtask(() {
      if (mounted) {
        setState(() {
          _filteredSortedApps = filtered;
          _isSearchLoading = false;
        });
      }
    });
  }

  // ---------------------------------------------------------------------------
  // AZIONI UTENTE
  // ---------------------------------------------------------------------------

  /// Unico punto in cui i preferiti vengono scritti su disco: quando
  /// l'utente tocca esplicitamente la stella.
  void _toggleFavorite(Map<String, dynamic> app) {
    final pkg = app['packageName'] as String? ?? '';
    if (pkg.isEmpty || !mounted) return;
    final isFav = _favoritePackages.contains(pkg);

    setState(() {
      if (isFav) {
        _favoritePackages.remove(pkg);
      } else {
        _favoritePackages.add(pkg);
      }
    });

    // Scrittura su disco: avviene solo qui e in _handlePackageEvent (package_removed).
    widget.onFavoritesUpdated(getUpdatedFavoritesData());

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isFav
              ? '"${app['appName']}" rimosso dai preferiti.'
              : '"${app['appName']}" aggiunto ai preferiti.',
        ),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  List<Map<String, String>> getUpdatedFavoritesData() {
    return _allAppsWithData
        .where((app) => _favoritePackages.contains(app['packageName']))
        .map(
          (app) => {
            'appName': app['appName'] as String? ?? 'App',
            'packageName': app['packageName'] as String? ?? '',
          },
        )
        .toList();
  }

  void _toggleDeleteMode() {
    if (!mounted) return;
    setState(() {
      _isDeleteMode = !_isDeleteMode;
      if (_isDeleteMode) {
        _swingController.repeat(reverse: true);
      } else {
        _swingController.stop();
        _swingController.reset();
      }
    });
  }

  void _confirmDeleteApp(Map<String, dynamic> app) {
    final pkg = app['packageName'] as String? ?? '';
    final appName = app['appName'] as String? ?? 'App';
    if (pkg.isEmpty || !mounted) return;

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: Text(
              'Conferma disinstallazione',
              style: TextStyle(color: colorScheme.onSurface),
            ),
            content: Text(
              'Vuoi disinstallare "$appName"?',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Annulla',
                  style: TextStyle(color: colorScheme.primary),
                ),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  developer.log(
                    'Avvio intent disinstallazione per $pkg...',
                    name: 'AllAppsScreenContent',
                  );
                  final success = await uninstallAppByPackage(pkg);
                  if (!success && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Non è stato possibile avviare la disinstallazione di "$appName".',
                        ),
                        backgroundColor: colorScheme.errorContainer,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    developer.log(
                      'Fallimento avvio intent disinstallazione per $pkg',
                    );
                  } else if (success) {
                    developer.log(
                      'Intent disinstallazione per $pkg avviato. In attesa evento package_removed...',
                    );
                  }
                },
                child: Text(
                  'Disinstalla',
                  style: TextStyle(color: colorScheme.error),
                ),
              ),
            ],
          ),
    );
  }

  void _incrementAppClickCount(String packageName) {
    if (packageName.isEmpty || !mounted) return;
    setState(() {
      final currentCount = _clickCounts[packageName] ?? 0;
      _clickCounts[packageName] = currentCount + 1;
      _clickCountsChangedSinceLastSave = true;
      _applyFilterAndSort(_searchController.text.trim());
    });
    _scheduleSaveClickCounts();
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SafeArea(
      child: Column(
        children: [
          // --- Barra di Ricerca e Pulsante Delete ---
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 12.0, 16.0, 4.0),
            child: Row(
              children: [
                Expanded(
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Cerca app...',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon:
                            _searchController.text.isNotEmpty
                                ? IconButton(
                                  icon: const Icon(Icons.clear, size: 20),
                                  tooltip: 'Cancella ricerca',
                                  onPressed: () {
                                    _searchController.clear();
                                    _applyFilterAndSort('');
                                  },
                                )
                                : null,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12.0,
                          horizontal: 12.0,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20.0),
                          borderSide: BorderSide(color: Colors.grey[300]!),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20.0),
                          borderSide: BorderSide(
                            color: theme.primaryColor,
                            width: 1.5,
                          ),
                        ),
                      ),
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (_isSearchLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12.0),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.0),
                    ),
                  )
                else
                  IconButton(
                    icon: Icon(
                      _isDeleteMode
                          ? Icons.delete_forever
                          : Icons.delete_outline,
                      color:
                          _isDeleteMode
                              ? colorScheme.error
                              : colorScheme.onSurfaceVariant,
                    ),
                    tooltip:
                        _isDeleteMode
                            ? 'Termina eliminazione'
                            : 'Modalità eliminazione',
                    onPressed: _toggleDeleteMode,
                  ),
              ],
            ),
          ),
          // --- Lista App o Indicatori di Stato ---
          Expanded(
            child:
                _isLoading
                    ? Center(
                      child: CircularProgressIndicator(
                        color: colorScheme.primary,
                      ),
                    )
                    : _filteredSortedApps.isEmpty && !_isSearchLoading
                    ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32.0),
                        child: Text(
                          _searchController.text.isEmpty
                              ? 'Nessuna applicazione installata.'
                              : 'Nessuna app trovata per "${_searchController.text}".',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                    : ListView.builder(
                      padding: const EdgeInsets.only(
                        top: 8.0,
                        bottom: 16.0,
                        left: 8.0,
                        right: 8.0,
                      ),
                      itemCount: _filteredSortedApps.length,
                      itemBuilder: (context, index) {
                        final app = _filteredSortedApps[index];
                        final pkg = app['packageName'] as String? ?? '';
                        final isFav = _favoritePackages.contains(pkg);
                        final iconPath = _iconPathCache[pkg];

                        return _AppListItem(
                          key: ValueKey(pkg),
                          appData: app,
                          isDeleteMode: _isDeleteMode,
                          isFavorite: isFav,
                          swingAnimation: _swingAnimation,
                          iconPath: iconPath,
                          onToggleFavorite: () => _toggleFavorite(app),
                          onTap: () => _handleAppTap(app),
                          onDelete: () => _confirmDeleteApp(app),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }

  void _handleAppTap(Map<String, dynamic> app) async {
    final pkg = app['packageName'] as String? ?? '';
    if (!_isDeleteMode && pkg.isNotEmpty) {
      final ok = await openAppByPackage(pkg);
      if (ok) {
        _incrementAppClickCount(pkg);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Impossibile aprire "${app['appName']}"'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else if (_isDeleteMode) {
      _confirmDeleteApp(app);
    }
  }
}

// -----------------------------------------------------------------------------
// Widget _AppListItem
// -----------------------------------------------------------------------------
class _AppListItem extends StatelessWidget {
  final Map<String, dynamic> appData;
  final bool isDeleteMode;
  final bool isFavorite;
  final Animation<double> swingAnimation;
  final String? iconPath;
  final VoidCallback onToggleFavorite;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _AppListItem({
    Key? key,
    required this.appData,
    required this.isDeleteMode,
    required this.isFavorite,
    required this.swingAnimation,
    required this.iconPath,
    required this.onToggleFavorite,
    required this.onTap,
    required this.onDelete,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final appName = appData['appName'] as String? ?? 'App Sconosciuta';
    final pkg = appData['packageName'] as String? ?? '';

    Widget iconContent;

    if (iconPath != null && iconPath!.isNotEmpty) {
      iconContent = ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: Image.file(
          File(iconPath!),
          fit: BoxFit.cover,
          width: 48,
          height: 48,
          frameBuilder: (context, child, frame, wasSyncLoaded) {
            if (wasSyncLoaded) return child;
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: child,
            );
          },
          errorBuilder: (context, error, stackTrace) {
            developer.log(
              "Errore Image.file per $pkg ($iconPath): $error",
              name: "AppListItem",
            );
            return Icon(
              Icons.broken_image,
              size: 40,
              color: colorScheme.error.withOpacity(0.7),
            );
          },
        ),
      );
    } else {
      iconContent = Icon(
        Icons.android,
        size: 40,
        color: colorScheme.onSurfaceVariant.withOpacity(0.5),
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 4.0),
      elevation: 0.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
      color: theme.cardColor,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8.0),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child:
                    isDeleteMode
                        ? AnimatedBuilder(
                          animation: swingAnimation,
                          builder:
                              (_, child) => Transform.rotate(
                                angle: swingAnimation.value,
                                child: child,
                              ),
                          child: iconContent,
                        )
                        : iconContent,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        appName,
                        style: textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isDeleteMode) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Tocca per disinstallare',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.error.withOpacity(0.9),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isDeleteMode)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.delete_forever, color: colorScheme.error),
                  tooltip: 'Disinstalla $appName',
                  onPressed: onDelete,
                )
              else
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
                    color:
                        isFavorite
                            ? Colors.amber[600]
                            : colorScheme.onSurfaceVariant.withOpacity(0.7),
                    size: 28,
                  ),
                  tooltip:
                      isFavorite
                          ? 'Rimuovi dai preferiti'
                          : 'Aggiungi ai preferiti',
                  onPressed: onToggleFavorite,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Classe Helper Debouncer
// -----------------------------------------------------------------------------
class Debouncer {
  final int milliseconds;
  Timer? _timer;

  Debouncer({required this.milliseconds});

  run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: milliseconds), action);
  }

  dispose() {
    _timer?.cancel();
  }
}
