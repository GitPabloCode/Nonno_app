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
// -----------------------------------------------------------------------------
class AllAppsScreenContent extends StatefulWidget {
  final List<Map<String, String>> currentFavorites;
  final Function(List<Map<String, String>>) onFavoritesUpdated;

  const AllAppsScreenContent({
    super.key,
    required this.currentFavorites,
    required this.onFavoritesUpdated,
  });

  @override
  State<AllAppsScreenContent> createState() => _AllAppsScreenContentState();
}

class _AllAppsScreenContentState extends State<AllAppsScreenContent>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
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

  static const String _clickCountsPrefsKey = 'app_click_counts';
  Timer? _saveClickCountsTimer;
  bool _clickCountsChangedSinceLastSave = false;

  bool _isSearchLoading = false;
  String _lastSearchQuery = '';
  final _debounceTimer = Debouncer(milliseconds: 400);

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

    _favoritePackages =
        widget.currentFavorites
            .map((fav) => fav['packageName'] ?? '')
            .where((pkg) => pkg.isNotEmpty)
            .toSet();

    _isLoading = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadInitialData(showLoadingIndicator: false);
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
      'AllAppsScreenContent initState completato',
      name: 'AllAppsScreenContent',
    );
  }

  @override
  void dispose() {
    developer.log('AllAppsScreenContent dispose', name: 'AllAppsScreenContent');
    WidgetsBinding.instance.removeObserver(this);
    _searchController
      ..removeListener(_debounceSearchListener)
      ..dispose();
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
        'AllAppsScreenContent resumed, ricarico dati',
        name: 'AllAppsScreenContent',
      );
      _loadInitialData(showLoadingIndicator: _allAppsWithData.isEmpty);
    } else if (state == AppLifecycleState.paused) {
      developer.log(
        'AllAppsScreenContent paused, salvo click counts',
        name: 'AllAppsScreenContent',
      );
      _saveClickCountsNowIfChanged();
    }
  }

  // ---------------------------------------------------------------------------
  // EVENTCHANNEL
  // ---------------------------------------------------------------------------

  void _listenToPackageEvents() {
    _packageEventSubscription?.cancel();
    _packageEventSubscription = _packageEventChannel
        .receiveBroadcastStream()
        .listen(
          _handlePackageEvent,
          onError:
              (Object error) => developer.log(
                'Errore EventChannel: $error',
                name: 'AllAppsScreenContent',
              ),
          onDone:
              () => developer.log(
                'EventChannel stream chiuso.',
                name: 'AllAppsScreenContent',
              ),
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
    if (event is! Map) return;

    final eventType = event['event'] as String? ?? '';
    final packageName = event['packageName'] as String?;
    if (packageName == null || packageName.isEmpty) return;

    if (eventType == 'package_removed') {
      if (!mounted) return;
      bool favoriteRemoved = false;
      bool countsRemoved = false;
      setState(() {
        _allAppsWithData.removeWhere((a) => a['packageName'] == packageName);
        _iconPathCache.remove(packageName);
        if (_favoritePackages.remove(packageName)) favoriteRemoved = true;
        if (_clickCounts.remove(packageName) != null) countsRemoved = true;
        _applyFilterAndSort(_searchController.text.trim());
      });
      // Solo qui (disinstallazione reale) è lecito salvare su disco i preferiti
      if (favoriteRemoved) widget.onFavoritesUpdated(getUpdatedFavoritesData());
      if (countsRemoved) {
        _clickCountsChangedSinceLastSave = true;
        _saveClickCountsNowIfChanged();
      }
    } else if (eventType == 'package_added' || eventType == 'package_changed') {
      developer.log(
        'Pacchetto $packageName aggiunto/modificato, ricarico.',
        name: 'AllAppsScreenContent',
      );
      _loadInitialData(showLoadingIndicator: _allAppsWithData.isEmpty);
    }
  }

  // ---------------------------------------------------------------------------
  // CLICK COUNTS
  // ---------------------------------------------------------------------------

  Future<void> _loadClickCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_clickCountsPrefsKey);
      if (jsonString != null) {
        final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
        _clickCounts = decoded.map((k, v) => MapEntry(k, v as int? ?? 0));
      } else {
        _clickCounts = {};
      }
      _clickCountsChangedSinceLastSave = false;
      developer.log('Click counts caricati.', name: 'AllAppsScreenContent');
    } catch (e, s) {
      developer.log(
        'Errore caricamento click counts: $e',
        name: 'AllAppsScreenContent',
        error: e,
        stackTrace: s,
      );
      _clickCounts = {};
    }
  }

  Future<void> _saveClickCountsNowIfChanged() async {
    if (!_clickCountsChangedSinceLastSave) return;
    developer.log('Salvataggio click counts...', name: 'AllAppsScreenContent');
    _saveClickCountsTimer?.cancel();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_clickCountsPrefsKey, jsonEncode(_clickCounts));
      _clickCountsChangedSinceLastSave = false;
    } catch (e, s) {
      developer.log(
        'Errore salvataggio click counts: $e',
        name: 'AllAppsScreenContent',
        error: e,
        stackTrace: s,
      );
    }
  }

  void _scheduleSaveClickCounts() {
    if (!_clickCountsChangedSinceLastSave) return;
    _saveClickCountsTimer?.cancel();
    _saveClickCountsTimer = Timer(
      const Duration(seconds: 15),
      _saveClickCountsNowIfChanged,
    );
  }

  // ---------------------------------------------------------------------------
  // CARICAMENTO INIZIALE
  //
  // FIX: la sincronizzazione preferiti aggiorna SOLO _favoritePackages in
  // memoria. Non chiama mai onFavoritesUpdated() → nessuna scrittura su disco.
  // I preferiti vengono scritti su disco SOLO da _toggleFavorite (stella) e
  // da _handlePackageEvent (package_removed = disinstallazione reale).
  // ---------------------------------------------------------------------------
  Future<void> _loadInitialData({bool showLoadingIndicator = true}) async {
    developer.log('_loadInitialData...', name: 'AllAppsScreenContent');
    try {
      final results = await Future.wait([
        getInstalledApps(),
        _loadClickCounts(),
      ]);
      if (!mounted) return;

      final apps = results[0] as List<Map<String, String>>;
      final appsWithData =
          apps.map((app) {
            final pkg = app['packageName'] ?? '';
            return <String, dynamic>{
              ...app,
              'clickCount': _clickCounts[pkg] ?? 0,
            };
          }).toList();

      // Pre-fetch percorsi icone in parallelo
      final Map<String, String?> currentIconPaths = {};
      await Future.wait([
        for (final app in appsWithData)
          if ((app['packageName'] as String?)?.isNotEmpty == true)
            getAppIconPath(app['packageName'] as String)
                .then((path) {
                  if (mounted) {
                    currentIconPaths[app['packageName'] as String] =
                        path.isNotEmpty ? path : null;
                  }
                })
                .catchError((Object e) {
                  developer.log(
                    'Errore getAppIconPath per ${app['packageName']}: $e',
                    name: 'AllAppsScreenContent',
                  );
                  if (mounted) {
                    currentIconPaths[app['packageName'] as String] = null;
                  }
                }),
      ]);

      developer.log('Percorsi icone ottenuti.', name: 'AllAppsScreenContent');
      if (!mounted) return;

      setState(() {
        _allAppsWithData = appsWithData;
        _iconPathCache
          ..clear()
          ..addAll(currentIconPaths);

        // FIX: aggiorna preferiti solo in memoria, mai su disco.
        // Guarda di sicurezza: salta se la lista sembra incompleta
        // (split APK, profilo lavoro, avvio lento di Android).
        if (appsWithData.length > 10) {
          _favoritePackages.removeWhere(
            (pkg) => !_allAppsWithData.any((a) => a['packageName'] == pkg),
          );
          // NON chiamiamo widget.onFavoritesUpdated() qui.
        }

        _isLoading = false;
        _applyFilterAndSort(_searchController.text.trim());
        developer.log('_isLoading = false.', name: 'AllAppsScreenContent');
      });
    } catch (e, s) {
      developer.log(
        'Errore _loadInitialData: $e',
        name: 'AllAppsScreenContent',
        stackTrace: s,
      );
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // RICERCA e ORDINAMENTO
  // ---------------------------------------------------------------------------

  void _applyFilterAndSort(String query) {
    if (!mounted) return;
    setState(() => _isSearchLoading = true);

    final q = query.trim().toLowerCase();
    final filtered =
        q.isEmpty
            ? List<Map<String, dynamic>>.from(_allAppsWithData)
            : _allAppsWithData.where((app) {
              final name = (app['appName'] as String? ?? '').toLowerCase();
              final pkg = (app['packageName'] as String? ?? '').toLowerCase();
              return name.contains(q) || pkg.contains(q);
            }).toList();

    filtered.sort((a, b) {
      final cmp = (b['clickCount'] as int? ?? 0).compareTo(
        a['clickCount'] as int? ?? 0,
      );
      if (cmp != 0) return cmp;
      return (a['appName'] as String? ?? '').toLowerCase().compareTo(
        (b['appName'] as String? ?? '').toLowerCase(),
      );
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

  /// Scrittura su disco dei preferiti: SOLO qui e in package_removed.
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

  /// Costruisce la lista preferiti da passare a MainScaffold.
  /// Usa _allAppsWithData per i nomi se disponibili; fallback su
  /// widget.currentFavorites per non perdere voci durante il caricamento.
  List<Map<String, String>> getUpdatedFavoritesData() {
    final loadedNames = <String, String>{
      for (final app in _allAppsWithData)
        if ((app['packageName'] as String?)?.isNotEmpty == true)
          app['packageName'] as String: app['appName'] as String? ?? 'App',
    };
    final fallbackNames = <String, String>{
      for (final fav in widget.currentFavorites)
        if ((fav['packageName'] ?? '').isNotEmpty)
          fav['packageName']!: fav['appName'] ?? 'App',
    };
    return _favoritePackages
        .where((pkg) => pkg.isNotEmpty)
        .map(
          (pkg) => {
            'appName': loadedNames[pkg] ?? fallbackNames[pkg] ?? 'App',
            'packageName': pkg,
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
        _swingController
          ..stop()
          ..reset();
      }
    });
  }

  void _confirmDeleteApp(Map<String, dynamic> app) {
    final pkg = app['packageName'] as String? ?? '';
    final appName = app['appName'] as String? ?? 'App';
    if (pkg.isEmpty || !mounted) return;
    final colorScheme = Theme.of(context).colorScheme;

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
                    'Avvio disinstallazione per $pkg...',
                    name: 'AllAppsScreenContent',
                  );
                  final success = await uninstallAppByPackage(pkg);
                  if (!mounted) return;
                  if (!success) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Non è stato possibile avviare la disinstallazione di "$appName".',
                        ),
                        backgroundColor: colorScheme.errorContainer,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  } else {
                    developer.log(
                      'Intent disinstallazione per $pkg avviato. Attendo package_removed...',
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
      _clickCounts[packageName] = (_clickCounts[packageName] ?? 0) + 1;
      _clickCountsChangedSinceLastSave = true;
      _applyFilterAndSort(_searchController.text.trim());
    });
    _scheduleSaveClickCounts();
  }

  void _handleAppTap(Map<String, dynamic> app) async {
    final pkg = app['packageName'] as String? ?? '';
    if (_isDeleteMode) {
      _confirmDeleteApp(app);
      return;
    }
    if (pkg.isEmpty) return;
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
                            color: colorScheme.primary,
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
                        return _AppListItem(
                          key: ValueKey(pkg),
                          appData: app,
                          isDeleteMode: _isDeleteMode,
                          isFavorite: _favoritePackages.contains(pkg),
                          swingAnimation: _swingAnimation,
                          iconPath: _iconPathCache[pkg],
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
    super.key,
    required this.appData,
    required this.isDeleteMode,
    required this.isFavorite,
    required this.swingAnimation,
    required this.iconPath,
    required this.onToggleFavorite,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final appName = appData['appName'] as String? ?? 'App Sconosciuta';
    final pkg = appData['packageName'] as String? ?? '';

    final Widget iconContent;
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
              opacity: frame == null ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: child,
            );
          },
          errorBuilder: (context, error, stackTrace) {
            developer.log(
              'Errore Image.file per $pkg: $error',
              name: 'AppListItem',
            );
            return Icon(
              Icons.broken_image,
              size: 40,
              color: colorScheme.error.withValues(alpha: 0.7),
            );
          },
        ),
      );
    } else {
      iconContent = Icon(
        Icons.android,
        size: 40,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 4.0),
      elevation: 0.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
      color: colorScheme.surface,
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
                        style: theme.textTheme.titleMedium?.copyWith(
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
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.error.withValues(alpha: 0.9),
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
                            : colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
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
// Debouncer
// -----------------------------------------------------------------------------
class Debouncer {
  final int milliseconds;
  Timer? _timer;

  Debouncer({required this.milliseconds});

  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: milliseconds), action);
  }

  void dispose() => _timer?.cancel();
}
