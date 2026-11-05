import 'package:cloud_firestore/cloud_firestore.dart';

/// A single medicine item prescribed by a doctor.
class PrescriptionMedicine {
  final String name;
  final String strength;
  final String dosage;
  final String frequency;
  final String duration;
  final String instructions;

  const PrescriptionMedicine({
    required this.name,
    this.strength = '',
    this.dosage = '',
    this.frequency = '',
    this.duration = '',
    this.instructions = '',
  });

  factory PrescriptionMedicine.fromMap(Map<String, dynamic> map) {
    return PrescriptionMedicine(
      name: (map['name'] ?? '').toString().trim(),
      strength: (map['strength'] ?? '').toString().trim(),
      dosage: (map['dosage'] ?? '').toString().trim(),
      frequency: (map['frequency'] ?? '').toString().trim(),
      duration: (map['duration'] ?? '').toString().trim(),
      instructions: (map['instructions'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'strength': strength,
    'dosage': dosage,
    'frequency': frequency,
    'duration': duration,
    'instructions': instructions,
  };

  /// Single line preview e.g. "Panadol 500mg • 1 Tab • 1-0-1 • 5 Days • After meal"
  String get displayLine {
    final parts = <String>[];
    if (name.isNotEmpty) {
      parts.add(strength.isNotEmpty ? '$name ($strength)' : name);
    }
    if (dosage.isNotEmpty) parts.add(dosage);
    if (frequency.isNotEmpty) parts.add(frequency);
    if (duration.isNotEmpty) parts.add(duration);
    if (instructions.isNotEmpty) parts.add(instructions);
    return parts.join(' • ');
  }

  bool get isEmpty => name.isEmpty;
  bool get isNotEmpty => name.isNotEmpty;
}

/// An official prescription issued by a doctor to a patient in OPD Telemedicine.
///
/// The document id IS the `prescriptionId`, so a chat message of type
/// `prescription` only needs to carry that id to link the two together.
class PrescriptionModel {
  final String prescriptionId;
  final String doctorId;
  final String doctorName;

  /// Highest qualification/degree (e.g., MBBS, FCPS, MD).
  final String doctorQualification;

  /// Specialty/designation (e.g. General Physician, Consultant Cardiologist).
  final String doctorSpecialty;

  final String patientId;
  final String patientName;

  /// Age captured at the time of prescribing (a snapshot, so the printed
  /// prescription stays accurate even if the profile later changes).
  final String patientAge;

  /// Gender snapshot (e.g. Male, Female, Other).
  final String patientGender;

  /// The doctor's full written prescription / general notes.
  final String note;

  /// Structured list of medicines prescribed.
  final List<PrescriptionMedicine> medicines;

  /// Additional medical advice.
  final String advice;

  /// Follow-up instructions (e.g. "Review after 7 days").
  final String followUp;

  /// Optional Firebase Storage download URL for the generated PDF document.
  final String? pdfUrl;

  /// Optional Firebase Storage download URL for the generated PNG preview image.
  final String? previewImageUrl;

  /// Permanent high-resolution PNG image download URLs for each page in order.
  /// This is the Single Source of Truth for prescription viewing across the app.
  final List<String> pageImageUrls;

  /// Corresponding Firebase Storage paths for each page image.
  final List<String> imageStoragePaths;

  /// Total number of prescription pages.
  final int pageCount;

  final DateTime createdAt;
  final DateTime? updatedAt;

  /// Conversation this was issued from (`"{idA}_{idB}"` sorted pair).
  final String chatId;

  /// Associated appointment / consultation ID, if applicable.
  final String appointmentId;

  const PrescriptionModel({
    required this.prescriptionId,
    required this.doctorId,
    required this.doctorName,
    this.doctorQualification = '',
    this.doctorSpecialty = '',
    required this.patientId,
    required this.patientName,
    this.patientAge = '',
    this.patientGender = '',
    this.note = '',
    this.medicines = const [],
    this.advice = '',
    this.followUp = '',
    this.pdfUrl,
    this.previewImageUrl,
    this.pageImageUrls = const [],
    this.imageStoragePaths = const [],
    this.pageCount = 1,
    required this.createdAt,
    this.updatedAt,
    this.chatId = '',
    this.appointmentId = '',
  });

  bool get hasMedicines => medicines.any((m) => m.isNotEmpty);

  /// Primary image URL for single-image preview or page 1.
  String get primaryImageUrl {
    if (pageImageUrls.isNotEmpty && pageImageUrls.first.trim().isNotEmpty) {
      return pageImageUrls.first;
    }
    return previewImageUrl ?? '';
  }

  factory PrescriptionModel.fromMap(String id, Map<String, dynamic> map) {
    final rawMeds = map['medicines'];
    final parsedMeds = <PrescriptionMedicine>[];
    if (rawMeds is List) {
      for (final item in rawMeds) {
        if (item is Map) {
          parsedMeds.add(
            PrescriptionMedicine.fromMap(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    final rawPageUrls = map['pageImageUrls'] ?? map['imageUrls'];
    final parsedPageUrls = <String>[];
    if (rawPageUrls is List) {
      for (final u in rawPageUrls) {
        if (u != null && u.toString().trim().isNotEmpty) {
          parsedPageUrls.add(u.toString().trim());
        }
      }
    }
    final singleImg = (map['previewImageUrl'] ??
            map['previewUrl'] ??
            map['imageUrl'])
        ?.toString()
        .trim();
    if (parsedPageUrls.isEmpty && singleImg != null && singleImg.isNotEmpty) {
      parsedPageUrls.add(singleImg);
    }

    final rawPaths = map['imageStoragePaths'];
    final parsedPaths = <String>[];
    if (rawPaths is List) {
      for (final p in rawPaths) {
        if (p != null && p.toString().trim().isNotEmpty) {
          parsedPaths.add(p.toString().trim());
        }
      }
    }

    final int count = (map['pageCount'] as num?)?.toInt() ??
        (parsedPageUrls.isNotEmpty ? parsedPageUrls.length : 1);

    return PrescriptionModel(
      prescriptionId: (map['prescriptionId'] ?? id).toString(),
      doctorId: (map['doctorId'] ?? '').toString(),
      doctorName: (map['doctorName'] ?? '').toString(),
      doctorQualification:
          (map['doctorQualification'] ??
                  map['qualification'] ??
                  map['highestDegree'] ??
                  '')
              .toString(),
      doctorSpecialty:
          (map['doctorSpecialty'] ??
                  map['specialty'] ??
                  map['specialization'] ??
                  map['designation'] ??
                  '')
              .toString(),
      patientId: (map['patientId'] ?? '').toString(),
      patientName: (map['patientName'] ?? '').toString(),
      patientAge: (map['patientAge'] ?? map['age'] ?? '').toString(),
      patientGender: (map['patientGender'] ?? map['gender'] ?? '').toString(),
      note: (map['note'] ?? '').toString(),
      medicines: parsedMeds,
      advice: (map['advice'] ?? '').toString(),
      followUp: (map['followUp'] ?? map['followup'] ?? '').toString(),
      pdfUrl: map['pdfUrl']?.toString(),
      previewImageUrl: parsedPageUrls.isNotEmpty
          ? parsedPageUrls.first
          : singleImg,
      pageImageUrls: parsedPageUrls,
      imageStoragePaths: parsedPaths,
      pageCount: count,
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
      chatId: (map['chatId'] ?? '').toString(),
      appointmentId: (map['appointmentId'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() => {
    'prescriptionId': prescriptionId,
    'doctorId': doctorId,
    'doctorName': doctorName,
    'doctorQualification': doctorQualification,
    'doctorSpecialty': doctorSpecialty,
    'patientId': patientId,
    'patientName': patientName,
    'patientAge': patientAge,
    'patientGender': patientGender,
    'note': note,
    'medicines': medicines.map((m) => m.toMap()).toList(),
    'advice': advice,
    'followUp': followUp,
    if (pdfUrl != null && pdfUrl!.isNotEmpty) 'pdfUrl': pdfUrl,
    if (primaryImageUrl.isNotEmpty) 'previewImageUrl': primaryImageUrl,
    if (primaryImageUrl.isNotEmpty) 'imageUrl': primaryImageUrl,
    if (pageImageUrls.isNotEmpty) 'pageImageUrls': pageImageUrls,
    if (imageStoragePaths.isNotEmpty) 'imageStoragePaths': imageStoragePaths,
    'pageCount': pageCount > 0
        ? pageCount
        : (pageImageUrls.isNotEmpty ? pageImageUrls.length : 1),
    'createdAt': Timestamp.fromDate(createdAt),
    if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
    'chatId': chatId,
    'appointmentId': appointmentId,
  };

  PrescriptionModel copyWith({
    String? prescriptionId,
    String? doctorId,
    String? doctorName,
    String? doctorQualification,
    String? doctorSpecialty,
    String? patientId,
    String? patientName,
    String? patientAge,
    String? patientGender,
    String? note,
    List<PrescriptionMedicine>? medicines,
    String? advice,
    String? followUp,
    String? pdfUrl,
    String? previewImageUrl,
    List<String>? pageImageUrls,
    List<String>? imageStoragePaths,
    int? pageCount,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? chatId,
    String? appointmentId,
  }) {
    return PrescriptionModel(
      prescriptionId: prescriptionId ?? this.prescriptionId,
      doctorId: doctorId ?? this.doctorId,
      doctorName: doctorName ?? this.doctorName,
      doctorQualification: doctorQualification ?? this.doctorQualification,
      doctorSpecialty: doctorSpecialty ?? this.doctorSpecialty,
      patientId: patientId ?? this.patientId,
      patientName: patientName ?? this.patientName,
      patientAge: patientAge ?? this.patientAge,
      patientGender: patientGender ?? this.patientGender,
      note: note ?? this.note,
      medicines: medicines ?? this.medicines,
      advice: advice ?? this.advice,
      followUp: followUp ?? this.followUp,
      pdfUrl: pdfUrl ?? this.pdfUrl,
      previewImageUrl: previewImageUrl ?? this.previewImageUrl,
      pageImageUrls: pageImageUrls ?? this.pageImageUrls,
      imageStoragePaths: imageStoragePaths ?? this.imageStoragePaths,
      pageCount: pageCount ?? this.pageCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      chatId: chatId ?? this.chatId,
      appointmentId: appointmentId ?? this.appointmentId,
    );
  }

  /// A short, human-friendly reference printed on the prescription, e.g. `RX-7F3A21C4`.
  String get reference {
    final suffix = prescriptionId
        .replaceAll('-', '')
        .toUpperCase()
        .padLeft(8, '0');
    return 'RX-${suffix.length > 8 ? suffix.substring(suffix.length - 8) : suffix}';
  }
}
