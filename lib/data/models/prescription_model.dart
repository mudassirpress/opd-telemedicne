import 'package:cloud_firestore/cloud_firestore.dart';

/// A prescription issued by a doctor to a patient.
///
/// The document id IS the `prescriptionId`, so a chat message of type
/// `prescription` only needs to carry that id to link the two together.
class PrescriptionModel {
  final String prescriptionId;
  final String doctorId;
  final String doctorName;
  final String patientId;
  final String patientName;

  /// Age captured at the time of prescribing (a snapshot, so the printed
  /// prescription stays accurate even if the profile later changes).
  final String patientAge;

  /// The doctor's full multiline prescription / instructions.
  final String note;

  final DateTime createdAt;

  /// Conversation this was issued from (`"{idA}_{idB}"` sorted pair). Kept on
  /// the document so the list can be queried per chat without loading messages.
  final String chatId;

  const PrescriptionModel({
    required this.prescriptionId,
    required this.doctorId,
    required this.doctorName,
    required this.patientId,
    required this.patientName,
    this.patientAge = '',
    this.note = '',
    required this.createdAt,
    this.chatId = '',
  });

  factory PrescriptionModel.fromMap(
    String id,
    Map<String, dynamic> map,
  ) {
    return PrescriptionModel(
      prescriptionId: (map['prescriptionId'] ?? id).toString(),
      doctorId: (map['doctorId'] ?? '').toString(),
      doctorName: (map['doctorName'] ?? '').toString(),
      patientId: (map['patientId'] ?? '').toString(),
      patientName: (map['patientName'] ?? '').toString(),
      patientAge: (map['patientAge'] ?? '').toString(),
      note: (map['note'] ?? '').toString(),
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      chatId: (map['chatId'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'prescriptionId': prescriptionId,
        'doctorId': doctorId,
        'doctorName': doctorName,
        'patientId': patientId,
        'patientName': patientName,
        'patientAge': patientAge,
        'note': note,
        'createdAt': Timestamp.fromDate(createdAt),
        'chatId': chatId,
      };

  /// A short, human-friendly reference printed at the bottom of the
  /// prescription, e.g. `RX-7F3A21C4`.
  String get reference {
    final suffix = prescriptionId
        .replaceAll('-', '')
        .toUpperCase()
        .padLeft(8, '0');
    return 'RX-${suffix.length > 8 ? suffix.substring(suffix.length - 8) : suffix}';
  }
}
