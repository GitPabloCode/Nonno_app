import 'dart:async';
import 'dart:convert';
import 'dart:io'; // Per File
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Per EventChannel
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nonno_app/native/native_methods.dart'; // Assicurati che il percorso sia corretto
import 'dart:developer' as developer; // Per il logging

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
  List<Map<String, dynamic>> _allAppsWithData =
      []; // Lista completa app con dati extra
  List<Map<String, dynamic>> _filteredSortedApps =
      []; // Lista visualizzata (filtrata/ordinata)
  final TextEditingController _searchController = TextEditingController();
  late Set<String> _favoritePackages; // Package names dei preferiti
  Map<String, int> _clickCounts = {}; // Conteggio click per app
  bool _isDeleteMode = false; // Flag per modalità eliminazione
  bool _isLoading =
      true; // Flag caricamento iniziale (impostato true in initState)
  late AnimationController
  _swingController; // Controller per animazione delete mode
  late Animation<double> _swingAnimation; // Animazione delete mode
  final Map<String, String?> _iconPathCache =
      {}; // Cache per i *percorsi* delle icone

  // --- Gestione Salvataggio Click Counts Ottimizzato ---
  static const String _clickCountsPrefsKey = 'app_click_counts';
  Timer? _saveClickCountsTimer; // Timer per raggruppare salvataggi
  bool _clickCountsChangedSinceLastSave = false; // Flag per sapere se salvare

  // --- Gestione Ricerca ---
  bool _isSearchLoading = false; // Flag caricamento specifico della ricerca
  String _lastSearchQuery =
      ""; // Ultima query usata per evitare chiamate duplicate
  final _debounceTimer = Debouncer(
    milliseconds: 400,
  ); // Debouncer per input ricerca

  // --- Gestione Eventi Installazione/Rimozione App ---
  // Assicurati che il package name qui sia quello del tuo progetto Android/iOS
  static const _packageEventChannel = EventChannel(
    'com.example.nonno_app/package_events',
  );
  StreamSubscription?
  _packageEventSubscription; // Sottoscrizione allo stream eventi

  // --- METODI LIFECYCLE & HELPER ---

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(
      this,
    ); // Registra observer per lifecycle app

    // Inizializza i preferiti dalla lista passata da MainScaffold
    _favoritePackages =
        widget.currentFavorites
            .map((fav) => fav['packageName'] ?? '')
            .where((pkg) => pkg.isNotEmpty)
            .toSet();

    // Imposta lo stato iniziale come "in caricamento"
    // Non chiamare _loadInitialData() direttamente qui.
    _isLoading = true; // Flag per mostrare subito l'indicatore globale

    // *** MODIFICA CHIAVE: Pianifica _loadInitialData DOPO il primo frame ***
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Controlla se il widget è ancora montato prima di procedere
      if (mounted) {
        // Avvia il caricamento dati senza mostrare un ulteriore indicatore
        // perché _isLoading è già true.
        _loadInitialData(showLoadingIndicator: false);
      }
    });

    // Aggiungi listener al controller di ricerca
    _searchController.addListener(_debounceSearchListener);

    // Inizializza animazione per delete mode
    _swingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _swingAnimation = Tween<double>(
      begin: -0.025, // Angolo iniziale (radianti)
      end: 0.025, // Angolo finale (radianti)
    ).chain(CurveTween(curve: Curves.easeInOut)).animate(_swingController);

    // Inizia ad ascoltare eventi di aggiunta/rimozione pacchetti
    _listenToPackageEvents();

    developer.log(
      "AllAppsScreenContent initState completato (loading deferred)",
      name: "AllAppsScreenContent",
    );
  }

  @override
  void dispose() {
    developer.log("AllAppsScreenContent dispose", name: "AllAppsScreenContent");
    WidgetsBinding.instance.removeObserver(this); // Rimuovi observer lifecycle
    _searchController.removeListener(
      _debounceSearchListener,
    ); // Rimuovi listener ricerca
    _searchController.dispose();
    _swingController.dispose(); // Rilascia controller animazione
    _packageEventSubscription?.cancel(); // Cancella sottoscrizione eventi
    _debounceTimer.dispose(); // Rilascia timer debounce
    _saveClickCountsTimer?.cancel(); // Cancella timer salvataggio click
    _saveClickCountsNowIfChanged(); // Salva click un'ultima volta se necessario
    super.dispose();
  }

  // Metodo helper per rimuovere il listener del debounce
  void _debounceSearchListener() {
    final query = _searchController.text.trim();
    _debounceTimer.run(() {
      if (query != _lastSearchQuery) {
        _lastSearchQuery = query;
        // Applica filtro e ordinamento (sul main thread)
        _applyFilterAndSort(query);
      }
    });
  }

  // Gestisce cambiamenti lifecycle dell'app (es. pausa, resume)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Quando l'app torna in foreground, ricarica i dati per sicurezza
      // (l'utente potrebbe aver installato/disinstallato app fuori dall'app)
      developer.log(
        "AllAppsScreenContent resumed, ricarico dati",
        name: "AllAppsScreenContent",
      );
      // Non mostrare l'indicatore di caricamento globale se non è il primo caricamento
      _loadInitialData(showLoadingIndicator: !_allAppsWithData.isNotEmpty);
    } else if (state == AppLifecycleState.paused) {
      // Quando l'app va in pausa, salva i conteggi click se sono cambiati
      developer.log(
        "AllAppsScreenContent paused, salvo click counts se cambiati",
        name: "AllAppsScreenContent",
      );
      _saveClickCountsNowIfChanged();
    }
  }

  // --- GESTIONE EVENTCHANNEL (Aggiunta/Rimozione App Esterna) ---

  void _listenToPackageEvents() {
    _packageEventSubscription
        ?.cancel(); // Assicura che non ci siano listener duplicati
    _packageEventSubscription = _packageEventChannel
        .receiveBroadcastStream()
        .listen(
          _handlePackageEvent, // Metodo che gestisce l'evento
          onError: (error) {
            // Logga eventuali errori dello stream
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
            // Potresti voler riavviare l'ascolto qui se necessario
          },
        );
    developer.log(
      'In ascolto per eventi pacchetto...',
      name: 'AllAppsScreenContent',
    );
  }

  // Processa l'evento ricevuto da EventChannel
  void _handlePackageEvent(dynamic event) {
    developer.log(
      'Evento pacchetto ricevuto: $event',
      name: 'AllAppsScreenContent',
    );
    if (event is Map) {
      final String eventType = event['event'] ?? '';
      final String? packageName = event['packageName'];

      if (packageName != null && packageName.isNotEmpty) {
        // Se un'app è stata rimossa
        if (eventType == 'package_removed') {
          // Verifica se il widget è ancora attivo
          if (mounted) {
            bool favoriteRemoved = false;
            bool countsRemoved = false;
            // Aggiorna lo stato rimuovendo l'app
            setState(() {
              // Rimuovi da tutte le liste e cache
              _allAppsWithData.removeWhere(
                (a) => a['packageName'] == packageName,
              );
              _iconPathCache.remove(
                packageName,
              ); // Rimuovi icona dalla cache percorsi

              // Rimuovi dai preferiti se presente
              if (_favoritePackages.contains(packageName)) {
                _favoritePackages.remove(packageName);
                favoriteRemoved = true;
              }
              // Rimuovi dai conteggi click se presente
              if (_clickCounts.containsKey(packageName)) {
                _clickCounts.remove(packageName);
                countsRemoved = true; // Indica che i counts sono cambiati
              }
              // Applica filtro e ordinamento per aggiornare la UI
              _applyFilterAndSort(_searchController.text.trim());
            });

            // Notifica MainScaffold se un preferito è stato rimosso
            if (favoriteRemoved) {
              widget.onFavoritesUpdated(getUpdatedFavoritesData());
            }
            // Salva subito i click counts se sono stati modificati
            if (countsRemoved) {
              _clickCountsChangedSinceLastSave = true;
              _saveClickCountsNowIfChanged();
            }
          }
        }
        // Se un'app è stata aggiunta o modificata (es. aggiornamento)
        else if (eventType == 'package_added' ||
            eventType == 'package_changed') {
          developer.log(
            'Pacchetto $packageName aggiunto/modificato, ricarico dati.',
            name: 'AllAppsScreenContent',
          );
          // Ricarica tutti i dati (inclusi i percorsi icone)
          // Mostra indicatore solo se la lista era vuota
          _loadInitialData(showLoadingIndicator: _allAppsWithData.isEmpty);
        }
      }
    }
  }

  // --- CARICAMENTO DATI (App, Click, Percorsi Icone) ---

  // Carica i conteggi dei click da SharedPreferences
  Future<void> _loadClickCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_clickCountsPrefsKey);
      if (jsonString != null) {
        final decodedMap = jsonDecode(jsonString) as Map<String, dynamic>;
        // Converte la mappa JSON in Map<String, int>
        _clickCounts = decodedMap.map(
          (key, value) => MapEntry(key, value as int? ?? 0),
        );
      } else {
        _clickCounts = {}; // Inizializza a vuoto se non trovato
      }
      _clickCountsChangedSinceLastSave =
          false; // Resetta il flag dopo il caricamento
      developer.log("Click counts caricati.", name: "AllAppsScreenContent");
    } catch (e, stacktrace) {
      developer.log(
        "Errore caricamento click counts: $e",
        name: 'AllAppsScreenContent',
        error: e,
        stackTrace: stacktrace,
      );
      _clickCounts = {}; // Resetta in caso di errore
    }
  }

  // Salva i conteggi dei click su SharedPreferences, MA SOLO SE SONO CAMBIATI
  Future<void> _saveClickCountsNowIfChanged() async {
    // Se il flag indica che non ci sono modifiche dall'ultimo salvataggio/caricamento, esci
    if (!_clickCountsChangedSinceLastSave) {
      developer.log(
        "Salvataggio click counts saltato (nessuna modifica).",
        name: "AllAppsScreenContent",
      );
      return;
    }
    developer.log("Salvataggio click counts...", name: "AllAppsScreenContent");
    _saveClickCountsTimer?.cancel(); // Cancella il timer se era attivo
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(_clickCounts); // Codifica la mappa in JSON
      await prefs.setString(_clickCountsPrefsKey, jsonString);
      _clickCountsChangedSinceLastSave =
          false; // Resetta il flag dopo il salvataggio riuscito
    } catch (e, stacktrace) {
      developer.log(
        "Errore salvataggio click counts: $e",
        name: 'AllAppsScreenContent',
        error: e,
        stackTrace: stacktrace,
      );
      // Non resettare il flag in caso di errore, così riproverà al prossimo evento
    }
  }

  // Pianifica il salvataggio dei conteggi click dopo un certo periodo di inattività
  void _scheduleSaveClickCounts() {
    // Se non ci sono modifiche da salvare, non fare nulla
    if (!_clickCountsChangedSinceLastSave) return;

    _saveClickCountsTimer?.cancel(); // Cancella eventuali timer precedenti
    _saveClickCountsTimer = Timer(const Duration(seconds: 15), () {
      // Attendi 15 secondi
      // Quando il timer scatta, esegui il salvataggio (che controllerà di nuovo il flag)
      _saveClickCountsNowIfChanged();
    });
  }

  // *** MODIFICATO per NON impostare _isLoading=true all'inizio ***
  // Carica la lista app, i click counts, e pre-carica i percorsi delle icone
  Future<void> _loadInitialData({bool showLoadingIndicator = true}) async {
    // L'impostazione di _isLoading = true è ora fatta solo in initState

    developer.log(
      "Esecuzione _loadInitialData...",
      name: "AllAppsScreenContent",
    );

    try {
      // Carica lista app e conteggi click in parallelo per ottimizzare i tempi
      final results = await Future.wait([
        getInstalledApps(), // Chiamata nativa
        _loadClickCounts(), // Lettura SharedPreferences
      ]);

      // Se il widget è stato smontato mentre attendevamo i dati, esci
      if (!mounted) return;

      // Estrai i risultati
      final List<Map<String, String>> apps =
          results[0] as List<Map<String, String>>;
      // _loadClickCounts aggiorna _clickCounts direttamente

      // Prepara la lista di dati completa (_allAppsWithData)
      final List<Map<String, dynamic>> appsWithData =
          apps.map((app) {
            final pkg = app['packageName'] ?? '';
            return {
              ...app, // Include appName, packageName
              'clickCount':
                  _clickCounts[pkg] ?? 0, // Aggiunge il conteggio click
            };
          }).toList();

      // **Pre-fetch dei percorsi delle icone**
      final Map<String, String?> currentIconPaths =
          {}; // Mappa temporanea per i nuovi percorsi
      List<Future> iconPathFutures =
          []; // Lista di Future per attendere il completamento
      for (var app in appsWithData) {
        final pkg = app['packageName'] as String?;
        if (pkg != null && pkg.isNotEmpty) {
          // Avvia la chiamata nativa asincrona per ottenere il percorso dell'icona
          iconPathFutures.add(
            getAppIconPath(pkg)
                .then((path) {
                  // Quando la chiamata ritorna, aggiorna la mappa temporanea
                  // (controlla sempre 'mounted' nelle callback asincrone)
                  if (mounted) {
                    currentIconPaths[pkg] = path.isNotEmpty ? path : null;
                  }
                })
                .catchError((e) {
                  // Gestisci errori durante il recupero del percorso
                  developer.log(
                    "Errore getAppIconPath per $pkg: $e",
                    name: "AllAppsScreenContent",
                  );
                  if (mounted) {
                    currentIconPaths[pkg] =
                        null; // Imposta null se c'è un errore
                  }
                }),
          );
        }
      }

      // Aspetta che tutte le richieste asincrone per i percorsi finiscano
      await Future.wait(iconPathFutures);
      developer.log("Percorsi icone ottenuti.", name: "AllAppsScreenContent");

      // Se il widget è stato smontato mentre attendevamo le icone, esci
      if (!mounted) return;

      // Aggiorna lo stato finale con tutti i dati caricati
      setState(() {
        _allAppsWithData = appsWithData; // Aggiorna la lista completa
        _iconPathCache.clear(); // Pulisci la cache vecchia
        _iconPathCache.addAll(
          currentIconPaths,
        ); // Aggiorna la cache con i nuovi percorsi

        // Sincronizza i preferiti: rimuovi quelli non più installati
        int originalFavCount = _favoritePackages.length;
        _favoritePackages.removeWhere(
          (pkg) => !_allAppsWithData.any((app) => app['packageName'] == pkg),
        );
        bool favoritesChanged = _favoritePackages.length != originalFavCount;

        // *** MODIFICA CHIAVE: Imposta _isLoading = false alla fine ***
        _isLoading = false;
        // Applica il filtro e l'ordinamento iniziali o correnti
        _applyFilterAndSort(_searchController.text.trim());

        // Notifica MainScaffold solo se la lista dei preferiti è cambiata
        if (favoritesChanged) {
          widget.onFavoritesUpdated(getUpdatedFavoritesData());
        }
        developer.log(
          "Stato aggiornato, _isLoading = false.",
          name: "AllAppsScreenContent",
        );
      });
    } catch (e, s) {
      // Gestione errori durante il caricamento iniziale
      developer.log(
        "Errore _loadInitialData: $e",
        name: "AllAppsScreenContent",
        stackTrace: s,
      );
      if (mounted) {
        // Assicurati di fermare l'indicatore di caricamento anche in caso di errore
        setState(() => _isLoading = false);
      }
    }
  }

  // --- RICERCA e ORDINAMENTO (Eseguiti sul Main Thread) ---

  // Applica il filtro testuale e l'ordinamento alla lista _allAppsWithData
  void _applyFilterAndSort(String query) {
    if (!mounted) return; // Controllo sicurezza
    // Mostra l'indicatore di caricamento specifico per la ricerca
    // (potrebbe essere così veloce da non vedersi, ma è utile per query complesse)
    setState(() => _isSearchLoading = true);

    // Esegui filtro e ordinamento
    final lowercaseQuery = query.trim().toLowerCase();
    List<Map<String, dynamic>> filtered;

    // Filtra in base alla query (su nome app o package name)
    if (lowercaseQuery.isEmpty) {
      filtered = List.from(_allAppsWithData); // Nessun filtro, prendi tutte
    } else {
      filtered =
          _allAppsWithData.where((app) {
            final name = (app['appName'] as String? ?? '').toLowerCase();
            final pkg = (app['packageName'] as String? ?? '').toLowerCase();
            return name.contains(lowercaseQuery) ||
                pkg.contains(lowercaseQuery);
          }).toList();
    }

    // Ordina la lista filtrata:
    // 1. Per numero di click (discendente)
    // 2. A parità di click, per nome (ascendente, case-insensitive)
    filtered.sort((a, b) {
      final countA = a['clickCount'] as int? ?? 0;
      final countB = b['clickCount'] as int? ?? 0;
      int compare = countB.compareTo(countA); // Decrescente per click
      if (compare == 0) {
        // Se i click sono uguali...
        final nameA = a['appName'] as String? ?? '';
        final nameB = b['appName'] as String? ?? '';
        compare = nameA.toLowerCase().compareTo(
          nameB.toLowerCase(),
        ); // Crescente per nome
      }
      return compare;
    });

    // Aggiorna lo stato con la lista filtrata/ordinata e nascondi l'indicatore di ricerca
    // Usiamo un microtask per assicurarci che lo stato di loading venga aggiornato
    // anche se il filtro/sort è quasi istantaneo.
    Future.microtask(() {
      if (mounted) {
        setState(() {
          _filteredSortedApps = filtered;
          _isSearchLoading = false; // Nascondi spinner ricerca
        });
      }
    });
  }

  // --- Metodi Azioni Utente (Toggle Preferito, Conferma Delete, Incrementa Click) ---

  // Gestisce il tocco sull'icona stella (aggiungi/rimuovi preferito)
  void _toggleFavorite(Map<String, dynamic> app) {
    final pkg = app['packageName'] as String? ?? '';
    if (pkg.isEmpty || !mounted) return;
    final isFav = _favoritePackages.contains(pkg);

    // Aggiorna lo stato locale dei preferiti
    setState(() {
      if (isFav) {
        _favoritePackages.remove(pkg);
      } else {
        _favoritePackages.add(pkg);
      }
      // Potresti voler riordinare la lista qui se l'essere preferito
      // influisce sull'ordinamento (attualmente non lo fa).
      // _applyFilterAndSort(_searchController.text.trim());
    });

    // Notifica il widget padre (MainScaffold) che i preferiti sono cambiati
    widget.onFavoritesUpdated(getUpdatedFavoritesData());

    // Mostra un messaggio di feedback all'utente
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

  // Prepara la lista di dati dei preferiti da passare a MainScaffold
  List<Map<String, String>> getUpdatedFavoritesData() {
    return _allAppsWithData
        .where((app) => _favoritePackages.contains(app['packageName']))
        .map(
          (app) => {
            // Passa solo nome e package name, come richiesto da MainScaffold
            'appName': app['appName'] as String? ?? 'App',
            'packageName': app['packageName'] as String? ?? '',
          },
        )
        .toList();
  }

  // Attiva/Disattiva la modalità eliminazione con animazione
  void _toggleDeleteMode() {
    if (!mounted) return;
    setState(() {
      _isDeleteMode = !_isDeleteMode;
      if (_isDeleteMode) {
        _swingController.repeat(reverse: true); // Avvia animazione oscillante
      } else {
        _swingController.stop(); // Ferma animazione
        _swingController.reset(); // Resetta alla posizione iniziale
      }
    });
  }

  // Mostra il dialogo di conferma prima di disinstallare un'app
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
                onPressed: () => Navigator.of(context).pop(), // Chiudi dialogo
                child: Text(
                  'Annulla',
                  style: TextStyle(color: colorScheme.primary),
                ),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop(); // Chiudi dialogo
                  developer.log(
                    'Avvio intent disinstallazione per $pkg...',
                    name: 'AllAppsScreenContent',
                  );
                  // Chiama il metodo nativo per avviare la disinstallazione
                  final success = await uninstallAppByPackage(pkg);
                  // L'aggiornamento della UI (rimozione dalla lista) avverrà
                  // quando riceveremo l'evento 'package_removed' da EventChannel.
                  if (!success && mounted) {
                    // Mostra errore se non è stato possibile avviare l'intent
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

  // Incrementa il conteggio dei click e pianifica il salvataggio ottimizzato
  void _incrementAppClickCount(String packageName) {
    if (packageName.isEmpty || !mounted) return;
    setState(() {
      final currentCount = _clickCounts[packageName] ?? 0;
      _clickCounts[packageName] = currentCount + 1;
      _clickCountsChangedSinceLastSave = true; // Segna che i dati sono cambiati
      // Ri-ordina la lista visualizzata per riflettere subito il nuovo conteggio
      _applyFilterAndSort(_searchController.text.trim());
    });
    // Pianifica il salvataggio su disco (avverrà dopo 15 sec o in pausa/dispose)
    _scheduleSaveClickCounts();
  }

  // --- WIDGET BUILD (UI della schermata) ---
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SafeArea(
      // Evita sovrapposizioni con notch, barre di sistema, ecc.
      child: Column(
        children: [
          // --- Barra di Ricerca e Pulsante Delete ---
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 12.0, 16.0, 4.0),
            child: Row(
              children: [
                // Campo di testo per la ricerca
                Expanded(
                  child: Directionality(
                    // Forza LTR per il campo di testo
                    textDirection: TextDirection.ltr,
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Cerca app...',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        // Mostra pulsante 'X' per cancellare se c'è testo
                        suffixIcon:
                            _searchController.text.isNotEmpty
                                ? IconButton(
                                  icon: const Icon(Icons.clear, size: 20),
                                  tooltip: 'Cancella ricerca',
                                  onPressed: () {
                                    _searchController.clear(); // Pulisci campo
                                    _applyFilterAndSort(
                                      '',
                                    ); // Applica filtro vuoto
                                  },
                                )
                                : null, // Nascondi se vuoto
                        isDense: true, // Riduce l'altezza
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12.0,
                          horizontal: 12.0,
                        ),
                        // Bordi arrotondati
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
                      style: theme.textTheme.bodyLarge, // Stile testo input
                    ),
                  ),
                ),
                const SizedBox(width: 8), // Spazio tra ricerca e pulsante
                // Mostra indicatore di caricamento ricerca o pulsante delete
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
                      // Cambia icona se in modalità delete
                      _isDeleteMode
                          ? Icons.delete_forever
                          : Icons.delete_outline,
                      // Cambia colore se in modalità delete
                      color:
                          _isDeleteMode
                              ? colorScheme.error
                              : colorScheme.onSurfaceVariant,
                    ),
                    tooltip:
                        _isDeleteMode
                            ? 'Termina eliminazione'
                            : 'Modalità eliminazione',
                    onPressed:
                        _toggleDeleteMode, // Attiva/disattiva delete mode
                  ),
              ],
            ),
          ),
          // --- Lista App o Indicatori di Stato ---
          Expanded(
            // Mostra indicatore di caricamento globale se _isLoading è true
            child:
                _isLoading
                    ? Center(
                      child: CircularProgressIndicator(
                        color: colorScheme.primary,
                      ),
                    )
                    // Altrimenti, se la lista filtrata è vuota E non stiamo caricando una ricerca...
                    : _filteredSortedApps.isEmpty && !_isSearchLoading
                    // Mostra messaggio "Nessuna app trovata"
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
                    // Altrimenti, mostra la ListView delle app
                    : ListView.builder(
                      padding: const EdgeInsets.only(
                        top: 8.0,
                        bottom: 16.0,
                        left: 8.0,
                        right: 8.0,
                      ),
                      itemCount:
                          _filteredSortedApps
                              .length, // Numero di app da mostrare
                      // Costruisce ogni elemento della lista
                      itemBuilder: (context, index) {
                        final app = _filteredSortedApps[index];
                        final pkg = app['packageName'] as String? ?? '';
                        final isFav = _favoritePackages.contains(pkg);
                        // Ottieni il percorso dell'icona dalla cache popolata in _loadInitialData
                        final iconPath = _iconPathCache[pkg];

                        // Crea il widget _AppListItem per questa app
                        return _AppListItem(
                          key: ValueKey(
                            pkg,
                          ), // Usa package name come chiave univoca
                          appData: app,
                          isDeleteMode: _isDeleteMode,
                          isFavorite: isFav,
                          swingAnimation: _swingAnimation, // Passa animazione
                          iconPath: iconPath, // Passa il percorso icona!
                          // Callback per azioni utente sull'item
                          onToggleFavorite: () => _toggleFavorite(app),
                          onTap:
                              () => _handleAppTap(
                                app,
                              ), // Gestisce tap normale e delete
                          onDelete:
                              () => _confirmDeleteApp(
                                app,
                              ), // Mostra conferma delete
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }

  // Metodo helper per gestire il tap sull'elemento della lista
  void _handleAppTap(Map<String, dynamic> app) async {
    final pkg = app['packageName'] as String? ?? '';
    if (!_isDeleteMode && pkg.isNotEmpty) {
      // Se non siamo in delete mode...
      // Apri l'app
      final ok = await openAppByPackage(pkg);
      if (ok) {
        // Se l'apertura ha successo, incrementa il contatore
        _incrementAppClickCount(pkg);
      } else if (mounted) {
        // Se l'apertura fallisce, mostra un messaggio
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Impossibile aprire "${app['appName']}"'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else if (_isDeleteMode) {
      // Se siamo in delete mode...
      // Mostra il dialogo di conferma disinstallazione
      _confirmDeleteApp(app);
    }
  }
} // Fine _AllAppsScreenContentState

// -----------------------------------------------------------------------------
// Widget _AppListItem (Elemento singolo nella lista)
// MODIFICATO per usare iconPath e Image.file
// -----------------------------------------------------------------------------
class _AppListItem extends StatelessWidget {
  final Map<String, dynamic> appData;
  final bool isDeleteMode;
  final bool isFavorite;
  final Animation<double> swingAnimation;
  final String? iconPath; // Riceve il percorso dell'icona dalla cache del padre
  final VoidCallback onToggleFavorite;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _AppListItem({
    Key? key,
    required this.appData,
    required this.isDeleteMode,
    required this.isFavorite,
    required this.swingAnimation,
    required this.iconPath, // Richiede il percorso
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

    Widget iconContent; // Widget che conterrà l'icona o il fallback

    // Tenta di caricare l'icona usando Image.file se il percorso è valido
    if (iconPath != null && iconPath!.isNotEmpty) {
      iconContent = ClipRRect(
        // Arrotonda gli angoli dell'immagine
        borderRadius: BorderRadius.circular(8.0),
        child: Image.file(
          File(iconPath!), // Crea l'oggetto File dal percorso
          fit: BoxFit.cover, // Adatta l'immagine allo spazio
          width: 48,
          height: 48,
          // frameBuilder per una transizione di opacità (effetto fade-in)
          frameBuilder: (context, child, frame, wasSyncLoaded) {
            if (wasSyncLoaded)
              return child; // Evita animazione se caricata subito
            return AnimatedOpacity(
              opacity:
                  frame == null
                      ? 0
                      : 1, // Opacità 0 durante caricamento, 1 a caricamento finito
              duration: const Duration(milliseconds: 300), // Durata dissolvenza
              curve: Curves.easeOut,
              child: child,
            );
          },
          // errorBuilder è FONDAMENTALE quando si usa Image.file
          errorBuilder: (context, error, stackTrace) {
            // Se c'è un errore nel caricare/decodificare il file
            developer.log(
              "Errore Image.file per $pkg ($iconPath): $error",
              name: "AppListItem",
            );
            // Mostra un'icona sostitutiva di errore
            return Icon(
              Icons.broken_image,
              size: 40,
              color: colorScheme.error.withOpacity(0.7),
            );
          },
        ),
      );
    } else {
      // Se iconPath è null o vuoto, mostra un'icona di fallback generica
      iconContent = Icon(
        Icons.android,
        size: 40,
        color: colorScheme.onSurfaceVariant.withOpacity(0.5),
      );
    }

    // Costruzione dell'elemento Card della lista
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 4.0),
      elevation: 0.5, // Leggera ombra
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8.0),
      ), // Bordi arrotondati
      color: theme.cardColor, // Usa colore dalla cardTheme
      clipBehavior: Clip.antiAlias, // Ritaglia contenuto ai bordi arrotondati
      child: InkWell(
        // Rende l'elemento cliccabile
        onTap: onTap, // Azione al tocco (gestita dal padre)
        borderRadius: BorderRadius.circular(8.0), // Effetto ripple arrotondato
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
          child: Row(
            // Layout orizzontale: Icona | Testo | Pulsante Stella/Delete
            children: [
              // --- Icona (con eventuale animazione delete) ---
              SizedBox(
                width: 48,
                height: 48,
                child:
                    isDeleteMode
                        // Se in delete mode, applica l'animazione di oscillazione
                        ? AnimatedBuilder(
                          animation: swingAnimation,
                          builder:
                              (_, child) => Transform.rotate(
                                angle: swingAnimation.value,
                                child: child,
                              ),
                          child: iconContent, // Il contenuto dell'icona
                        )
                        // Altrimenti, mostra solo l'icona statica
                        : iconContent,
              ),
              const SizedBox(width: 16), // Spazio tra icona e testo
              // --- Nome App e Testo "Tocca per disinstallare" ---
              Expanded(
                // Occupa lo spazio rimanente
                child: Column(
                  // Layout verticale per nome e testo delete
                  crossAxisAlignment:
                      CrossAxisAlignment.start, // Allinea a sinistra
                  mainAxisAlignment:
                      MainAxisAlignment.center, // Centra verticalmente
                  children: [
                    // Nome dell'app (forza LTR per sicurezza)
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        appName,
                        style: textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                        maxLines: 1, // Massimo una riga
                        overflow: TextOverflow.ellipsis, // ... se troppo lungo
                      ),
                    ),
                    // Mostra testo aggiuntivo solo se in delete mode
                    if (isDeleteMode) ...[
                      const SizedBox(height: 2), // Piccolo spazio
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
              const SizedBox(width: 8), // Spazio tra testo e pulsante azione
              // --- Pulsante Azione (Stella o Delete) ---
              if (isDeleteMode)
                // Pulsante per confermare la disinstallazione (l'azione è su onTap dell'InkWell)
                IconButton(
                  visualDensity: VisualDensity.compact, // Riduci padding
                  icon: Icon(Icons.delete_forever, color: colorScheme.error),
                  tooltip: 'Disinstalla $appName',
                  onPressed: onDelete, // Azione gestita dal padre
                )
              else
                // Pulsante per aggiungere/rimuovere dai preferiti
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    // Icona piena o vuota a seconda se è preferito
                    isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
                    // Colore diverso se è preferito
                    color:
                        isFavorite
                            ? Colors.amber[600]
                            : colorScheme.onSurfaceVariant.withOpacity(0.7),
                    size: 28, // Dimensione icona stella
                  ),
                  tooltip:
                      isFavorite
                          ? 'Rimuovi dai preferiti'
                          : 'Aggiungi ai preferiti',
                  onPressed: onToggleFavorite, // Azione gestita dal padre
                ),
            ],
          ),
        ),
      ),
    );
  }
} // Fine _AppListItem

// -----------------------------------------------------------------------------
// Classe Helper Debouncer (Invariata)
// Utility per ritardare l'esecuzione di un'azione (es. ricerca)
// -----------------------------------------------------------------------------
class Debouncer {
  final int milliseconds; // Tempo di attesa in millisecondi
  Timer? _timer; // Timer interno

  Debouncer({required this.milliseconds});

  // Esegue l'azione dopo il ritardo specificato, cancellando eventuali azioni precedenti in attesa
  run(VoidCallback action) {
    _timer?.cancel(); // Cancella il timer precedente, se esiste
    // Avvia un nuovo timer
    _timer = Timer(Duration(milliseconds: milliseconds), action);
  }

  // Rilascia le risorse (cancella il timer) quando non serve più
  dispose() {
    _timer?.cancel();
  }
}
