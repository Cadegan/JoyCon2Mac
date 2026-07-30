# JoyCon2Mac — Feuille de route avant test matériel

> **Créé le** : 2026-07-30  
> **Objectif** : obtenir un bundle testable sur un Mac Apple Silicon, sans ambiguïté de signature, de calibration ou d'état dans l'interface.  
> **Règle projet** : ne jamais exécuter `git push` depuis une IA.

## 1. État actuel

L'architecture ciblée est :

1. `JoyCon2Mac.app` gère l'interface, les préférences et l'activation de l'extension.
2. `JoyCon2MacDaemon.app` gère le Bluetooth, le décodage et les commandes Joy-Con.
3. `local.joycon2mac.driver.dext` publie les périphériques HID virtuels.

Les améliorations suivantes sont intégrées au commit `f90d96d`, mais restent à valider sur matériel :

- décodage NFC Type 2 et messages NDEF multi-enregistrements ;
- précision restaurée pour l'accéléromètre et le gyroscope ;
- bornes et valeurs par défaut des sticks harmonisées ;
- `control.jsonl` limité aux permissions `0600` ;
- vrai réglage macOS « Launch at Login » ;
- effacement fiable de la vue des journaux.

Depuis la création de cette feuille de route, les corrections logicielles de signature
imbriquée, de calibration, de réglages et de pré-vol ont été implémentées. La validation
réelle du bundle produit a également passé le pré-vol local. L'activation effective de
l'extension et les entrées restent à confirmer avec le matériel.

### Avancement au 2026-07-30

- [x] CMake installé et tests natifs exécutables.
- [x] Ordre de signature interne vers externe implémenté, sans `codesign --deep` à la signature.
- [x] Pré-vol du bundle ajouté à `build_all.sh`.
- [x] Calibration déterministe et commande manuelle reliées à l'interface.
- [x] Réglages sans effet retirés de l'interface et de l'export.
- [x] Licence Xcode acceptée et SDK DriverKit disponible.
- [x] Build DriverKit complet, signature et entitlements vérifiés sur le bundle produit.
- [ ] Matrice de test matériel exécutée.

Dernière validation logicielle : `./build_all.sh` termine avec
`Ready for hardware test`, et `ctest --test-dir build --output-on-failure`
valide tous les tests de calibration.

## 2. Ordre recommandé

| Priorité | Chantier | Condition de sortie |
|---|---|---|
| P0 | Préparer la chaîne de build | Xcode, DriverKit et CMake répondent sans erreur |
| P0 | Corriger la signature du bundle | Les entitlements DriverKit sont encore présents après intégration dans l'app |
| P0 | Fiabiliser la calibration des sticks | Un stick maintenu hors centre ne peut jamais devenir le nouveau neutre |
| P1 | Retirer ou relier les réglages inactifs | Aucun contrôle visible ne prétend faire une action inexistante |
| P1 | Ajouter des contrôles de pré-vol | Le build échoue clairement si le `.dext` est absent ou invalide |
| P2 | Exécuter la matrice matérielle | Gamepad, souris, IMU, NFC et haptics validés |

---

## 3. P0 — Préparer la chaîne de build

### État observé le 2026-07-30

- machine : Apple Silicon, macOS 26.5.1 ;
- `cmake` 4.4.1 installé et présent dans le `PATH` ;
- licence Xcode acceptée ;
- SDK DriverKit 25.5 disponible ;
- le typage et la liaison Swift fonctionnent en appelant directement le compilateur Xcode ;
- le daemon C++/Objective-C++ compile et se lie ;
- les tests unitaires de calibration passent.

### Actions

- [x] Accepter la licence Xcode :

  ```bash
  sudo xcodebuild -license accept
  ```

- [x] Installer CMake et confirmer sa disponibilité :

  ```bash
  cmake --version
  ```

- [x] Vérifier le SDK DriverKit :

  ```bash
  xcrun --sdk driverkit --show-sdk-path
  ```

- [x] Vérifier que l'identité ou la signature ad hoc prévue pour le test est explicitement choisie.
- [ ] Utiliser uniquement un Mac de développement isolé si SIP/AMFI doivent être désactivés.
- [ ] Documenter la procédure de restauration de SIP/AMFI après le test.

### Critère d'acceptation

`./build_all.sh` doit pouvoir commencer le build DriverKit sans erreur de licence, de SDK ou de commande manquante.

---

## 4. P0 — Préserver la signature et les entitlements DriverKit

### Problème

`build_driver.sh` signe d'abord correctement le `.dext` avec ses entitlements DriverKit. Ensuite, `build_all.sh` resigne l'app avec `codesign --deep` après avoir copié le `.dext`.

Une signature récursive forcée peut re-signer les composants imbriqués avec les options et entitlements de l'app principale. L'extension risque alors de perdre :

- `com.apple.developer.driverkit` ;
- `com.apple.developer.driverkit.family.hid.device` ;
- `com.apple.developer.driverkit.transport.hid` ;
- `com.apple.developer.driverkit.allow-any-userclient-access`.

### Fichiers concernés

- `build_gui.sh`
- `build_all.sh`
- `build_driver.sh`
- `JoyCon2MacApp/JoyCon2Mac.entitlements`
- `VirtualJoyConDriver/VirtualJoyConDriver.entitlements`

### Implémentation

- [x] Signer les composants de l'intérieur vers l'extérieur :

  1. binaire et bundle `local.joycon2mac.driver.dext` ;
  2. `JoyCon2MacDaemon.app` ;
  3. `JoyCon2Mac.app`.

- [x] Ne pas utiliser `--deep` pour signer l'app.
- [x] Conserver `--deep` uniquement pour une vérification finale, si nécessaire.
- [x] Après copie du `.dext`, re-signer uniquement le bundle extérieur de l'app.
- [x] Faire échouer `build_all.sh` si :

  - le build du driver échoue et aucun `.dext` précompilé n'est disponible ;
  - le `.dext` n'existe pas dans `Contents/Library/SystemExtensions/` ;
  - la signature d'un composant est invalide ;
  - les entitlements DriverKit attendus sont absents.

- [x] Corriger les instructions finales de `build_driver.sh`, qui mentionnaient encore l'ancien nom `VirtualJoyConDriver.dext`.

### Vérifications

```bash
codesign --verify --strict --verbose=4 \
  build/xcode/Release/local.joycon2mac.driver.dext

codesign -d --entitlements :- \
  build/xcode/Release/local.joycon2mac.driver.dext

codesign --verify --deep --strict --verbose=4 \
  build/JoyCon2Mac.app

codesign -d --entitlements :- \
  build/JoyCon2Mac.app
```

Vérifier également l'extension réellement intégrée :

```bash
codesign -d --entitlements :- \
  build/JoyCon2Mac.app/Contents/Library/SystemExtensions/local.joycon2mac.driver.dext
```

### Critères d'acceptation

- Le `.dext` intégré conserve tous ses entitlements DriverKit.
- L'app principale ne possède que ses propres entitlements.
- `codesign --verify --deep --strict` réussit.
- Un build sans extension ne peut pas être présenté comme un build matériel réussi.

---

## 5. P0 — Rendre la calibration des sticks déterministe

### Problème

Le décodeur considère actuellement toute valeur brute comprise entre `1500` et `2300` comme un neutre plausible et recalcule le centre après 30 échantillons stables.

Une position légèrement maintenue peut donc devenir le nouveau centre. Au relâchement, le stick produit alors un mouvement dans la direction opposée.

Le décodage est aussi appelé plusieurs fois par paquet dans certains chemins, ce qui accélère artificiellement le compteur d'échantillons.

### Fichiers concernés

- `JoyCon2Mac/JoyConDecoder.h`
- `JoyCon2Mac/JoyConDecoder.cpp`
- `JoyCon2Mac/main.mm`
- `JoyCon2MacApp/DaemonBridge.swift`
- `JoyCon2MacApp/SettingsView.swift`

### Comportement cible

- La calibration est indépendante pour le Joy-Con gauche et le Joy-Con droit.
- Un stick hors de la zone neutre ne peut pas modifier son centre.
- Une calibration validée ne se relance pas continuellement.
- Le bouton « Calibrate Sticks » déclenche une vraie calibration.
- La calibration ne bloque jamais le thread principal.
- L'app affiche l'état : en attente, côté gauche validé, côté droit validé, terminée ou expirée.

### Implémentation

- [x] Déplacer les états de calibration hors des variables `static` locales de `DecodeJoystick`.
- [x] Ajouter une API explicite :

  ```cpp
  void BeginStickCalibration();
  void CancelStickCalibration();
  bool IsStickCalibrationComplete(JoyConSide side);
  int GetStickCalibrationSampleCount(JoyConSide side);
  ```

- [x] Ajouter une commande IPC `calibrateSticks`.
- [x] Relier le bouton SwiftUI à cette commande.
- [x] Émettre des événements daemon de progression.
- [x] Utiliser une fenêtre initiale stricte autour du centre nominal `2048`.
- [x] Commencer avec une tolérance expérimentale d'environ ±160 valeurs brutes, à ajuster à partir des traces matérielles.
- [x] Exiger au moins 30 échantillons stables avec une variation inter-échantillons maximale de 4.
- [x] Compter au plus un échantillon de calibration par paquet physique.
- [x] Après validation, ne plus recentrer automatiquement hors de la deadzone autour du centre établi.
- [x] Ajouter un délai maximal et conserver le centre précédent si la calibration expire.

### Cas de validation

- [x] Démarrer avec les deux sticks relâchés : les deux côtés se calibrent (test unitaire).
- [x] Démarrer avec un stick maintenu à 20 % : il ne devient pas le centre (test unitaire).
- [x] Maintenir un stick immobile après calibration : le centre ne bouge pas (test unitaire).
- [x] Relâcher le stick : la valeur revient à zéro sans mouvement inverse (test unitaire).
- [ ] Déplacer chaque stick jusqu'aux quatre extrêmes : la plage HID reste symétrique et atteint la valeur attendue.
- [ ] Modifier deadzone et sensibilité : le changement est visible sans redémarrage.
- [ ] Relancer une calibration manuelle : la progression est visible et les deux côtés sont recalculés sur matériel.

### Critère d'acceptation

Une session de cinq minutes avec mouvements, maintiens et relâchements répétés ne produit ni recentrage intempestif ni dérive induite par le logiciel.

---

## 6. P1 — Corriger les réglages trompeurs

### Contrôles actuellement sans effet complet

- `Auto-Reconnect`
- `Show Notifications`
- `Log Level`
- `Clear Paired Controllers`

`Clear Paired Controllers` supprime une préférence dans le domaine de l'app SwiftUI. Le daemon utilise un autre bundle et les méthodes de stockage de `PairingManager` ne sont actuellement pas reliées au flux principal. Ce bouton ne désassocie ni macOS ni le Joy-Con.

### Stratégie pour le premier test

Pour limiter les risques avant le test matériel :

- [x] masquer ou désactiver les contrôles sans effet ;
- [x] retirer entièrement les contrôles qui ne doivent pas rester visibles ;
- [x] ne pas exporter un réglage qui n'a aucun comportement.

### Implémentation ultérieure

- [ ] `Auto-Reconnect` : définir précisément s'il contrôle le scan BLE, la reconnexion à un périphérique connu, ou les deux.
- [ ] `Show Notifications` : intégrer `UNUserNotificationCenter` avec demande d'autorisation explicite.
- [ ] `Log Level` : envoyer une commande au daemon et filtrer réellement les événements.
- [ ] `Clear Paired Controllers` : distinguer :

  - les métadonnées locales ;
  - l'association CoreBluetooth/macOS ;
  - le MAC hôte persisté dans le Joy-Con.

- [ ] Ne proposer une suppression que si son effet exact est connu et confirmé.

### Critère d'acceptation

Chaque contrôle visible produit un effet observable ou indique clairement qu'il n'est pas encore disponible.

---

## 7. P1 — Contrôles automatiques de pré-vol

Ajouter à `build_all.sh` une étape finale qui vérifie :

- [x] présence de `JoyCon2Mac.app` ;
- [x] présence et exécution du helper daemon ;
- [x] présence du `.dext` sous son nom exact ;
- [x] identifiants de bundle attendus ;
- [x] versions non vides ;
- [x] signatures valides ;
- [x] entitlements distincts app/driver ;
- [x] absence de l'ancien `VirtualJoyConDriver.dext` ;
- [x] présence du framework `ServiceManagement` dans la compilation Swift.

Le script doit afficher un résumé final explicite :

```text
App             OK
Daemon helper   OK
DriverKit dext  OK
Signatures      OK
Entitlements    OK
Ready for hardware test
```

Tout échec doit produire un code de sortie non nul.

---

## 8. P2 — Matrice de test matériel

### Installation et activation

- [ ] Copier l'app dans `/Applications`.
- [ ] Ouvrir l'app et accepter les demandes macOS.
- [ ] Approuver l'extension dans Réglages Système.
- [ ] Redémarrer si macOS le demande.
- [ ] Vérifier que `local.joycon2mac.driver` est activé.
- [ ] Vérifier la présence du service `VirtualJoyConDriver` dans IOKit.
- [ ] Confirmer que l'app signale « Driver extension loaded ».

### Bluetooth

- [ ] Connecter le Joy-Con gauche seul.
- [ ] Connecter le Joy-Con droit seul.
- [ ] Connecter les deux simultanément.
- [ ] Éteindre puis rallumer chaque Joy-Con.
- [ ] Redémarrer le daemon avec les Joy-Con déjà connectés.
- [ ] Vérifier l'absence de boucle connexion/déconnexion.

### Gamepad

- [ ] Tester tous les boutons.
- [ ] Tester les diagonales du D-pad.
- [ ] Tester L3/R3, Home, Capture et Chat/C.
- [ ] Tester les quatre boutons de rail et leurs remappings.
- [ ] Vérifier les deux sticks dans l'app, Chrome et un client SDL.
- [ ] Vérifier l'absence de périphériques fantômes ou dupliqués.
- [ ] Tester `SDL Only Mode`.

### Souris

- [ ] Tester Off, Slow, Normal et Fast.
- [ ] Tester la sélection automatique gauche/droite.
- [ ] Tester clics, déplacement et molette.
- [ ] Vérifier que les entrées utilisées par la souris ne fuient pas dans le gamepad.

### Mouvement

- [ ] Poser les deux Joy-Con à plat : accélération proche de `(0, 0, +1 G)`.
- [ ] Vérifier séparément gauche, droite et fusion.
- [ ] Tester pitch, roll et yaw.
- [ ] Vérifier que la vue 3D est fluide et cohérente avec le mouvement physique.

### Haptics et Find My

- [ ] Tester vibration gauche, droite et simultanée.
- [ ] Tester plusieurs intensités.
- [ ] Tester Find Left, Find Right et Find Both.
- [ ] Vérifier l'arrêt après le geste prévu.

### NFC

- [ ] Détecter un Amiibo.
- [ ] Lire complètement le tag.
- [ ] Tester un tag NDEF texte.
- [ ] Tester une URI NDEF compressée.
- [ ] Tester un message NDEF multi-enregistrements.
- [ ] Retirer et représenter le même tag.
- [ ] Vérifier les messages d'erreur sur un tag incompatible.

### Persistance et interface

- [ ] Redémarrer l'app et vérifier les remappings.
- [ ] Vérifier deadzone et sensibilité après redémarrage.
- [ ] Tester export puis import de configuration.
- [ ] Tester Launch at Login depuis une app installée dans `/Applications`.
- [ ] Vérifier que « Clear Logs » ne réaffiche pas d'anciennes lignes.

---

## 9. Journaux à conserver pendant le test

```bash
tail -f "$HOME/Library/Application Support/JoyCon2Mac/daemon.jsonl"
```

```bash
tail -f "$HOME/Library/Application Support/JoyCon2Mac/input-trace.log"
```

Pour chaque anomalie, conserver :

- version de macOS ;
- modèle du Mac ;
- côté du Joy-Con ;
- état des LEDs ;
- étapes exactes de reproduction ;
- extrait `daemon.jsonl` ;
- extrait `input-trace.log` ;
- capture de la page concernée ;
- client utilisé : app, Chrome, SDL, jeu ou cloud gaming.

Ne pas publier les adresses MAC Bluetooth complètes dans un rapport public.

---

## 10. Décision Go / No-Go

### Go pour test matériel

- chaîne de build fonctionnelle ;
- `.dext` présent et correctement signé ;
- entitlements DriverKit vérifiés après intégration ;
- calibration déterministe ;
- build final sans erreur ;
- machine de test préparée et procédure de restauration connue.

### No-Go

- `.dext` absent ;
- signature imbriquée invalide ;
- entitlements DriverKit manquants ;
- calibration capable de recentrer un stick maintenu ;
- build DriverKit échoué mais script terminé avec succès ;
- test effectué sur une machine non sauvegardée ou utilisée pour des données sensibles.

## 11. Découpage conseillé des commits

1. `fix(build): preserve DriverKit entitlements when embedding dext`
2. `fix(input): make stick calibration explicit and deterministic`
3. `fix(settings): hide or implement inactive controls`
4. `build: add hardware-test preflight validation`
5. `docs: add hardware test procedure and results`

Chaque commit doit rester réversible et être testé séparément. Le push reste manuel conformément aux règles du projet.
