# Proposed Structure

The target is a feature-first structure that preserves the existing Riverpod architecture,
Firebase contracts, native projects, and UI. It deliberately keeps a shared `data/` layer
because several models (`UserModel`, `ChatMessageModel`, `AppointmentModel`, notifications)
are used by more than one feature.

## Target `lib/` layout

```
lib/
  main.dart                         # unchanged entry point + background handlers
  firebase_options.dart             # unchanged generated config path

  app/
    app.dart
    theme/app_theme.dart

  core/
    constants/app_constants.dart
    errors/
    network/
    providers/badge_providers.dart
    services/                       # app-wide infrastructure only
      account_expiry_service.dart
      app_feedback.dart
      audio_service.dart
      auth_routing_service.dart
      call_ringtone_service.dart
      device_service.dart
      doctor_list_cache.dart
      doctor_presence_service.dart
      fcm_token_service.dart        # renamed from fcm_service.dart
      firebase_storage_service.dart
      guest_mode_service.dart
      image_picker_service.dart
      incoming_call_coordinator.dart
      notification_dispatcher.dart
      notification_service.dart
      patient_presence_service.dart
      payment_complaint_visibility_service.dart
      session_service.dart
      single_device_session_service.dart
      smart_launch_coordinator.dart
      soft_delete_service.dart
    utils/

  data/
    local/                          # offline cache (was lib/offline_db)
      hive_db_service.dart
      offline_call_service.dart
      offline_chat_service.dart
      offline_converters.dart
      offline_doctor_service.dart
      models/
    models/                         # shared Firestore models
    repositories/

  features/
    admin/
      presentation/
        admin_design_system.dart    # was admin_ui.dart
        admin_bottom_nav/
        admin_chat/admin_chat_view_screen.dart
        create_doctor_id/create_doctor_id_screen.dart
        doctor_online_history/
          doctor_online_history_screen.dart
          admin_online_history_tab.dart
          doctor_online_services/doctor_online_history_service.dart
        doctor_videos/
        notifications/              # singular folder merged into this one
          admin_complaint_detail_screen.dart
          admin_notifications_screen.dart
          admin_payment_screen.dart  # was payment_approve_noti.dart
          admin_reactivation_screen.dart
        patient_id_management/
        admin_portal_screen.dart
        admin_chat_management_screen.dart
        admin_reports_screen.dart

    appointments/
      presentation/
        appointment_controller.dart
        appointment_detail_screen.dart
        appointment_lifecycle_logic.dart
        appointment_lifecycle_service.dart
        appointment_payment_screen.dart
        appointment_request_screen.dart
        appointment_screen.dart
        appointment_status_widgets.dart   # was appointment_ui.dart
        (doctor_details_screen.dart moved to doctors/)

    auth/
      data/services/
        patient_password_reset_service.dart
        patient_phone_auth_service.dart
        phone_auth_service.dart
        phone_verification_service.dart
      presentation/
        controllers/
          doctor_controller.dart
          patient_controller.dart
          patient_id_controller.dart
        providers/user_provider.dart
        screens/
          complete_patient_profile_screen.dart
          expired_patient_screen.dart
          otp_verification_screen.dart
          patient_id_verification_screen.dart
          sign_in_screen.dart

    calls/
      presentation/
        controllers/call_controller.dart
        call_history_screen.dart
        call_screen.dart
        incoming_call_screen.dart
        call_recording/call_recording_widget.dart

    chat/
      presentation/
        chat_screen.dart
        room_chat_screen.dart
        chat_list_widget.dart
        chat_action/
        controllers/
          chat_controller.dart
          chat_providers.dart
        chat_menu/chat_overflow_menu.dart
        chat_status/
        doc/
        voice/

    complaints/
      presentation/
        payment_complaint_service.dart
        submit_complaint_screen.dart

    doctor_portal/
      presentation/
        appointments/
        bottom_nav/
        doctor_portal_screen.dart
        prescriptions/
        ratings/
        shared_reports/

    doctor_videos/
      presentation/doctor_video_controller.dart

    doctors/
      presentation/
        doctor_details_screen.dart
        doctor_list_widget.dart
        screens/
          doctor_profile_screen.dart
          update_doctor_profile_screen.dart

    patients/
      presentation/
        patient_portal_tab_provider.dart
        patient_portal_wrapper.dart
        screens/patient_profile_screen.dart

    payments/
      presentation/screens/payment_screen.dart

    reports/
      presentation/
        patient_shared_reports/
        report_controller/
        report_history/
        report_share_controller/
        share_report_screen/
        upload_report_screen/

    splash/
      presentation/splash_screen.dart

  shared/
    widgets/
      anchored_popup_menu.dart
      app_bars.dart
      app_states.dart
      auth_layout.dart
      badge_indicator.dart
      custom_text_field.dart          # was custom_textfield.dart
      image_picker/
      international_phone_input.dart
      language_field.dart
      opd_design_system.dart          # was opd_design.dart
      single_device_session_guard.dart
```

## Target `functions/` layout

No language, runtime, module-system, export, trigger, or package-manager change. The
deployment entry point remains `functions/index.js` and `functions/package.json` `main`
is unchanged. Only helper modules are grouped by responsibility:

```
functions/
  index.js                    # unchanged deploy entry; requires from lib/
  package.json                # unchanged engines/dependencies/scripts
  lib/
    shared/
      fcm_helpers.js
      notification_shared.js
      phone_helpers.js
      password_reset_helpers.js
    calls/
      call_notification.js
    auth/
      patient_password_reset.js
      phone_verification.js
    presence/
      doctor_presence.js
      doctor_presence_helpers.js
    doctors/
      doctor_profile_helpers.js
  test/                       # requires updated to lib/ paths
  migrate_cloudinary.js       # one-off migration script, left in place
```

`index.js` is intentionally not split in this pass. Its exports are production contracts
and require emulator/deployment verification; splitting it without that verification
would be an unnecessary deployment risk.

## Layer rules applied

- **Presentation:** screens, widgets, Riverpod controllers/providers for a feature.
- **Data:** shared Firestore models/repositories and local Hive cache.
- **Domain:** not introduced as empty boilerplate. Existing pure logic helpers
  (`appointment_lifecycle_logic.dart`, subscription utilities) remain where they are used.
- **Core:** only app-wide infrastructure.
- **Shared:** genuinely reusable widgets and design systems.

## Explicit non-changes

- No UI, color, typography, spacing, animation, or navigation redesign.
- No Firestore collection/document/field renames.
- No Cloud Function export, trigger, region, retry, or payload changes.
- No package upgrades or dependency removals.
- No Android/iOS identifiers, signing, permissions, or native files changed.
- No deletion of password reset, registration, notification, call, or payment features.
- No production deploy or Firebase rules change.
