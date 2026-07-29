# JoyCon2Mac — Rapport d'audit IA

> **Auteur** : Antigravity (Google DeepMind)
> **Date** : 2026-07-29
> **Scope** : Audit complet — sécurité, fuites de données, optimisations, qualité de code
> **Fichiers analysés** : 43 fichiers, ~13 700 lignes (100 % du codebase)

Ce document est destiné à d'autres IA travaillant sur ce projet. Il résume ce que j'ai trouvé, ce qui est sûr, ce qui ne l'est pas, et ce qu'il faut corriger.

---

## 1. Qu'est-ce que ce projet ?

JoyCon2Mac connecte des manettes Joy-Con (Nintendo Switch 2) à un Mac via Bluetooth Low Energy et les expose comme des périphériques HID virtuels (gamepad, souris, NFC).

### Architecture en 3 composants

```
┌─────────────────────┐     JSON files      ┌──────────────────┐     IOKit      ┌──────────────────────┐
│  JoyCon2Mac.app     │◄──────────────────►  │  joycon2mac      │◄─────────────► │  local.joycon2mac    │
│  (SwiftUI GUI)      │  ~/Library/App       │  (daemon C++/ObjC)│  UserClient   │  .driver.dext        │
│                     │  Support/JoyCon2Mac/ │                  │               │  (DriverKit HID)     │
└─────────────────────┘                      └──────────────────┘               └──────────────────────┘
        UI seul                              BLE, décodage,                     Gamepad virtuel,
        pas de réseau                        souris, haptics                    DualSense, Mouse HID
```

### Fichiers clés à connaître

| Fichier | Lignes | Rôle |
|---------|--------|------|
| `JoyCon2Mac/main.mm` | 1222 | Point d'entrée daemon, boucle principale, dispatch commandes, rapport HID |
| `JoyCon2Mac/BLEManager.mm` | 2285 | Gestion BLE complète : scan, connexion, init, NFC, commandes Joy-Con |
| `JoyCon2Mac/MouseEmitter.mm` | ~450 | Émulation souris optique → HID mouse reports |
| `JoyCon2Mac/JoyConDecoder.cpp` | 233 | Décodage brut des paquets BLE (boutons, sticks, IMU, batterie) |
| `JoyCon2Mac/DriverKitClient.mm` | ~250 | Wrapper IOKit pour parler au dext |
| `JoyCon2MacApp/DaemonBridge.swift` | 1468 | Bridge GUI↔daemon : parsing JSON, throttling, state management |
| `JoyCon2MacApp/TelemetryStore.swift` | 91 | Buffer de logs avec batch-flush |
| `VirtualJoyConDriver/VirtualJoyConDriver.cpp` | 1412 | Extension DriverKit : 3 devices HID + dispatch table |

### Communication inter-composants

- **GUI → Daemon** : fichier `control.jsonl` (append-only, polling 10 Hz)
- **Daemon → GUI** : fichier `daemon.jsonl` (append-only, polling 125 Hz)
- **Daemon → Dext** : `IOConnectCallStructMethod` (IOKit UserClient, selectors 0-4)
- **Dext → Daemon** : selector 3 (rumble report, polling 60 Hz)

**Aucune communication réseau n'existe dans le projet.**

---

## 2. Résultat sécurité : SAIN

### Ce que j'ai vérifié

| Vérification | Résultat | Méthode |
|---|---|---|
| Connexions réseau sortantes | ❌ Aucune | Grep `NSURLSession`, `URLRequest`, `socket`, `connect`, `curl`, `wget` → 0 résultat |
| Exécution de code arbitraire | ❌ Aucune | Grep `NSTask`, `system(`, `popen(`, `exec(`, `eval(` → 0 résultat |
| Obfuscation / code caché | ❌ Aucune | Les blobs binaires dans `PairingManager.mm` sont des commandes MAC-binding Joy2Win documentées |
| Analytics / tracking | ❌ Aucun | Pas de SDK tiers, pas de Firebase, pas de Sentry |
| Clipboard leak | ❌ Aucun | `NSPasteboard` uniquement sur action utilisateur explicite |
| Keychain / secrets | N/A | Aucun secret n'est stocké |
| Dépendances externes | ❌ Aucune | Zéro dépendance npm/pip/pod/swift-package. Build scripts ne téléchargent rien |
| Build script injection | ❌ Aucune | `build_all.sh` / `build_gui.sh` / `build_driver.sh` sont propres, `set -euo pipefail` |

### Points de vigilance (pas des vulnérabilités, mais à documenter)

#### V1 — SIP/AMFI désactivés (risque système)

**Où** : Prérequis d'installation (README)
**Quoi** : Le dext n'est pas signé Apple → nécessite `csrutil disable` + `amfi_get_out_of_my_way=1` au boot. Cela réduit la sécurité globale du Mac (n'importe quel kext/dext non signé peut être chargé).
**Impact** : Élevé (mais c'est un compromis accepté pour le développement local)
**Recommandation** : Obtenir un certificat Developer ID avec DriverKit provisioning pour signer le dext. Documenter clairement le risque pour les utilisateurs.

#### V2 — Dext ouvert à tous les processus

**Où** : `VirtualJoyConDriver/VirtualJoyConDriver.entitlements` ligne 11
```xml
<key>com.apple.developer.driverkit.allow-any-userclient-access</key>
<true/>
```
**Quoi** : N'importe quel processus peut ouvrir un `IOUserClient` vers le dext et envoyer des gamepad/mouse/NFC reports.
**Impact** : Moyen — un processus malveillant pourrait injecter de faux inputs HID.
**Recommandation** : Vérifier l'audit token de l'appelant dans `NewUserClient_Impl()` ou restreindre l'entitlement.

#### V3 — Fichier IPC sans restriction de permissions

**Où** : `JoyCon2Mac/main.mm` lignes 587-629 et 631-655
```objc
// Le daemon crée control.jsonl avec les permissions par défaut (world-readable/writable)
[[NSFileManager defaultManager] createFileAtPath:g_controlFilePath
                                        contents:nil
                                      attributes:nil];
```
**Quoi** : `control.jsonl` est créé avec les permissions par défaut du filesystem. Un autre processus local pourrait y écrire des commandes (`setMouseMode`, `scanNFC`, `setRailBindings`, etc.)
**Impact** : Faible (attaque locale uniquement, commandes limitées au changement de mode)
**Recommandation** : Créer le fichier avec permissions `0600` :
```objc
NSDictionary *attrs = @{ NSFilePosixPermissions: @(0600) };
[[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:attrs];
```

#### V4 — Adresses MAC BLE en clair dans les logs

**Où** : `PairingManager.mm` ligne 23, `BLEManager.mm` (multiples `emitTelemetry`)
**Quoi** : Les adresses MAC Bluetooth sont loggées en clair et stockées dans `NSUserDefaults`.
**Impact** : Très faible (tout est local, pas de réseau)
**Recommandation** : Masquer les 3 derniers octets dans les logs de production.

#### V5 — Import config sans validation de ranges

**Où** : `JoyCon2MacApp/SettingsView.swift` lignes 233-253
**Quoi** : `importConfig()` applique les valeurs du JSON sans vérifier les bornes.
**Impact** : Faible — peut mettre `deadzone` ou `stickSensitivity` hors-limites, mais ces valeurs ne sont de toute façon pas envoyées au daemon (voir bug L1 ci-dessous).
**Recommandation** : `deadzone = max(0, min(0.3, value))`, `sensitivity = max(0.5, min(2.0, value))`.

---

## 3. Bugs identifiés (priorité haute)

### H1 — Data race dans TelemetryStore

**Où** : `JoyCon2MacApp/TelemetryStore.swift` lignes 32-39

```swift
// Appelé depuis ingestQueue (background) :
func append(_ line: String) {
    pendingLines.append(line)         // ← Mutation sur background thread
    if pendingLines.count > maxStoredLines * 2 {
        pendingLines.removeFirst(...)  // ← Mutation sur background thread
    }
    scheduleFlush()
}

// flush() est appelé depuis un Timer sur le main thread :
private func flush() {
    let batch = pendingLines           // ← Lecture sur main thread
    pendingLines.removeAll(...)        // ← Mutation sur main thread
}
```

**Problème** : `pendingLines` est muté depuis deux threads différents sans synchronisation.
**Fix** : Ajouter un `DispatchQueue` de sérialisation interne, ou déplacer `append()` sur le main thread via `DispatchQueue.main.async`.

### H2 — Settings UI déconnectés du daemon

**Où** : `JoyCon2MacApp/SettingsView.swift` lignes 110-128 + `JoyCon2Mac/JoyConDecoder.cpp` lignes 120-126

```swift
// GUI — l'utilisateur ajuste ces sliders :
@AppStorage("deadzone") private var deadzone: Double = 0.08
@AppStorage("stickSensitivity") private var stickSensitivity: Double = 1.0
```

```cpp
// Daemon — valeurs en dur, jamais modifiées :
const float deadzone = 0.08f;
x = std::clamp(x * 1.7f, -1.0f, 1.0f);  // 1.7 = sensitivity fixe
```

**Problème** : Les paramètres de la GUI n'ont absolument aucun effet. Le daemon utilise des constantes.
**Fix** : Ajouter une commande `setDeadzone` / `setSensitivity` via le fichier `control.jsonl` existant, et modifier `JoyConDecoder` pour accepter ces valeurs en paramètre plutôt qu'en constante.

### H3 — Bouton "Calibrate Sticks" vide

**Où** : `JoyCon2MacApp/SettingsView.swift` lignes 126-128
```swift
Button("Calibrate Sticks") {
    // Open calibration wizard   ← Body vide
}
```
**Recommandation** : Implémenter ou retirer le bouton.

### H4 — `launchAtLogin` non implémenté

**Où** : `JoyCon2MacApp/SettingsView.swift` ligne 6
```swift
@AppStorage("launchAtLogin") private var launchAtLogin = false
```
Aucun appel à `SMAppService.register()` / `SMLoginItemSetEnabled` nulle part.

---

## 4. Optimisations recommandées

### Performance (par ordre d'impact)

#### P1 — NFC decoder O(n²)

**Où** : `JoyCon2MacApp/DaemonBridge.swift` lignes 134-143
```swift
private static func decodeNDEFContainers(in data: Data) -> [NFCDecodedRecord] {
    let bytes = Array(data)
    for offset in bytes.indices {                    // ← O(n)
        records.append(contentsOf: decodeTLV(...))   // ← O(n) chacun
        records.append(contentsOf: decodeNDEFRecords(...))
    }
}
```
**Fix** : Parser le TLV séquentiellement plutôt que de tester chaque offset. Le TLV est un format à longueur préfixée — on peut sauter directement au prochain record.

#### P2 — `std::ostringstream` sur le hot path (240 Hz)

**Où** : `JoyCon2Mac/main.mm` lignes 810-844
```cpp
std::ostringstream out;  // ← allocation heap à chaque appel
out << "{\"event\":\"state\",...";
```
**Fix** : Remplacer par `snprintf` dans un `char[512]` stack-allocated. Gain estimé : ~2-3 µs/appel × 240/s = ~600 µs/s de GC/heap en moins.

#### P3 — File polling ouvre/ferme le fichier 125×/s

**Où** : `JoyCon2MacApp/DaemonBridge.swift` lignes 758-772
```swift
let handle = try? FileHandle(forReadingFrom: daemonLogPath)  // ← open()
try handle.seek(toOffset: daemonLogOffset)
let data = handle.readDataToEndOfFile()
try handle.close()  // ← close()
```
**Fix** : Garder un `FileHandle` persistant. Le réouvrir uniquement si le fichier est tronqué (offset reset).

#### P4 — `ingestQueue.sync` bloque le main thread

**Où** : `JoyCon2MacApp/DaemonBridge.swift` lignes 1060-1067
```swift
let (states, statuses) = ingestQueue.sync {  // ← Bloque main thread
    let s = pendingStateSnapshots
    ...
}
```
**Fix** : Double-buffering — l'ingest queue remplit le buffer A, le main thread lit le buffer B, et on swap atomiquement.

### Qualité de code

| # | Quoi | Où | Fix |
|---|---|---|---|
| Q1 | Version hard-codée `"1.0.0"` | SettingsView.swift L175 | Lire `Bundle.main.infoDictionary` |
| Q2 | ~40 variables `static` globales | main.mm L49-89 | Encapsuler dans une `struct DaemonState` |
| Q3 | `Thread.sleep(0.05)` sur main thread | DaemonBridge.swift L570 | Remplacer par `DispatchQueue.main.asyncAfter` |
| Q4 | Byte 0x1F partagé entre `current_raw` et `level_raw` | JoyConDecoder.cpp L204/L213 | Vérifier la spec du protocole Joy-Con, possible erreur de décodage batterie |
| Q5 | `pendingOutput` potentielle data race | DaemonBridge.swift L364 | Variable accédée sur ingestQueue mais déclarée hors protection |

---

## 5. Ce qui est BIEN fait (ne pas casser)

Ces éléments sont bien conçus et ne doivent pas être modifiés sans bonne raison :

1. **Throttling display-rate** dans `DaemonBridge` (120 Hz gate par côté) — empêche le freeze UI
2. **Change-triggered input tracing** — les logs `[RS-DEC]`, `[HID-TX]`, `[UI R]` ne spamment pas quand idle
3. **Séparation gamepad/mouse/NFC en 3 devices HID distincts** — sinon macOS classifie le device composite comme `GCMouse` uniquement
4. **DualSense compatibility layer** avec VID/PID Sony réels — nécessaire pour SDL, Chrome, cloud gaming
5. **Generation counter** dans `DaemonBridge.startDaemon()` — empêche les callbacks de terminaison stale de tuer un nouveau daemon
6. **Picker flicker guard** (`pendingMouseMode` / `pendingEchoWindow`) — évite le bounce visuel pendant le round-trip GUI→daemon→GUI
7. **Rail binding sanitization** (`sanitizedRailTarget`) — whitelist stricte des cibles valides
8. **`applyControlCommand` validation** — vérifie les types (`isKindOfClass`) et les ranges avant application
9. **DriverKit dispatch table avec tailles de struct fixes** — rejet automatique des payloads de mauvaise taille

---

## 6. Contexte pour les futures modifications

### Si tu modifies le décodeur de paquets (`JoyConDecoder.cpp`)
- Les offsets sont spécifiques au Joy-Con 2 (Switch 2). Le Joy-Con 1 a un format différent.
- La calibration stick est **statique** — elle persiste tant que le processus tourne. C'est intentionnel.
- Le `1.7f` multiplier est un gain de sensibilité empirique, pas une valeur de spec.

### Si tu modifies le DriverKit (`VirtualJoyConDriver.cpp`)
- Les `static_assert` et `__attribute__((packed))` sont critiques. Les structs doivent correspondre byte-pour-byte aux descripteurs HID.
- Le DualSense device utilise les VID/PID Sony réels (`054C:0CE6`). C'est nécessaire pour que SDL/Chrome le reconnaissent.
- Le `g_latestRumbleReport` est un global partagé entre tous les selectors — pas de thread safety, mais OK car tout passe par le même IOKit dispatch thread.

### Si tu modifies la communication GUI↔daemon
- Le fichier `control.jsonl` est append-only. Le daemon poll à 10 Hz et lit les nouvelles lignes.
- Le fichier `daemon.jsonl` est append-only. La GUI poll à 125 Hz et lit les nouvelles lignes.
- Le format est JSONL (une ligne = un objet JSON). Les lignes partielles sont gérées (`pendingOutput`).
- Ne pas introduire de XPC ou Mach ports — la simplicité fichier-JSON est un choix architectural délibéré pour éviter les problèmes de signing/entitlements.

### Si tu modifies le mouse emitter (`MouseEmitter.mm`)
- Le `processBuffer:side:buttonState:stickReading:mouseDistance:` **mute le buffer** pour supprimer les inputs HID consommés par la souris. C'est intentionnel — le gamepad ne doit pas voir les boutons/sticks que la souris utilise.
- La distinction surface/airborne se fait via `mouseDistance` (0 = sur surface, >0 = en l'air).
- Le source `Auto` choisit automatiquement le Joy-Con qui est sur une surface.

---

## 7. Commandes utiles

```bash
# Build complet
./build_all.sh

# Voir les logs en temps réel
tail -f ~/Library/Application\ Support/JoyCon2Mac/daemon.jsonl | python3 -m json.tool

# Trace input (stick/boutons/HID pipeline)
tail -f ~/Library/Application\ Support/JoyCon2Mac/input-trace.log

# Vérifier si le dext est chargé
systemextensionsctl list | grep joycon2mac

# Tuer le daemon manuellement
pkill -f joycon2mac
```

---

## 8. Résumé exécutif

| Catégorie | Verdict |
|---|---|
| **Backdoors** | ❌ Aucune trouvée |
| **Fuites de données** | ❌ Aucune (zéro réseau) |
| **Vulnérabilités critiques** | ❌ Aucune |
| **Points de vigilance** | ⚠️ 5 (SIP/AMFI, dext permissions, IPC file perms, MAC logging, import validation) |
| **Bugs fonctionnels** | 🔴 4 (data race, settings déconnectés, boutons vides, launch-at-login) |
| **Optimisations perf** | 🟡 4 (NFC O(n²), ostringstream, file polling, sync blocking) |
| **Qualité de code** | 🟢 5 (version hardcoded, globals, Thread.sleep, byte overlap, data race) |
| **Architecture** | ✅ Solide et bien pensée |

**Le projet est sûr pour une utilisation locale.** Les améliorations recommandées sont des optimisations et des corrections de bugs, pas des corrections de sécurité critiques.
