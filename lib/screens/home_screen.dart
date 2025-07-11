import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:nonno_app/native/native_methods.dart';
import 'package:nonno_app/providers/theme_notifier.dart';
import 'dart:developer' as developer;

// Widget HomeScreenContent (modificato solo il delegate della griglia)
class HomeScreenContent extends StatelessWidget {
  final List<Map<String, String>> favoriteApps;
  final bool isLoading;

  const HomeScreenContent({
    Key? key,
    required this.favoriteApps,
    required this.isLoading,
  }) : super(key: key);

  static final List<Map<String, dynamic>> fixedItemsData = [
    {
      'label': 'Telefono',
      'iconData': Icons.phone,
      'onTap': openPhone,
      'isFixed': true,
    },
    {
      'label': 'Messaggi',
      'iconData': Icons.message,
      'onTap': openMessages,
      'isFixed': true,
    },
  ];

  Map<String, dynamic> _buildFavoriteItemData(Map<String, String> app) {
    return {
      'label': app['appName'] ?? 'Sconosciuta',
      'packageName': app['packageName'],
      'onTap': () async {
        final packageName = app['packageName'];
        if (packageName != null && packageName.isNotEmpty) {
          await openAppByPackage(packageName);
        }
      },
      'isFixed': false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final theme = Theme.of(context);

    final allItemsData = <Map<String, dynamic>>[...fixedItemsData];
    for (var app in favoriteApps) {
      allItemsData.add(_buildFavoriteItemData(app));
    }

    if (isLoading) {
      return Center(
        child: CircularProgressIndicator(color: theme.colorScheme.primary),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  // --- MODIFICHE ALLA GRIGLIA ---
                  maxCrossAxisExtent: 165, // Elementi leggermente più piccoli?
                  childAspectRatio: 0.95, // Leggermente più alti che larghi?
                  crossAxisSpacing: 12, // Spazio orizzontale ridotto?
                  mainAxisSpacing: 12, // Spazio verticale ridotto?
                ),
                itemCount: allItemsData.length,
                itemBuilder: (context, index) {
                  final itemData = allItemsData[index];
                  // Usa il NUOVO _HomeGridItem StatefulWidget
                  return _HomeGridItem(itemData: itemData);
                },
              ),
            ),
            const SizedBox(height: 20),
            // --- Switch Tema (invariato) ---
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.brightness_5,
                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                ),
                const SizedBox(width: 8),
                Switch(
                  value: themeNotifier.themeMode == ThemeMode.dark,
                  onChanged: (isDark) {
                    context.read<ThemeNotifier>().setThemeMode(
                      isDark ? ThemeMode.dark : ThemeMode.light,
                    );
                  },
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.brightness_3,
                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }
}

// --- Widget _HomeGridItem (Rifatto come StatefulWidget per animazione) ---
class _HomeGridItem extends StatefulWidget {
  final Map<String, dynamic> itemData;
  const _HomeGridItem({Key? key, required this.itemData}) : super(key: key);

  @override
  State<_HomeGridItem> createState() => _HomeGridItemState();
}

class _HomeGridItemState extends State<_HomeGridItem>
    with SingleTickerProviderStateMixin {
  // Controller e Animazione per l'effetto "scale" al tocco
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;

  // Cache icone locale (come prima)
  static final Map<String, String?> _localIconCache = {};

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100), // Animazione veloce
      reverseDuration: const Duration(milliseconds: 100),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  // Metodo per caricare icona (come prima)
  Future<String?> _fetchIconPath(String packageName) async {
    if (packageName.isEmpty) return null;
    if (_localIconCache.containsKey(packageName)) {
      return _localIconCache[packageName];
    }
    try {
      final path = await getAppIconPath(packageName);
      final result = path.isNotEmpty ? path : null;
      // Controllo mount prima di aggiornare cache statica (buona norma)
      if (mounted) {
        _localIconCache[packageName] = result;
      }
      return result;
    } catch (e) {
      developer.log(
        "Errore fetch icon in HomeGridItem: $e",
        name: "HomeGridItem",
      );
      if (mounted) {
        _localIconCache[packageName] = null;
      }
      return null;
    }
  }

  // Funzioni per gestire l'animazione al tocco
  void _onTapDown(TapDownDetails details) {
    _animationController.forward(); // Riduci scala
  }

  void _onTapUp(TapUpDetails details) {
    Future.delayed(const Duration(milliseconds: 50), () {
      // Piccolo ritardo prima di tornare indietro
      if (mounted) _animationController.reverse(); // Riporta a scala 1.0
    });
    // Esegui l'azione onTap originale
    widget.itemData['onTap']?.call();
  }

  void _onTapCancel() {
    if (mounted)
      _animationController
          .reverse(); // Riporta a scala 1.0 se il tap viene cancellato
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final String label = widget.itemData['label'] as String? ?? 'N/A';
    final IconData? iconData = widget.itemData['iconData'] as IconData?;
    final String? packageName = widget.itemData['packageName'] as String?;
    // final VoidCallback? onTap = widget.itemData['onTap'] as VoidCallback?; // onTap gestito ora in _onTapUp

    // --- COSTRUZIONE ICONA (con stile circolare e ombra) ---
    Widget iconWidgetContent; // Il contenuto effettivo (Icon o Image)
    Widget
    placeholderOrLoading; // Widget da mostrare durante caricamento/errore

    // Placeholder standard (puoi personalizzarlo)
    placeholderOrLoading = ClipOval(
      // Circolare anche il placeholder
      child: Container(
        width: 60, // Dimensione leggermente maggiore per icona+ombra?
        height: 60,
        color: colorScheme.secondaryContainer.withOpacity(
          0.3,
        ), // Colore placeholder
        child: Icon(
          Icons.apps, // Icona app generica
          size: 32,
          color: colorScheme.onSecondaryContainer.withOpacity(0.6),
        ),
      ),
    );

    if (iconData != null) {
      // Icona fissa (Telefono, Messaggi)
      iconWidgetContent = Icon(
        iconData,
        size: 36,
        color: colorScheme.onPrimaryContainer,
      ); // Dimensione icona interna
      placeholderOrLoading = ClipOval(
        // Sfondo circolare anche per icone fisse
        child: Container(
          width: 60,
          height: 60,
          color: colorScheme.primaryContainer,
        ),
      );
    } else if (packageName != null && packageName.isNotEmpty) {
      // Icona App Preferita (caricata asincrona)
      iconWidgetContent = FutureBuilder<String?>(
        future: _fetchIconPath(packageName),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.hasData &&
              snapshot.data != null) {
            // Icona caricata: usa Image.file dentro ClipOval
            return ClipOval(
              child: Image.file(
                File(snapshot.data!),
                width: 60,
                height: 60,
                fit: BoxFit.cover,
                frameBuilder: (context, child, frame, wasSyncLoaded) {
                  // Dissolvenza
                  if (wasSyncLoaded) return child;
                  return AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                    child: child,
                  );
                },
                errorBuilder: (context, error, stackTrace) {
                  // Gestione Errore
                  developer.log(
                    "Errore Image.file in HomeGridItem: $error",
                    name: "HomeGridItem",
                  );
                  _localIconCache.remove(packageName);
                  // Mostra un'icona di errore dentro un cerchio
                  return ClipOval(
                    child: Container(
                      width: 60,
                      height: 60,
                      color: colorScheme.errorContainer.withOpacity(0.3),
                      child: Icon(
                        Icons.broken_image_outlined,
                        size: 32,
                        color: colorScheme.onErrorContainer,
                      ),
                    ),
                  );
                },
              ),
            );
          } else if (snapshot.connectionState == ConnectionState.done) {
            // Errore nel Future (es. path null o non trovato)
            return placeholderOrLoading; // Mostra placeholder generico
          } else {
            // In caricamento: mostra spinner dentro il cerchio
            return ClipOval(
              child: Container(
                width: 60,
                height: 60,
                color: colorScheme.secondaryContainer.withOpacity(0.3),
                child: Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2.0,
                    color: colorScheme.primary,
                  ),
                ),
              ),
            );
          }
        },
      );
    } else {
      // Fallback (dati mancanti)
      iconWidgetContent = placeholderOrLoading;
    }

    // Combina contenuto e placeholder/sfondo con ombra
    final Widget finalIconWidget = Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorScheme.surface, // Sfondo sotto l'icona/placeholder
        boxShadow: [
          // Ombra per l'icona
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 5.0,
            spreadRadius: 1.0,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      // Stack per sovrapporre icona/placeholder (potrebbe non essere necessario
      // se il contenuto (es. Image.file) riempie già il ClipOval)
      child: Center(child: iconWidgetContent),
      // Se iconWidgetContent è già un ClipOval che riempie 60x60,
      // puoi mettere direttamente iconWidgetContent qui invece dello Stack.
      // child: iconWidgetContent,
    );

    // --- COSTRUZIONE CARD CON ANIMAZIONE ---
    return ScaleTransition(
      // Applica animazione di scala
      scale: _scaleAnimation,
      child: Card(
        // Stile della Card
        elevation: 0.5, // Ombra molto leggera per la card
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14.0),
        ), // Angoli più arrotondati?
        color: colorScheme.surface, // Colore di sfondo della card
        surfaceTintColor:
            Colors.transparent, // Evita tinta M3 indesiderata sulla card
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          // Gestione eventi tocco per animazione e azione
          onTapDown: _onTapDown,
          onTapUp: _onTapUp,
          onTapCancel: _onTapCancel,
          // onTap: onTap, // Non serve più qui, chiamato in _onTapUp
          borderRadius: BorderRadius.circular(14.0),
          child: Padding(
            // Padding interno della card
            padding: const EdgeInsets.symmetric(
              vertical: 16.0,
              horizontal: 8.0,
            ),
            child: Column(
              mainAxisAlignment:
                  MainAxisAlignment.center, // Centra verticalmente
              children: [
                // Icona finale (circolare, con ombra)
                finalIconWidget,
                // Spazio tra icona e testo
                const SizedBox(height: 12),
                // Testo (Label)
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    label,
                    style: textTheme.bodyLarge?.copyWith(
                      // Usato bodyLarge per testo più leggibile?
                      color: colorScheme.onSurface, // Colore testo standard
                      fontWeight: FontWeight.w500, // Leggermente più bold?
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2, // Max 2 righe
                    overflow: TextOverflow.ellipsis, // Ellissi se troppo lungo
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
