import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/features/doctor_portal/presentation/prescriptions/prescription_screen.dart';
import 'package:telemedicine/features/chat/presentation/chat_menu/chat_contact_screen.dart';
import 'package:telemedicine/features/chat/presentation/chat_menu/chat_favourites_provider.dart';
import 'package:telemedicine/features/chat/presentation/chat_menu/chat_media_screen.dart';
import 'package:telemedicine/features/chat/presentation/chat_menu/doctor_contact_screen.dart';
import 'package:telemedicine/shared/widgets/anchored_popup_menu.dart';

/// Builds and shows the WhatsApp-style overflow menu for the chat screen.
///
/// The menu is a small floating popup anchored directly under the 3-dot button
/// — not a bottom sheet and not a full-screen dialog. It wraps its content.
///
/// Entries come from the *actually logged-in* role, so a patient never sees
/// Prescription or View Contact, and a doctor never sees the Favourites toggle.
Future<void> showChatMenu({
  required BuildContext context,
  required WidgetRef ref,
  required GlobalKey anchorKey,
  required LayerLink anchorLink,
  required VoidCallback onSearch,
  required String currentUserId,
  required String currentUserRole,
  required String otherUserId,
  required String otherUserName,
  required String otherUserImage,
  required String otherUserRole,
  required String chatId,
  required List<ChatMessageModel> messages,
}) {
  final isDoctor = currentUserRole == UserRoles.doctor;
  final notifier = ref.read(chatFavouritesProvider.notifier);
  final isFavourite = notifier.isFavourite(
    chatId: chatId,
    otherUserId: otherUserId,
  );
  final navigator = Navigator.of(context, rootNavigator: true);

  return showAnchoredMenu(
    context: context,
    anchorKey: anchorKey,
    link: anchorLink,
    items: [
      if (isDoctor)
        AnchoredMenuItem(
          label: 'Prescription',
          onTap: () => navigator.push(
            MaterialPageRoute(
              builder: (_) => PrescriptionScreen(
                chatId: chatId,
                patientId: otherUserId,
                patientName: otherUserName,
              ),
            ),
          ),
        ),
      // View Contact for a DOCTOR looking at their patient keeps the richer
      // clinical card (age, gender, blood group, patient ID).
      if (isDoctor)
        AnchoredMenuItem(
          label: 'View Contact',
          onTap: () => navigator.push(
            MaterialPageRoute(
              builder: (_) => ChatContactScreen(
                userId: otherUserId,
                userName: otherUserName,
                userImage: otherUserImage,
                userRole: otherUserRole,
              ),
            ),
          ),
        ),
      // View Contact for a PATIENT looking at their doctor is a separate,
      // deliberately minimal screen: image, name, highest degree and languages
      // only — no ratings, fees, phone number or appointment actions. Routing
      // both roles to `ChatContactScreen` would leak the clinician-facing fields
      // into the patient view.
      if (!isDoctor && otherUserRole == UserRoles.doctor)
        AnchoredMenuItem(
          label: 'View Contact',
          onTap: () => navigator.push(
            MaterialPageRoute(
              builder: (_) => DoctorContactScreen(
                doctorId: otherUserId,
                doctorName: otherUserName,
                doctorImage: otherUserImage,
              ),
            ),
          ),
        ),
      // Search never leaves this screen — it turns the chat header into the
      // WhatsApp-style search header instead of pushing a new route.
      AnchoredMenuItem(
        label: 'Search',
        onTap: onSearch,
      ),
      AnchoredMenuItem(
        label: 'Media, Links & Docs',
        onTap: () => navigator.push(
          MaterialPageRoute(
            builder: (_) => ChatMediaScreen(
              messages: messages,
              currentUserId: currentUserId,
            ),
          ),
        ),
      ),
      if (!isDoctor)
        AnchoredMenuItem(
          label: isFavourite
              ? 'Remove from Favorites'
              : 'Add to Favorites',
          onTap: () => _toggleFavourite(
            notifier,
            chatId: chatId,
            otherUserId: otherUserId,
            otherUserName: otherUserName,
          ),
        ),
    ],
  );
}

Future<void> _toggleFavourite(
  ChatFavouritesNotifier notifier, {
  required String chatId,
  required String otherUserId,
  required String otherUserName,
}) async {
  final key = chatFavouriteKey(chatId: chatId, otherUserId: otherUserId);
  if (key.isEmpty) return;

  final nowFavourite = await notifier.toggle(key);
  ToastService.instance.showSuccess(
    nowFavourite
        ? '$otherUserName added to Favorites'
        : '$otherUserName removed from Favorites',
  );
}
