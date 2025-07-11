import 'package:flutter/services.dart';
import 'dart:developer' as developer;

const MethodChannel _channel = MethodChannel('my_apps_channel');
const String _tag = 'NativeMethods';

Future<void> openPhone() async {
  try {
    await _channel.invokeMethod('openPhone');
  } on PlatformException catch (e) {
    developer.log(
      "Errore apertura telefono: ${e.message}",
      name: _tag,
      error: e,
    );
  }
}

Future<void> openMessages() async {
  try {
    await _channel.invokeMethod('openMessages');
  } on PlatformException catch (e) {
    developer.log(
      "Errore apertura messaggi: ${e.message}",
      name: _tag,
      error: e,
    );
  }
}

/// Restituisce una lista di Map con 'appName' e 'packageName'
Future<List<Map<String, String>>> getInstalledApps() async {
  try {
    final List<dynamic>? result = await _channel.invokeMethod(
      'getInstalledApps',
    );
    if (result == null) return [];

    final apps =
        result
            .map((item) {
              if (item is Map) {
                return {
                  'appName': item['appName'] as String? ?? 'App sconosciuta',
                  'packageName': item['packageName'] as String? ?? '',
                };
              }
              return {'appName': '', 'packageName': ''};
            })
            .where((app) => app['packageName']!.isNotEmpty)
            .toList();

    return List<Map<String, String>>.from(apps);
  } on PlatformException catch (e) {
    developer.log(
      "Errore getInstalledApps: ${e.message}",
      name: _tag,
      error: e,
    );
    return [];
  }
}

/// Ottiene il path dell'icona per un'app specifica (se presente in cache/nativa)
Future<String> getAppIconPath(String packageName) async {
  if (packageName.isEmpty) return "";
  try {
    final String? path = await _channel.invokeMethod<String>('getAppIconPath', {
      'packageName': packageName,
    });
    return path ?? "";
  } on PlatformException catch (e) {
    developer.log("Errore getAppIconPath: ${e.message}", name: _tag, error: e);
    return "";
  }
}

Future<bool> openAppByPackage(String packageName) async {
  if (packageName.isEmpty) return false;
  try {
    final bool? result = await _channel.invokeMethod<bool>('openApp', {
      'packageName': packageName,
    });
    return result ?? false;
  } on PlatformException catch (e) {
    developer.log(
      "Errore openAppByPackage: ${e.message}",
      name: _tag,
      error: e,
    );
    return false;
  }
}

/// Se Nonno App è già il launcher e vuoi tornare ad un altro launcher
Future<void> revertLauncher() async {
  try {
    await _channel.invokeMethod('revertLauncher');
  } on PlatformException catch (e) {
    developer.log("Errore revertLauncher: ${e.message}", name: _tag, error: e);
  }
}

/// Disinstalla l'app col packageName (chiede conferma all'utente)
Future<bool> uninstallAppByPackage(String packageName) async {
  if (packageName.isEmpty) return false;
  try {
    final bool? result = await _channel.invokeMethod<bool>('uninstallApp', {
      'packageName': packageName,
    });
    return result ?? false;
  } on PlatformException catch (e) {
    developer.log(
      "Errore uninstallAppByPackage: ${e.message}",
      name: _tag,
      error: e,
    );
    return false;
  }
}
