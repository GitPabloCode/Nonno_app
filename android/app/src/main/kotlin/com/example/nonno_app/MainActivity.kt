package com.example.nonno_app // <-- IMPORTANTE: Sostituisci con il tuo package name effettivo!

import android.app.AlertDialog
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.LauncherApps
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
// Rimosso import ConnectivityManager, NetworkCapabilities, BatteryManager se getSystemStatus non è più usato
import android.net.Uri
import android.os.Bundle
import android.os.UserManager
import android.provider.Settings
import android.telecom.TelecomManager
import android.util.Log
import android.widget.Toast
import androidx.core.content.getSystemService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel // Necessario per EventChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    // Canale per chiamate Metodo (Flutter -> Native)
    private val METHOD_CHANNEL_NAME = "my_apps_channel"
    // Canale per Eventi (Native -> Flutter)
    private val EVENT_CHANNEL_NAME = "com.example.nonno_app/package_events" // Usa il tuo package name
    private val TAG = "MainActivity"

    companion object {
        // Cache per la *lista* di app installate (nome + packageName)
        var cachedAppsList: List<Map<String, Any>>? = null
        // Lock per la sincronizzazione dell’accesso a cachedAppsList
        private val cacheLock = Any()
    }

    // --- Gestore per EventChannel ---
    private var eventSink: EventChannel.EventSink? = null
    // Implementa l'interfaccia StreamHandler per gestire il ciclo di vita dello stream di eventi
    private val packageStreamHandler = object : EventChannel.StreamHandler {
        // Chiamato quando Flutter inizia ad ascoltare
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            Log.d(TAG, "EventChannel [${EVENT_CHANNEL_NAME}]: onListen")
            eventSink = events // Salva l'oggetto 'sink' per inviare eventi a Flutter
        }

        // Chiamato quando Flutter smette di ascoltare
        override fun onCancel(arguments: Any?) {
            Log.d(TAG, "EventChannel [${EVENT_CHANNEL_NAME}]: onCancel")
            eventSink = null // Rimuovi il riferimento al sink
        }
    }
    // --- Fine Gestore EventChannel ---


    // BroadcastReceiver per rilevare installazione/rimozione/aggiornamento app
    private val packageChangeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val action = intent.action
            val packageName = intent.data?.schemeSpecificPart // Ottieni il package name dall'URI
            Log.d(TAG, "BroadcastReceiver: Ricevuto azione '$action' per package '$packageName'")

            // 1. Invalida sempre la cache della lista app nativa
            synchronized(cacheLock) {
                cachedAppsList = null
                Log.d(TAG,"Cache app nativa invalidata.")
            }

            // 2. Se Flutter sta ascoltando (eventSink != null) e abbiamo un package name, invia l'evento
            if (packageName != null && eventSink != null) {
                val eventData = mutableMapOf<String, String>()
                eventData["packageName"] = packageName

                when (action) {
                    Intent.ACTION_PACKAGE_REMOVED -> {
                        Log.d(TAG, "Inviando evento 'package_removed' a Flutter per: $packageName")
                        eventData["event"] = "package_removed"
                        // Usa post su UI thread se necessario, ma success dovrebbe gestirlo
                        runOnUiThread { eventSink?.success(eventData) }
                    }
                    Intent.ACTION_PACKAGE_ADDED -> {
                         Log.d(TAG, "Inviando evento 'package_added' a Flutter per: $packageName")
                         eventData["event"] = "package_added"
                         runOnUiThread { eventSink?.success(eventData) }
                    }
                    Intent.ACTION_PACKAGE_CHANGED -> {
                        // Potresti voler inviare anche questo evento se ti serve
                         Log.d(TAG, "Pacchetto cambiato (non inviato a Flutter): $packageName")
                    }
                }
            } else if (packageName == null) {
                Log.w(TAG, "BroadcastReceiver: Ricevuto azione '$action' ma packageName è null.")
            } else {
                 Log.d(TAG, "BroadcastReceiver: Ricevuto azione '$action' per '$packageName', ma eventSink è null (Flutter non in ascolto).")
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Registra il receiver per azioni di install/remove/change app
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addAction(Intent.ACTION_PACKAGE_CHANGED)
            addDataScheme("package") // Cruciale per ottenere il package name in intent.data
        }
        registerReceiver(packageChangeReceiver, filter)
        Log.d(TAG,"packageChangeReceiver registrato.")

        // Se non è il launcher predefinito, chiedi se impostarlo (opzionale)
        if (!isDefaultLauncher()) {
            // askUserToSetAsDefaultLauncher() // Commentato per evitare pop-up continui durante test
            Log.d(TAG,"Questa app non è il launcher predefinito.")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        // Deregistra il receiver quando l'activity viene distrutta
        unregisterReceiver(packageChangeReceiver)
        Log.d(TAG,"packageChangeReceiver de-registrato.")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "Configurazione FlutterEngine...")

        // --- 1. Configura MethodChannel (Flutter -> Native) ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                Log.d(TAG, "MethodChannel: Ricevuta chiamata '${call.method}'")
                when (call.method) {
                    "openPhone" -> {
                        try {
                            // Tenta prima "Nonno Phone", poi dialer default, poi ACTION_DIAL
                            val nonnoPhonePackage = "com.example.nonno_phone_app" // Assicurati sia corretto
                            val nonnoPhoneIntent = packageManager.getLaunchIntentForPackage(nonnoPhonePackage)
                            if (nonnoPhoneIntent != null) {
                                nonnoPhoneIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(nonnoPhoneIntent)
                                result.success(true)
                            } else {
                                val telecomManager = getSystemService(TELECOM_SERVICE) as? TelecomManager
                                val defaultDialer = telecomManager?.defaultDialerPackage
                                val launchIntent = if (defaultDialer != null) packageManager.getLaunchIntentForPackage(defaultDialer) else null

                                if (launchIntent != null) {
                                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    startActivity(launchIntent)
                                    result.success(true)
                                } else {
                                    val dialIntent = Intent(Intent.ACTION_DIAL) // Apre dialer con tastierino
                                    dialIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                     try {
                                         startActivity(dialIntent)
                                         result.success(true)
                                     } catch (e: Exception) {
                                         Log.e(TAG, "Errore fallback ACTION_DIAL: ${e.message}")
                                         result.error("UNAVAILABLE", "Nessuna app telefono trovata.", null)
                                     }
                                }
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Errore openPhone: ${e.message}")
                            result.error("ERROR", "Errore apertura telefono", e.message)
                        }
                    }
                    "openMessages" -> {
                        try {
                            val intent = Intent(Intent.ACTION_MAIN)
                            intent.addCategory(Intent.CATEGORY_APP_MESSAGING)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "Errore openMessages: ${e.message}")
                            result.error("ERROR", "Errore apertura messaggi", e.message)
                        }
                    }
                    "getInstalledApps" -> {
                        // Usa la cache o recupera la lista
                        synchronized(cacheLock) {
                            if (cachedAppsList != null) {
                                Log.d(TAG,"getInstalledApps: Restituita lista da cache.")
                                result.success(cachedAppsList)
                                return@setMethodCallHandler
                            }
                        }
                        Log.d(TAG,"getInstalledApps: Cache vuota, recupero lista...")
                        val apps = mutableListOf<Map<String, Any>>()
                        try {
                            val launcherApps = getSystemService<LauncherApps>()
                            val userManager = getSystemService<UserManager>()
                            if (launcherApps == null || userManager == null) {
                                Log.e(TAG,"getInstalledApps: LauncherApps o UserManager non disponibili.")
                                result.error("ERROR", "Servizi di sistema non disponibili", null)
                                return@setMethodCallHandler
                            }
                            val profiles = userManager.userProfiles
                            val packageSet = mutableSetOf<String>() // Per evitare duplicati tra profili
                            for (profile in profiles) {
                                val activities = launcherApps.getActivityList(null, profile)
                                for (activityInfo in activities) {
                                    val appInfo = activityInfo.applicationInfo
                                    val packageName = appInfo.packageName
                                    // Salta se è l'app stessa o già aggiunto
                                    if (packageName == applicationContext.packageName || !packageSet.add(packageName)) {
                                        continue
                                    }
                                    val appName = activityInfo.label?.toString() ?: appInfo.loadLabel(packageManager).toString() ?: packageName
                                    val appMap = mapOf(
                                        "appName" to appName,
                                        "packageName" to packageName
                                    )
                                    apps.add(appMap)
                                }
                            }
                            apps.sortBy { (it["appName"] as String).lowercase() } // Ordina alfabeticamente
                            synchronized(cacheLock) {
                                cachedAppsList = apps // Salva in cache
                            }
                             Log.d(TAG,"getInstalledApps: Lista recuperata (${apps.size} app) e messa in cache.")
                            result.success(apps)
                        } catch (e: Exception) {
                            Log.e(TAG, "Errore getInstalledApps: ${e.message}")
                            result.error("ERROR", "Errore recupero lista app", e.message)
                        }
                    }
                    "getAppIconPath" -> {
                        // Ottieni percorso icona (usa cache file)
                        val packageName = call.argument<String>("packageName")
                        if (packageName.isNullOrEmpty()) {
                            result.success("") // Ritorna stringa vuota per package nullo/vuoto
                            return@setMethodCallHandler
                        }
                        try {
                            val cacheDir = context.cacheDir ?: run {
                                Log.e(TAG, "getAppIconPath: Impossibile ottenere cacheDir.")
                                result.error("ERROR", "Cache directory non disponibile", null)
                                return@setMethodCallHandler
                            }
                            val iconFileName = "$packageName.png"
                            val iconFile = File(cacheDir, iconFileName)

                            if (iconFile.exists() && iconFile.length() > 0) {
                                result.success(iconFile.absolutePath) // Icona trovata in cache file
                            } else {
                                // Icona non in cache, la carico e la salvo
                                val iconDrawable = try {
                                    applicationContext.packageManager.getApplicationIcon(packageName)
                                } catch (e: PackageManager.NameNotFoundException) {
                                    Log.w(TAG, "getAppIconPath: Icona non trovata per $packageName")
                                    null
                                }
                                if (iconDrawable != null) {
                                    val savedPath = saveDrawableToFile(iconDrawable, iconFileName)
                                    result.success(savedPath) // Ritorna path salvato
                                } else {
                                    result.success("") // Ritorna stringa vuota se icona non trovata
                                }
                            }
                        } catch (e: Exception) {
                             Log.e(TAG, "Errore getAppIconPath per $packageName: ${e.message}")
                             result.error("ERROR", "Errore recupero icona per $packageName", e.message)
                        }
                    }
                    "openApp" -> {
                        // Avvia un'app dal package name
                        val packageName = call.argument<String>("packageName")
                        if (!packageName.isNullOrEmpty()) {
                            try {
                                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                                if (launchIntent != null) {
                                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    startActivity(launchIntent)
                                    result.success(true)
                                } else {
                                     Log.w(TAG, "openApp: Launch intent nullo per $packageName")
                                    result.success(false) // App non avviabile
                                }
                            } catch (e: Exception) {
                                Log.e(TAG, "Errore openApp per $packageName: ${e.message}")
                                result.error("ERROR", "Errore apertura app $packageName", e.message)
                            }
                        } else {
                            result.success(false) // Package name vuoto
                        }
                    }
                    "uninstallApp" -> {
                        // Avvia l'intent di sistema per disinstallare l'app
                        val packageName = call.argument<String>("packageName")
                        if (!packageName.isNullOrEmpty()) {
                            try {
                                val intent = Intent(Intent.ACTION_DELETE)
                                intent.data = Uri.parse("package:$packageName")
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(intent)
                                // NON fare altro qui, la notifica avverrà tramite EventChannel
                                // quando il BroadcastReceiver rileverà l'azione completata.
                                Log.d(TAG,"uninstallApp: Avviato intent ACTION_DELETE per $packageName")
                                result.success(true) // Segnala solo che l'intent è partito
                            } catch (e: Exception) {
                                Log.e(TAG, "Errore uninstallApp per $packageName: ${e.message}")
                                result.error("ERROR", "Errore avvio disinstallazione per $packageName", e.message)
                            }
                        } else {
                            result.success(false) // Package name vuoto
                        }
                    }
                    "revertLauncher" -> {
                        // Apre le impostazioni per cambiare launcher
                        revertToAnotherLauncher()
                        result.success(true)
                    }

                    // --- Metodi Rimossi (perché UI rimossa da Flutter) ---
                    // "getSystemStatus", "openWifiSettings", "openMobileDataSettings", "openHotspotSettings"
                    // sono stati rimossi perché non più chiamati dal codice Dart attuale.
                    // Se necessario, possono essere reintrodotti.
                    // --- Fine Metodi Rimossi ---

                    else -> result.notImplemented()
                }
            }
         Log.d(TAG, "MethodChannel [${METHOD_CHANNEL_NAME}] configurato.")

        // --- 2. Configura EventChannel (Native -> Flutter) ---
        val eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL_NAME)
        eventChannel.setStreamHandler(packageStreamHandler) // Usa il gestore definito sopra
        Log.d(TAG, "EventChannel [${EVENT_CHANNEL_NAME}] configurato.")
        // --- Fine Configurazione EventChannel ---

        Log.d(TAG, "Fine configurazione FlutterEngine.")
    }

    // -------------------------------------------------------------------
    // Funzioni di utilità (Mantenute quelle usate)
    // -------------------------------------------------------------------

    private fun saveDrawableToFile(drawable: Drawable?, fileName: String): String {
        if (drawable == null) return ""
        val cacheDir = context.cacheDir ?: return "" // Usa context.cacheDir che è per l'app

        return try {
            // Imposta dimensione desiderata per l'icona salvata (es. 96x96)
            val targetSize = 96 // Puoi aggiustare se necessario
            val bitmap: Bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
                // Se è già una Bitmap, ridimensiona se necessario
                if (drawable.bitmap.width == targetSize && drawable.bitmap.height == targetSize) {
                    drawable.bitmap
                } else {
                    Bitmap.createScaledBitmap(drawable.bitmap, targetSize, targetSize, true)
                }
            } else {
                // Altrimenti disegna il Drawable su una nuova Bitmap
                val bmp = Bitmap.createBitmap(targetSize, targetSize, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                // Imposta i bounds corretti per il disegno
                drawable.setBounds(0, 0, targetSize, targetSize)
                drawable.draw(canvas)
                bmp
            }
            // Salva la bitmap come PNG nella cache directory
            val file = File(cacheDir, fileName)
            FileOutputStream(file).use { fos ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, fos) // 100% qualità PNG
                fos.flush()
            }
            Log.d(TAG, "Icona salvata in: ${file.absolutePath}")
            file.absolutePath // Ritorna il percorso completo del file salvato
        } catch (e: Exception) {
            Log.e(TAG, "Errore nel salvataggio icona $fileName: ${e.message}")
            "" // Ritorna stringa vuota in caso di errore
        }
    }

    private fun isDefaultLauncher(): Boolean {
        // Controlla se questa app è il launcher predefinito attuale
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val resolveInfo = packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
        val currentHomePackage = resolveInfo?.activityInfo?.packageName
        return packageName == currentHomePackage
    }

    private fun askUserToSetAsDefaultLauncher() {
        // Mostra un dialogo per chiedere all'utente di impostare come predefinito
        // Assicurati che il context sia l'Activity (this)
        AlertDialog.Builder(this)
            .setTitle("Imposta come predefinito")
            .setMessage("Vuoi impostare Nonno App come launcher predefinito?")
            .setPositiveButton("Sì") { _, _ ->
                openHomeSettings() // Apre le impostazioni Home di Android
            }
            .setNegativeButton("No", null)
            .setCancelable(false) // Impedisci chiusura accidentale
            .show()
    }

    private fun openHomeSettings() {
        // Apre le impostazioni Home di Android per cambiare launcher
        try {
            val intent = Intent(Settings.ACTION_HOME_SETTINGS)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (e: Exception) {
             Log.e(TAG, "Errore apertura ACTION_HOME_SETTINGS: ${e.message}, fallback...")
             // Fallback generico se ACTION_HOME_SETTINGS non funziona
             try {
                val fallbackIntent = Intent(Settings.ACTION_SETTINGS) // Apre impostazioni generali
                fallbackIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(fallbackIntent)
             } catch (e2: Exception) {
                 Log.e(TAG, "Errore apertura fallback ACTION_SETTINGS: ${e2.message}")
                 Toast.makeText(this, "Impossibile aprire le impostazioni del launcher.", Toast.LENGTH_SHORT).show()
             }
        }
    }

    private fun revertToAnotherLauncher() {
        // Alias per aprire le impostazioni e permettere cambio launcher
        openHomeSettings()
    }

     // --- Funzioni Relative a getSystemStatus RIMOSSE ---
     // Le funzioni openWifiSettings, openMobileDataSettings, openHotspotSettings,
     // getSystemStatus, getBatteryInfo, isHotspotEnabled sono state rimosse
     // perché non più utilizzate dal codice Flutter dopo le modifiche all'interfaccia utente.
     // --- Fine Funzioni Rimossi ---

} // Fine MainActivity