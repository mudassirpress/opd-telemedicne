# File Rename and Move Map

Branch: `refactor/architecture-cleanup`  
Baseline: `8664061`  
Generated from `git diff --cached -M --name-status`, so every entry below is a real detected move for this refactoring.

## Directory-level relocations

| Old location | New location |
| --- | --- |
| `lib/admin_portal/` | `lib/features/admin/presentation/` |
| `lib/auth/auth_provider/` | `lib/features/auth/presentation/providers/` |
| `lib/auth/auth_screen/` | `lib/features/auth/presentation/screens/` |
| `lib/auth/user_controller/` | `lib/features/auth/presentation/controllers/` |
| `lib/auth/doctor_profile/` | `lib/features/doctors/presentation/screens/` |
| `lib/auth/patient_profile/` | `lib/features/patients/presentation/screens/` |
| `lib/auth/payment/` | `lib/features/payments/presentation/screens/` |
| `lib/doctor_portal/` | `lib/features/doctor_portal/presentation/` |
| `lib/home_screen/` | `lib/features/chat/ or lib/features/doctors/ (split by responsibility)` |
| `lib/home_widget/chat_call/chat/` | `lib/features/chat/presentation/` |
| `lib/home_widget/chat_call/call/` | `lib/features/calls/presentation/` |
| `lib/home_widget/reports/` | `lib/features/reports/presentation/` |
| `lib/features/appointment/` | `lib/features/appointments/presentation/` |
| `lib/features/complaint/` | `lib/features/complaints/presentation/` |
| `lib/features/doctor_video/` | `lib/features/doctor_videos/presentation/` |
| `lib/features/patient/` | `lib/features/patients/presentation/` |
| `lib/features/splash/` | `lib/features/splash/presentation/` |
| `lib/services/` | `lib/features/auth/data/services/` |
| `lib/offline_db/` | `lib/data/local/` |
| `lib/core/theme/` | `lib/app/theme/` |
| `functions/*_helpers.js and feature modules` | `functions/lib/{shared,auth,calls,presence,doctors}/` |

## Complete file-level move map

| Old path | New path |
| --- | --- |
| `functions/patient_password_reset.js` | `functions/lib/auth/patient_password_reset.js` |
| `functions/phone_verification.js` | `functions/lib/auth/phone_verification.js` |
| `functions/call_notification.js` | `functions/lib/calls/call_notification.js` |
| `functions/doctor_profile_helpers.js` | `functions/lib/doctors/doctor_profile_helpers.js` |
| `functions/doctor_presence.js` | `functions/lib/presence/doctor_presence.js` |
| `functions/doctor_presence_helpers.js` | `functions/lib/presence/doctor_presence_helpers.js` |
| `functions/fcm_helpers.js` | `functions/lib/shared/fcm_helpers.js` |
| `functions/notification_shared.js` | `functions/lib/shared/notification_shared.js` |
| `functions/password_reset_helpers.js` | `functions/lib/shared/password_reset_helpers.js` |
| `functions/phone_helpers.js` | `functions/lib/shared/phone_helpers.js` |
| `lib/core/theme/app_theme.dart` | `lib/app/theme/app_theme.dart` |
| `lib/core/services/fcm_service.dart` | `lib/core/services/fcm_token_service.dart` |
| `lib/offline_db/hive_db_service.dart` | `lib/data/local/hive_db_service.dart` |
| `lib/offline_db/models/offline_call_record.dart` | `lib/data/local/models/offline_call_record.dart` |
| `lib/offline_db/models/offline_call_record.g.dart` | `lib/data/local/models/offline_call_record.g.dart` |
| `lib/offline_db/models/offline_chat_message.dart` | `lib/data/local/models/offline_chat_message.dart` |
| `lib/offline_db/models/offline_chat_message.g.dart` | `lib/data/local/models/offline_chat_message.g.dart` |
| `lib/offline_db/offline_call_service.dart` | `lib/data/local/offline_call_service.dart` |
| `lib/offline_db/offline_chat_service.dart` | `lib/data/local/offline_chat_service.dart` |
| `lib/offline_db/offline_converters.dart` | `lib/data/local/offline_converters.dart` |
| `lib/offline_db/offline_doctor_service.dart` | `lib/data/local/offline_doctor_service.dart` |
| `lib/admin_portal/admin_bottom_nav/admin_appointments_screen.dart` | `lib/features/admin/presentation/admin_bottom_nav/admin_appointments_screen.dart` |
| `lib/admin_portal/admin_bottom_nav/admin_doctors_patients_screen.dart` | `lib/features/admin/presentation/admin_bottom_nav/admin_doctors_patients_screen.dart` |
| `lib/admin_portal/admin_bottom_nav/admin_more_screen.dart` | `lib/features/admin/presentation/admin_bottom_nav/admin_more_screen.dart` |
| `lib/admin_portal/admin_bottom_nav/admin_portal_wrapper.dart` | `lib/features/admin/presentation/admin_bottom_nav/admin_portal_wrapper.dart` |
| `lib/admin_portal/admin_bottom_nav/admin_settings_screen.dart` | `lib/features/admin/presentation/admin_bottom_nav/admin_settings_screen.dart` |
| `lib/admin_portal/admin_chat/admin_chat_screen.dart` | `lib/features/admin/presentation/admin_chat/admin_chat_view_screen.dart` |
| `lib/admin_portal/admin_chat_management_screen.dart` | `lib/features/admin/presentation/admin_chat_management_screen.dart` |
| `lib/admin_portal/admin_ui.dart` | `lib/features/admin/presentation/admin_design_system.dart` |
| `lib/admin_portal/admin_portal_screen.dart` | `lib/features/admin/presentation/admin_portal_screen.dart` |
| `lib/admin_portal/admin_reports_screen.dart` | `lib/features/admin/presentation/admin_reports_screen.dart` |
| `lib/admin_portal/create_doctor_id_by_admin/create_doctor_id.dart` | `lib/features/admin/presentation/create_doctor_id/create_doctor_id_screen.dart` |
| `lib/admin_portal/doctor_online_history/admin_online_history_tab.dart` | `lib/features/admin/presentation/doctor_online_history/admin_online_history_tab.dart` |
| `lib/admin_portal/doctor_online_history/online_doctors_history.dart` | `lib/features/admin/presentation/doctor_online_history/doctor_online_history_screen.dart` |
| `lib/admin_portal/doctor_online_history/doctor_online_services/doctor_online_services.dart` | `lib/features/admin/presentation/doctor_online_history/doctor_online_services/doctor_online_history_service.dart` |
| `lib/admin_portal/doctor_videos/admin_doctor_videos_screen.dart` | `lib/features/admin/presentation/doctor_videos/admin_doctor_videos_screen.dart` |
| `lib/admin_portal/notifications/admin_complaint_detail_screen.dart` | `lib/features/admin/presentation/notifications/admin_complaint_detail_screen.dart` |
| `lib/admin_portal/notifications/admin_notifications_screen.dart` | `lib/features/admin/presentation/notifications/admin_notifications_screen.dart` |
| `lib/admin_portal/notification/payment_approve_noti.dart` | `lib/features/admin/presentation/notifications/admin_payment_screen.dart` |
| `lib/admin_portal/notification/admin_reactivation_screen.dart` | `lib/features/admin/presentation/notifications/admin_reactivation_screen.dart` |
| `lib/admin_portal/patient_id_management/patient_id_management_screen.dart` | `lib/features/admin/presentation/patient_id_management/patient_id_management_screen.dart` |
| `lib/features/appointment/appointment_controller.dart` | `lib/features/appointments/presentation/appointment_controller.dart` |
| `lib/features/appointment/appointment_detail_screen.dart` | `lib/features/appointments/presentation/appointment_detail_screen.dart` |
| `lib/features/appointment/appointment_lifecycle_logic.dart` | `lib/features/appointments/presentation/appointment_lifecycle_logic.dart` |
| `lib/features/appointment/appointment_lifecycle_service.dart` | `lib/features/appointments/presentation/appointment_lifecycle_service.dart` |
| `lib/features/appointment/appointment_payment_screen.dart` | `lib/features/appointments/presentation/appointment_payment_screen.dart` |
| `lib/features/appointment/appointment_request_screen.dart` | `lib/features/appointments/presentation/appointment_request_screen.dart` |
| `lib/features/appointment/appointment_screen.dart` | `lib/features/appointments/presentation/appointment_screen.dart` |
| `lib/features/appointment/appointment_ui.dart` | `lib/features/appointments/presentation/appointment_status_widgets.dart` |
| `lib/services/patient_password_reset_service.dart` | `lib/features/auth/data/services/patient_password_reset_service.dart` |
| `lib/services/patient_phone_auth_service.dart` | `lib/features/auth/data/services/patient_phone_auth_service.dart` |
| `lib/services/phone_auth_service.dart` | `lib/features/auth/data/services/phone_auth_service.dart` |
| `lib/services/phone_verification_service.dart` | `lib/features/auth/data/services/phone_verification_service.dart` |
| `lib/auth/user_controller/doctor_controller.dart` | `lib/features/auth/presentation/controllers/doctor_controller.dart` |
| `lib/auth/user_controller/patient_controller.dart` | `lib/features/auth/presentation/controllers/patient_controller.dart` |
| `lib/auth/user_controller/patient_id_controller.dart` | `lib/features/auth/presentation/controllers/patient_id_controller.dart` |
| `lib/auth/auth_provider/user_provider.dart` | `lib/features/auth/presentation/providers/user_provider.dart` |
| `lib/auth/auth_screen/complete_patient_profile_screen.dart` | `lib/features/auth/presentation/screens/complete_patient_profile_screen.dart` |
| `lib/auth/auth_screen/expired_patient_screen.dart` | `lib/features/auth/presentation/screens/expired_patient_screen.dart` |
| `lib/auth/auth_screen/otp_verification_screen.dart` | `lib/features/auth/presentation/screens/otp_verification_screen.dart` |
| `lib/auth/auth_screen/patient_id_verification_screen.dart` | `lib/features/auth/presentation/screens/patient_id_verification_screen.dart` |
| `lib/auth/auth_screen/sign_in_screen.dart` | `lib/features/auth/presentation/screens/sign_in_screen.dart` |
| `lib/home_widget/chat_call/call/call_history_screen.dart` | `lib/features/calls/presentation/call_history_screen.dart` |
| `lib/home_widget/chat_call/call_recording/call_recording_widget.dart` | `lib/features/calls/presentation/call_recording/call_recording_widget.dart` |
| `lib/home_widget/chat_call/call/call_screen.dart` | `lib/features/calls/presentation/call_screen.dart` |
| `lib/home_widget/chat_call/call/call_controller/call_controller.dart` | `lib/features/calls/presentation/controllers/call_controller.dart` |
| `lib/home_widget/chat_call/call/incoming_call.dart` | `lib/features/calls/presentation/incoming_call_screen.dart` |
| `lib/home_widget/chat_call/chat/chat_action/chat_action_widget.dart` | `lib/features/chat/presentation/chat_action/chat_action_widget.dart` |
| `lib/home_widget/chat_call/chat/chat_action/chat_image_download_service.dart` | `lib/features/chat/presentation/chat_action/chat_image_download_service.dart` |
| `lib/home_widget/chat_call/chat/chat_action/message_action_rules.dart` | `lib/features/chat/presentation/chat_action/message_action_rules.dart` |
| `lib/home_widget/chat_call/chat/chat_action/swipe_to_reply_wrapper.dart` | `lib/features/chat/presentation/chat_action/swipe_to_reply_wrapper.dart` |
| `lib/home_screen/chatting_list_widget/chatting_list_widget.dart` | `lib/features/chat/presentation/chat_list_widget.dart` |
| `lib/home_widget/chat_call/chat/chat_menu/chat_contact_screen.dart` | `lib/features/chat/presentation/chat_menu/chat_contact_screen.dart` |
| `lib/home_widget/chat_call/chat/chat_menu/chat_favourites_provider.dart` | `lib/features/chat/presentation/chat_menu/chat_favourites_provider.dart` |
| `lib/home_widget/chat_call/chat/chat_menu/chat_media_screen.dart` | `lib/features/chat/presentation/chat_menu/chat_media_screen.dart` |
| `lib/home_widget/chat_call/chat/chat_menu/chat_menu.dart` | `lib/features/chat/presentation/chat_menu/chat_overflow_menu.dart` |
| `lib/home_widget/chat_call/chat/chat_menu/doctor_contact_screen.dart` | `lib/features/chat/presentation/chat_menu/doctor_contact_screen.dart` |
| `lib/home_widget/chat_call/chat/chat_menu/forward_recipient_screen.dart` | `lib/features/chat/presentation/chat_menu/forward_recipient_screen.dart` |
| `lib/home_widget/chat_call/chat/chat_screen.dart` | `lib/features/chat/presentation/chat_screen.dart` |
| `lib/home_widget/chat_call/chat/chat_status/message_status_indicator.dart` | `lib/features/chat/presentation/chat_status/message_status_indicator.dart` |
| `lib/home_widget/chat_call/chat/chat_controller/chat_controller.dart` | `lib/features/chat/presentation/controllers/chat_controller.dart` |
| `lib/home_widget/chat_call/chat/chat_controller/chat_providers.dart` | `lib/features/chat/presentation/controllers/chat_providers.dart` |
| `lib/home_widget/chat_call/chat/doc/document_viewer_helper.dart` | `lib/features/chat/presentation/doc/document_viewer_helper.dart` |
| `lib/home_widget/chat_call/chat/doc/pdf_viewer_screen.dart` | `lib/features/chat/presentation/doc/pdf_viewer_screen.dart` |
| `lib/home_screen/room_chat_screen.dart` | `lib/features/chat/presentation/room_chat_screen.dart` |
| `lib/home_widget/chat_call/chat/voice/voice_manager/voice_message_manager.dart` | `lib/features/chat/presentation/voice/voice_manager/voice_message_manager.dart` |
| `lib/home_widget/chat_call/chat/voice/voice_message_player.dart` | `lib/features/chat/presentation/voice/voice_message_player.dart` |
| `lib/features/complaint/payment_complaint_service.dart` | `lib/features/complaints/presentation/payment_complaint_service.dart` |
| `lib/features/complaint/submit_complaint_screen.dart` | `lib/features/complaints/presentation/submit_complaint_screen.dart` |
| `lib/doctor_portal/appointments/confirm_appointment_screen.dart` | `lib/features/doctor_portal/presentation/appointments/confirm_appointment_screen.dart` |
| `lib/doctor_portal/appointments/doctor_appointments_screen.dart` | `lib/features/doctor_portal/presentation/appointments/doctor_appointments_screen.dart` |
| `lib/doctor_portal/bottom_nav/doctor_portal_tab_provider.dart` | `lib/features/doctor_portal/presentation/bottom_nav/doctor_portal_tab_provider.dart` |
| `lib/doctor_portal/bottom_nav/doctor_portal_wrapper.dart` | `lib/features/doctor_portal/presentation/bottom_nav/doctor_portal_wrapper.dart` |
| `lib/doctor_portal/doctor_portal_screen.dart` | `lib/features/doctor_portal/presentation/doctor_portal_screen.dart` |
| `lib/doctor_portal/prescriptions/prescription_controller.dart` | `lib/features/doctor_portal/presentation/prescriptions/prescription_controller.dart` |
| `lib/doctor_portal/prescriptions/prescription_detail_screen.dart` | `lib/features/doctor_portal/presentation/prescriptions/prescription_detail_screen.dart` |
| `lib/doctor_portal/prescriptions/prescription_screen.dart` | `lib/features/doctor_portal/presentation/prescriptions/prescription_screen.dart` |
| `lib/doctor_portal/ratings/doctor_rating_controller.dart` | `lib/features/doctor_portal/presentation/ratings/doctor_rating_controller.dart` |
| `lib/doctor_portal/ratings/doctor_rating_popup.dart` | `lib/features/doctor_portal/presentation/ratings/doctor_rating_popup.dart` |
| `lib/doctor_portal/shared_reports/doctor_shared_reports_screen.dart` | `lib/features/doctor_portal/presentation/shared_reports/doctor_shared_reports_screen.dart` |
| `lib/features/doctor_video/doctor_video_controller.dart` | `lib/features/doctor_videos/presentation/doctor_video_controller.dart` |
| `lib/features/appointment/doctor_details_screen.dart` | `lib/features/doctors/presentation/doctor_details_screen.dart` |
| `lib/home_screen/doctor_list_widget/doctor_list.dart` | `lib/features/doctors/presentation/doctor_list_widget.dart` |
| `lib/auth/doctor_profile/doctor_profile_screen.dart` | `lib/features/doctors/presentation/screens/doctor_profile_screen.dart` |
| `lib/auth/doctor_profile/update_doctor_profile.dart` | `lib/features/doctors/presentation/screens/update_doctor_profile_screen.dart` |
| `lib/features/patient/patient_portal_tab_provider.dart` | `lib/features/patients/presentation/patient_portal_tab_provider.dart` |
| `lib/features/patient/patient_portal_wrapper.dart` | `lib/features/patients/presentation/patient_portal_wrapper.dart` |
| `lib/auth/patient_profile/patient_profile_screen.dart` | `lib/features/patients/presentation/screens/patient_profile_screen.dart` |
| `lib/auth/payment/payment_screen.dart` | `lib/features/payments/presentation/screens/payment_screen.dart` |
| `lib/home_widget/reports/patient_shared_reports/patient_shared_reports_screen.dart` | `lib/features/reports/presentation/patient_shared_reports/patient_shared_reports_screen.dart` |
| `lib/home_widget/reports/report_controller/report_controller.dart` | `lib/features/reports/presentation/report_controller/report_controller.dart` |
| `lib/home_widget/reports/report_history/medical_history_item.dart` | `lib/features/reports/presentation/report_history/medical_history_item.dart` |
| `lib/home_widget/reports/report_history/report_history.dart` | `lib/features/reports/presentation/report_history/report_history_screen.dart` |
| `lib/home_widget/reports/report_share_controller/report_share_controller.dart` | `lib/features/reports/presentation/report_share_controller/report_share_controller.dart` |
| `lib/home_widget/reports/share_report_screen/share_report_screen.dart` | `lib/features/reports/presentation/share_report_screen/share_report_screen.dart` |
| `lib/home_widget/reports/upload_report_screen/upload_report_screen.dart` | `lib/features/reports/presentation/upload_report_screen/upload_report_screen.dart` |
| `lib/features/splash/splash_screen.dart` | `lib/features/splash/presentation/splash_screen.dart` |
| `lib/shared/widgets/custom_textfield.dart` | `lib/shared/widgets/custom_text_field.dart` |
| `lib/shared/widgets/opd_design.dart` | `lib/shared/widgets/opd_design_system.dart` |

## Deleted files

| Path | Reason |
| --- | --- |
| `lib/app/app.dart` | Unused duplicate root widget (`TelemedicineApp`). The real root is `MyApp` in `lib/main.dart`. |
| `lib/core/extensions/extensions.dart` | Verified unused: no imports and no runtime references in `lib/` or `test/`. |
| `lib/shared/widgets/common_widgets.dart` | Verified unused: 7 widgets with no imports in `lib/` or `test/`. |

## Identifier (class) renames inside files

| Old identifier | New identifier | Reason |
| --- | --- | --- |
| `ChatingListWidget` | `ChatListWidget` | Spelling error; filename also corrected. |
| `_ChatingListWidgetState` | `_ChatListWidgetState` | Follows class rename. |
| `CreateDcotorId` | `CreateDoctorIdScreen` | Spelling error + screen suffix. |
| `_CreateDcotorIdState` | `_CreateDoctorIdScreenState` | Follows class rename. |
| `MyTextfield` | `CustomTextField` | Public widget name now matches file and purpose. |
| `_MyTextfieldState` | `_CustomTextFieldState` | Follows class rename. |
| `UpdateDoctorProfile` | `UpdateDoctorProfileScreen` | Screen naming consistency. |
| `_UpdateDoctorProfileState` | `_UpdateDoctorProfileScreenState` | Follows class rename. |

## Intentionally unchanged paths / identifiers

- `lib/main.dart` and `lib/firebase_options.dart`
- `functions/index.js`, `functions/package.json`, `functions/package-lock.json`
- `firebase.json`, `firestore.rules`, `storage.rules`, `firestore.indexes.json`
- `android/`, `ios/`, `web/`, `windows/`, `macos/`, `linux/`
- Firestore collection/document/field names and Cloud Function export names
- `assets/images/`, `assets/sound/`, and `pubspec.yaml` asset entries
