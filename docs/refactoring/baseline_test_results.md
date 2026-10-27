# Baseline Test Results (before refactoring)

Recorded: 2026-10-27
Baseline commit: `8664061`
Branch created after baseline: `refactor/architecture-cleanup`

All results below are **actual command output**, not estimates.

## Environment

| Tool | Version |
| --- | --- |
| Flutter | 3.47.2 stable |
| Dart | 3.13.2 |
| Node.js | v26.7.0 (installed); project `functions/package.json` targets Node 22 |
| npm | Not invokable via PowerShell (`npm.ps1` blocked by execution policy); `node --test` used directly |

## Flutter analyzer

Command:

```powershell
flutter analyze
```

Result: **0 errors, 61 warnings, 322 info messages, 383 issues total** (267.7 s).

The failures are all lint/info-level (deprecated `withOpacity`, `avoid_print`,
`unnecessary_non_null_assertion`, unused test variables, etc.). There are no compile
errors at baseline.

## Flutter tests

Command:

```powershell
flutter test
```

Result: **360 passed, 2 failed, 362 total** (3 min 31 s).

### Pre-existing failures

1. `test/authentication_flow_update_test.dart`
   - Test: `3. Guest Mode Model & Routing AuthRoutingService routes Phone Patient without payment proof to paymentProof`
   - Expected `PatientAuthDestination.paymentProof`, actual `PatientAuthDestination.chatRoom`
   - Location: `test/authentication_flow_update_test.dart:163`
2. `test/patient_card_routing_test.dart`
   - Test: `Patient Card Expiry and Routing Logic AuthRoutingService: Case C - Regular Non-Card Patient without paymentImage routes to paymentProof`
   - Expected `PatientAuthDestination.paymentProof`, actual `PatientAuthDestination.chatRoom`
   - Location: `test/patient_card_routing_test.dart:229`

Both failures existed before any refactoring change and are unrelated to file moves.
They must remain documented as pre-existing until the routing logic or the tests are
updated intentionally (not part of this structure-only refactor).

## Cloud Functions tests

Command (run inside `functions/`):

```powershell
node --test
```

Result: **87 tests passed, 0 failed** (6 test files, 5 suites, ~1.1 s).

## Flutter builds

No Android/iOS/web/Windows build was run at baseline. Build verification is performed
after the refactoring (see final report and `refactoring_progress.md`).

## Deployment

No Firebase deploy (`firebase deploy`) was executed. No Firestore/Storage rules,
indexes, functions, secrets, or production data were changed.
