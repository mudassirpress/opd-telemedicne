# Current Structure Audit

Audit date: 2026-10-27
Branch: `refactor/architecture-cleanup`
Baseline commit: `8664061` (`chore: baseline before architecture refactor`)
Backup archive: `C:\Users\MNA\AppData\Local\Temp\opencode\telemedicine_backup_20261027_145902.zip`

## 1. Toolchain and project type

| Item | Value |
| --- | --- |
| Flutter | 3.47.2 (stable) |
| Dart | 3.13.2 |
| State management | Riverpod (`flutter_riverpod` 2.6.1) |
| Backend | Firebase, two entry points: Firestore/Storage rules + `firebase.json` |
| Cloud Functions | Plain JavaScript (CommonJS), Node.js 22 engine, `functions/index.js` entry |
| Platforms present | Android, iOS, web, Windows, macOS, Linux |
| Git | Repository was not initialized. A baseline commit and refactoring branch were created before edits. |

The Flutter app uses package imports (`package:telemedicine/...`) almost everywhere. Only
`lib/main.dart` and the offline cache modules use relative project imports. This makes
folder relocation low-risk as long as imports are rewritten and verified with the analyzer.

## 2. Current top-level layout

```
telemedicine/
  lib/               Flutter application
  functions/         Cloud Functions (JavaScript)
  test/              29 Flutter unit/widget tests
  migrations/        One-off SQL/JS data migration scripts
  assets/images/     UI images + launcher icon
  assets/sound/      Ringtone / notification sounds
  android/ ios/      Native projects (application IDs, signing, permissions)
  firebase.json      Firestore indexes, Storage rules, Functions source
  firestore.rules    Firestore security rules
  storage.rules      Storage security rules
  firestore.indexes.json
```

## 3. Current `lib/` layout

The project already contains part of a feature-first layout (`lib/core`, `lib/features`,
`lib/shared`, `lib/data`, `lib/app`) but also four legacy layouts that overlap it:

```
lib/
  main.dart                     App bootstrap, FCM background handler, Workmanager callback
  firebase_options.dart         Generated Firebase configuration (must stay at this path)
  app/app.dart                  MaterialApp root
  core/                         Constants, errors, network, theme, providers, services, utils
  data/models/                  15 shared Firestore model files
  data/repositories/            Doctor and patient repositories
  auth/                         Login, OTP, profiles, controllers, payment screen
  admin_portal/                 Entire admin experience + admin design system
  doctor_portal/                Doctor appointments, prescriptions, ratings, reports
  features/appointment/         Patient appointment flow + doctor details screen
  features/complaint/           Payment complaint flow
  features/doctor_video/        Doctor video controller
  features/patient/             Patient portal shell
  features/splash/              Splash screen
  home_screen/                  Main tab widgets: chat tab, doctor list tab, chat room
  home_widget/chat_call/        Chat feature, call feature, report feature
  offline_db/                   Hive offline cache (chat, call, doctor)
  services/                     Four auth-related services
  shared/widgets/               Reusable widgets and two design systems
```

### Responsibility map

| Area | Actual responsibility | Current location |
| --- | --- | --- |
| Bootstrap / background execution | Firebase init, FCM background handler, Workmanager callback, error hooks | `lib/main.dart` |
| Root widget | `MaterialApp`, theme, splash entry | `lib/app/app.dart` |
| Authentication | Phone login, OTP, Patient ID login, doctor login, session routing | `lib/auth/`, `lib/services/`, parts of `lib/core/services/` |
| Patient / doctor profiles | Profile screens and profile update | `lib/auth/patient_profile/`, `lib/auth/doctor_profile/` |
| Doctor discovery | Doctor list, details, presence/cache | `lib/home_screen/doctor_list_widget/`, `lib/features/appointment/doctor_details_screen.dart` |
| Chat | Chat list, room chat, message thread, voice, media, receipts, menu | `lib/home_screen/`, `lib/home_widget/chat_call/chat/` |
| Calls | Zego call screen, incoming call, history, recording, controller | `lib/home_widget/chat_call/call/`, `lib/core/services/` |
| Appointments | Booking, lifecycle, detail, payment proof, doctor appointments | `lib/features/appointment/`, `lib/doctor_portal/appointments/` |
| Payments | Subscription payment, appointment payment, approval screens | `lib/auth/payment/`, `lib/features/appointment/`, `lib/admin_portal/notification/` |
| Notifications | FCM tokens, local notifications, dispatcher, routing, badges | `lib/core/services/`, `lib/core/providers/` |
| Reports | Upload, share, history, shared reports | `lib/home_widget/reports/`, `lib/doctor_portal/shared_reports/` |
| Admin | Dashboard, accounts, appointments, payments, complaints, videos, settings | `lib/admin_portal/` |
| Offline data | Hive boxes, offline models, sync services | `lib/offline_db/` |
| Shared UI | Design systems, app bars, states, inputs, guards | `lib/shared/widgets/` |
| Shared data | Firestore models, repositories | `lib/data/` |

## 4. Naming and structural problems found

1. **Feature code split across four unrelated layouts.** Chat code exists in
   `home_screen/`, `home_widget/chat_call/chat/`, and `core/services/`; doctors exist in
   `auth/doctor_profile/`, `home_screen/doctor_list_widget/`, and
   `features/appointment/doctor_details_screen.dart`; appointments exist in
   `features/appointment/` and `doctor_portal/appointments/`.
2. **Folder names describe the old UI shell, not the feature.** `home_screen/`,
   `home_widget/`, `admin_portal/`, and `doctor_portal/` are navigation/layout terms.
3. **Vague or redundant filenames:**
   - `admin_ui.dart` is the admin design system, not a UI screen.
   - `opd_design.dart` is a shared OPD design system.
   - `appointment_ui.dart` only contains status pills and timeline widgets.
   - `update_doctor_profile.dart` contains a full screen.
   - `incoming_call.dart` contains the incoming-call screen.
   - `report_history.dart` contains a screen.
   - `fcm_service.dart` contains `FcmTokenService` only.
   - `chat_menu.dart` contains `showChatMenu` (overflow-menu builder).
   - `chatting_list_widget.dart` / `ChatingListWidget` contains a spelling error.
4. **Single-letter/ambiguous folder nesting:** `home_widget/chat_call/chat/` and
   `home_widget/chat_call/call/` do not describe the feature; they describe a widget tree.
5. **Very large files (maintainability risk):**

   | File | Size |
   | --- | --- |
   | `lib/home_widget/chat_call/chat/chat_screen.dart` | 235,757 bytes |
   | `lib/auth/user_controller/patient_controller.dart` | 132,672 bytes |
   | `lib/features/appointment/appointment_controller.dart` | 121,187 bytes |
   | `lib/home_widget/chat_call/chat/chat_controller/chat_controller.dart` | 121,794 bytes |
   | `lib/core/services/notification_service.dart` | 113,382 bytes |
   | `functions/index.js` | 94,784 bytes |
   | `lib/home_widget/chat_call/call/call_controller/call_controller.dart` | 64,306 bytes |
   | `lib/home_screen/room_chat_screen.dart` | 61,011 bytes |

   These files mix presentation, orchestration, Firestore access, and platform services.
   They were intentionally **not** split in this refactoring pass; splitting them safely
   requires feature-level test coverage that does not currently exist. See remaining work.
6. **Dead code found and verified unused:**
   - `lib/shared/widgets/common_widgets.dart` (7 widget classes, no imports anywhere).
   - `lib/core/extensions/extensions.dart` (3 extensions, no imports anywhere).
7. **Empty/obsolete folders after relocation:** `lib/auth/`, `lib/admin_portal/`,
   `lib/doctor_portal/`, `lib/home_screen/`, `lib/home_widget/`, `lib/services/`,
   `lib/offline_db/` were removed once all files were relocated.
8. **Backend modularity:** `functions/index.js` holds every trigger, callable, and
   scheduled function in one file. Helper modules are flat beside it. No language or
   runtime change is needed; module systems must remain CommonJS with Node 22.

## 5. Runtime- and deployment-sensitive paths (must not be moved casually)

| Path | Why it is sensitive |
| --- | --- |
| `lib/main.dart` | Flutter entry point, `@pragma('vm:entry-point')` FCM background handler and Workmanager callback |
| `lib/firebase_options.dart` | Referenced by `firebase.json` Flutter configuration (`flutter.configurations.dart`) |
| `functions/index.js` | `functions/package.json` `main`, Firebase deployment entry point |
| `functions/package.json` / lockfile | Node runtime, dependency versions, deploy scripts |
| `firebase.json`, `firestore.rules`, `storage.rules`, `firestore.indexes.json` | Deployed backend contracts |
| `android/`, `ios/` | Application IDs, signing, permissions, native integrations |
| `assets/images/`, `assets/sound/` | Referenced from `pubspec.yaml` and runtime code |
| Generated `*.g.dart` | Hive adapters; must stay beside their `part` owner |
| Firebase collection names, document IDs, field names, Cloud Function export names | External data contracts; unchanged by this refactoring |

## 6. Baseline verification

See `baseline_test_results.md`. Summary: analyzer reports 383 issues (none fatal),
`flutter test` reports 360 passing and 2 pre-existing failures, and Cloud Functions
tests pass 87/87. No Flutter or backend production deployment was performed.
