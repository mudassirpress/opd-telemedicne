// payment_complaint_visibility_service.dart
//
// Single source of truth for Help / Complaint button visibility.
//
// RULES:
// 1. Only patients have access to the payment Help / Complaint button (never doctors or admins).
// 2. Guests do not have an account payment submission to complain about.
// 3. If patient's account is expired (`user.isExpired == true`), the button is VISIBLE
//    (they need reactivation help or have a pending/rejected reactivation proof).
// 4. If patient is an active, valid Patient Card user (`user.isPatientIdUser && !user.isExpired`),
//    their access is approved and valid -> button is HIDDEN.
// 5. For standard patients:
//    - If payment is approved/completed and not expired -> button is HIDDEN.
//    - If payment is pending, rejected, or unsubmitted -> button is VISIBLE.
// 6. Appointment payments do NOT affect this account-level visibility: an approved
//    appointment payment does not hide the account complaint button if the account
//    itself is unapproved, pending, rejected, or expired.

import 'package:telemedicine/data/models/user_model.dart';

class PaymentComplaintVisibility {
  const PaymentComplaintVisibility._();

  /// Returns `true` if the patient's account activation or reactivation is
  /// approved and currently valid (not expired).
  static bool isAccountPaymentApprovedAndValid(UserModel? user) {
    if (user == null) return false;
    if (user.role != 'patient') return false;
    if (user.isExpired) return false;

    // Active, valid patient ID (card) user
    if (user.isPatientIdUser) return true;

    final status = (user.paymentStatus ?? '').toLowerCase().trim();
    final isApproved =
        (status == 'approved' || status == 'completed') ||
        user.ispayment == true;
    return isApproved;
  }

  /// Determines whether the Help / Complaint button should be visible.
  ///
  /// The button is shown ONLY when the account payment is NOT approved
  /// (e.g. pending, rejected, not submitted, or expired).
  /// Once approved and valid, the button is automatically hidden.
  static bool shouldShow(UserModel? user) {
    if (user == null) return false;
    if (user.role != 'patient') return false;
    if (user.isGuest) return false;

    // Expired patient always has access to Help / Complaint for reactivation
    if (user.isExpired) return true;

    // Active, valid patient card user -> hidden
    if (user.isPatientIdUser) return false;

    // If account payment is approved and valid, hide the button
    if (isAccountPaymentApprovedAndValid(user)) {
      return false;
    }

    // Pending, rejected, or not submitted -> show button
    return true;
  }
}
