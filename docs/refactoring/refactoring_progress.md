# Refactoring Progress

Branch: `refactor/architecture-cleanup`
Baseline commit: `8664061`
Backup: `C:\Users\MNA\AppData\Local\Temp\opencode\telemedicine_backup_20261027_145902.zip`

Status legend: `done`, `in progress`, `pending`, `blocked`, `not applicable`.

## Stage 0 — Safety and baseline

| Step | Status | Notes |
| --- | --- | --- |
| Archive backup created | done | 28.9 MB zip, excludes `.dart_tool`, `build`, `functions/node_modules` |
| Git baseline created | done | Repository had no `.git`; initialized and committed all existing work as-is |
| Refactoring branch created | done | `refactor/architecture-cleanup` |
| Analyzer baseline | done | 0 errors, 61 warnings, 322 info (383 issues), 267.7 s |
| Flutter test baseline | done | 360 passed, 2 pre-existing failures |
| Functions test baseline | done | 87 passed, 0 failed |
| Audit documentation | done | `current_structure.md`, `proposed_structure.md`, this file, `baseline_test_results.md` |

## Stage 1 — Shared infrastructure and naming

| Step | Status | Notes |
| --- | --- | --- |
| Move `core/theme/app_theme.dart` to `app/theme/` | done | App-level theme |
| Rename `fcm_service.dart` to `fcm_token_service.dart` | done | Contents define `FcmTokenService` |
| Rename `opd_design.dart` to `opd_design_system.dart` | done | 13 reusable design-system widgets |
| Rename `custom_textfield.dart` / `MyTextfield` | done | Now `custom_text_field.dart` / `CustomTextField` |
| Remove unused `core/extensions/extensions.dart` | done | No imports/references anywhere |
| Remove unused `shared/widgets/common_widgets.dart` | done | 7 widgets, no imports/references anywhere |
| Remove unused duplicate `app/app.dart` | done | `TelemedicineApp` unused; `main.dart` uses `MyApp` |

## Stage 2 — Authentication, doctors, patients

| Step | Status | Notes |
| --- | --- | --- |
| Move auth services to `features/auth/data/services/` | done | Password reset, phone auth, OTP verification |
| Move auth controllers/providers/screens | done | `features/auth/presentation/*` |
| Move doctor profile screens | done | `features/doctors/presentation/screens/` |
| Rename `update_doctor_profile.dart` | done | Now `update_doctor_profile_screen.dart`, class `UpdateDoctorProfileScreen` |
| Move patient profile screen | done | `features/patients/presentation/screens/` |
| Move patient portal shell | done | `features/patients/presentation/` |
| Move doctor details/list | done | `features/doctors/presentation/` |
| Rename `doctor_list.dart` | done | Now `doctor_list_widget.dart` |

## Stage 3 — Chat and notifications

| Step | Status | Notes |
| --- | --- | --- |
| Move chat screen/controller/actions/menu/voice/doc | done | `features/chat/presentation/` |
| Move room chat and chat list tab | done | `features/chat/presentation/` |
| Fix `ChatingListWidget` typo | done | Now `ChatListWidget` |
| Rename `chat_menu.dart` | done | Now `chat_overflow_menu.dart` (`showChatMenu`) |
| Notifications infrastructure kept in `core/services` | done | Notification behavior and handlers unchanged |
| Admin notifications consolidated | done | Singular `notification/` merged into `notifications/` |

## Stage 4 — Calls and Zego integration

| Step | Status | Notes |
| --- | --- | --- |
| Move call screen/history/incoming call | done | `features/calls/presentation/` |
| Move call controller | done | `features/calls/presentation/controllers/` |
| Move call recording widget | done | `features/calls/presentation/call_recording/` |
| Rename `incoming_call.dart` | done | Now `incoming_call_screen.dart` |
| Zego/platform registration untouched | done | No native or payload changes |

## Stage 5 — Appointments and payments

| Step | Status | Notes |
| --- | --- | --- |
| Move appointment feature | done | `features/appointments/presentation/` |
| Rename `appointment_ui.dart` | done | Now `appointment_status_widgets.dart` |
| Move doctor details screen out of appointment feature | done | `features/doctors/presentation/` |
| Move payment screen | done | `features/payments/presentation/screens/` |
| Move complaint feature | done | `features/complaints/presentation/` |
| Doctor portal appointments/prescriptions/ratings/reports | done | `features/doctor_portal/presentation/` |
| Business rules, timestamps, payment fields untouched | done | Structure-only changes |

## Stage 6 — Firebase Cloud Functions

| Step | Status | Notes |
| --- | --- | --- |
| Group helper modules under `functions/lib/` | done | `shared`, `auth`, `calls`, `presence`, `doctors` |
| Update internal `require()` paths | done | 26 replacements; `.js` extensions preserved |
| Update test requires | done | All 6 test files updated |
| Preserve `functions/index.js` as deploy entry | done | No export/trigger/runtime change |
| `node --check` all JS | done | 0 failures |
| `node --test` | done | 87 passed, 0 failed |

## Stage 7 — Formatting, builds, documentation

| Step | Status | Notes |
| --- | --- | --- |
| `dart format lib test` | pending | Deferred to a separate commit so structural moves stay reviewable |
| `flutter analyze` after formatting | pending | Re-run after format |
| `flutter test` after formatting | pending | Re-run after format |
| Google/Firebase emulator tests | pending | Requires emulator setup; not available in current environment |
| Android debug build | pending | To be executed |
| Android release build | pending | Only if signing configuration allows |
| Final report | pending | After build verification |

## Verification checkpoints actually run

| Checkpoint | Command | Result |
| --- | --- | --- |
| Baseline analyzer | `flutter analyze` | 0 errors / 383 issues |
| Baseline Flutter tests | `flutter test` | 360 pass, 2 pre-existing fail |
| Baseline Functions tests | `node --test` (in `functions`) | 87 pass, 0 fail |
| After Flutter moves | `flutter analyze` | 0 errors / 381 issues |
| After Flutter moves | `flutter test` | 360 pass, 2 pre-existing fail |
| After rename cleanup | `flutter analyze` | 0 errors / 374 issues |
| After rename cleanup | `flutter test` | 360 pass, 2 pre-existing fail |
| After Functions moves | `node --check` | 0 failures |
| After Functions moves | `node --test` | 87 pass, 0 fail |

## Pre-existing failures that remain

These failures existed before any refactoring and are intentionally not "fixed" by
changing product behavior during a structure-only refactor:

1. `test/authentication_flow_update_test.dart:163` — phone patient without payment proof
   expected `paymentProof`, actual `chatRoom`.
2. `test/patient_card_routing_test.dart:229` — regular non-card patient without
   `paymentImage` expected `paymentProof`, actual `chatRoom`.

Both point at `AuthRoutingService` behavior and need a product decision before changing.

## Not performed (requires approval)

- `firebase deploy` or any production deployment.
- Firestore/Storage rules or index changes.
- Function deletion, trigger/region/retry changes.
- Dependency upgrades/removals.
- Native project, application ID, signing, or permission changes.
