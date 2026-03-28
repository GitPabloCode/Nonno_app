import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:nonno_app/native/native_methods.dart';
import 'package:nonno_app/providers/theme_notifier.dart';
import 'dart:developer' as developer;

class HomeScreenContent extends StatelessWidget {
  final List<Map<String, String>> favoriteApps;
  final bool isLoading;

  const HomeScreenContent({
    super.key,
    required this.favoriteApps,
    required this.isLoading,
  });

  static final List<Map<String, dynamic>> _fixedItemsData = [
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

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final allItemsData = <Map<String, dynamic>>[..._fixedItemsData];
    for (final app in favoriteApps) {
      allItemsData.add({
        'label': app['appName'] ?? 'Sconosciuta',
        'packageName': app['packageName'] ?? '',
        // FIX: nessuna closure memorizzata — _HomeGridItemState chiama
        // openAppByPackage(packageName) direttamente in _onTapUp, così
        // non rischia di catturare un riferimento obsoleto.
        'isFixed': false,
      });
    }

    if (isLoading) {
      return Center(
        child: CircularProgressIndicator(color: colorScheme.primary),
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
                  maxCrossAxisExtent: 165,
                  childAspectRatio: 0.95,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: allItemsData.length,
                itemBuilder: (context, index) {
                  final itemData = allItemsData[index];
                  return _HomeGridItem(
                    key: ValueKey(itemData['packageName'] ?? itemData['label']),
                    itemData: itemData,
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.brightness_5,
                  color: colorScheme.onSurface.withValues(alpha: 0.7),
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
                  color: colorScheme.onSurface.withValues(alpha: 0.7),
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

// -----------------------------------------------------------------------------
// _HomeGridItem
// -----------------------------------------------------------------------------
class _HomeGridItem extends StatefulWidget {
  final Map<String, dynamic> itemData;

  const _HomeGridItem({super.key, required this.itemData});

  @override
  State<_HomeGridItem> createState() => _HomeGridItemState();
}

class _HomeGridItemState extends State<_HomeGridItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;

  // Cache statica condivisa tra tutte le istanze di questo widget
  static final Map<String, String?> _localIconCache = {};

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
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

  Future<String?> _fetchIconPath(String packageName) async {
    if (packageName.isEmpty) return null;
    if (_localIconCache.containsKey(packageName)) {
      return _localIconCache[packageName];
    }
    try {
      final path = await getAppIconPath(packageName);
      final result = path.isNotEmpty ? path : null;
      if (mounted) _localIconCache[packageName] = result;
      return result;
    } catch (e) {
      developer.log('Errore fetch icon: $e', name: 'HomeGridItem');
      if (mounted) _localIconCache[packageName] = null;
      return null;
    }
  }

  void _onTapDown(TapDownDetails details) => _animationController.forward();

  // FIX: legge packageName e iconData freschi da widget.itemData a ogni tap.
  // Non usa closure memorizzate, quindi non cattura mai un riferimento obsoleto.
  void _onTapUp(TapUpDetails details) {
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) _animationController.reverse();
    });

    final iconData = widget.itemData['iconData'] as IconData?;
    final packageName = widget.itemData['packageName'] as String?;

    if (iconData != null) {
      // Elemento fisso: Telefono / Messaggi
      (widget.itemData['onTap'] as VoidCallback?)?.call();
    } else if (packageName != null && packageName.isNotEmpty) {
      // App preferita: apri tramite package name
      openAppByPackage(packageName).then((success) {
        if (!success && mounted) {
          final label = widget.itemData['label'] as String? ?? 'App';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Impossibile aprire "$label"'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          developer.log(
            'Impossibile aprire $packageName',
            name: 'HomeGridItem',
          );
        }
      });
    }
  }

  void _onTapCancel() {
    if (mounted) _animationController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final label = widget.itemData['label'] as String? ?? 'N/A';
    final iconData = widget.itemData['iconData'] as IconData?;
    final packageName = widget.itemData['packageName'] as String?;

    // Placeholder generico
    final Widget placeholder = ClipOval(
      child: Container(
        width: 60,
        height: 60,
        color: colorScheme.secondaryContainer.withValues(alpha: 0.3),
        child: Icon(
          Icons.apps,
          size: 32,
          color: colorScheme.onSecondaryContainer.withValues(alpha: 0.6),
        ),
      ),
    );

    final Widget iconWidgetContent;

    if (iconData != null) {
      // Elementi fissi (Telefono, Messaggi)
      iconWidgetContent = ClipOval(
        child: Container(
          width: 60,
          height: 60,
          color: colorScheme.primaryContainer,
          child: Icon(
            iconData,
            size: 36,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
      );
    } else if (packageName != null && packageName.isNotEmpty) {
      // App preferita: icona caricata async
      iconWidgetContent = FutureBuilder<String?>(
        future: _fetchIconPath(packageName),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            final path = snapshot.data;
            if (path != null) {
              return ClipOval(
                child: Image.file(
                  File(path),
                  width: 60,
                  height: 60,
                  fit: BoxFit.cover,
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
                      'Errore Image.file: $error',
                      name: 'HomeGridItem',
                    );
                    _localIconCache.remove(packageName);
                    return ClipOval(
                      child: Container(
                        width: 60,
                        height: 60,
                        color: colorScheme.errorContainer.withValues(
                          alpha: 0.3,
                        ),
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
            }
            // Path null → placeholder
            return placeholder;
          }
          // In caricamento
          return ClipOval(
            child: Container(
              width: 60,
              height: 60,
              color: colorScheme.secondaryContainer.withValues(alpha: 0.3),
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.0,
                  color: colorScheme.primary,
                ),
              ),
            ),
          );
        },
      );
    } else {
      iconWidgetContent = placeholder;
    }

    final finalIconWidget = Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 5.0,
            spreadRadius: 1.0,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Center(child: iconWidgetContent),
    );

    return ScaleTransition(
      scale: _scaleAnimation,
      child: Card(
        elevation: 0.5,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14.0),
        ),
        color: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTapDown: _onTapDown,
          onTapUp: _onTapUp,
          onTapCancel: _onTapCancel,
          borderRadius: BorderRadius.circular(14.0),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 16.0,
              horizontal: 8.0,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                finalIconWidget,
                const SizedBox(height: 12),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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
