// In user_model.dart - Add isDeleted field
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/firestore_time.dart';

class UserModel {
  final String id;
  final String fullname;
  final String? image;
  final String deviceId;
  final String idcard;
  final String password;
  final String token;
  final String role;
  final String phoneNumber;
  final bool ispayment;
  final double totalPayment;
  final String? paymentImage;
  final String? highestDegree;
  final String? doctorId;
  final String? paymentStatus;
  final String? fcmToken;
  final bool? isDeleted; // Add this field
  final DateTime? paymentSubmittedAt;
  final String? rejectionReason;
  final String? patientId; // 12-digit unique Patient ID
  final String? paymentId;
  final String? gender;
  final int? age;
  final DateTime? expiryDate; // 6-month or plan-based expiry from activation/reactivation
  final String? cardStatus; // Card status (e.g. 'Active', 'Expired', 'Blocked')
  // Persisted authentication source: 'patientId' for Patient ID users,
  // 'normal' for normal signup/login patients. Stored in Firestore + local
  // session so the bypass survives navigation and app restarts.
  final String? loginType;
  /// Subscription plan ID ('one_month', 'six_months', 'one_year').
  final String? subscriptionPlan;
  /// Subscription duration in whole months (1, 6, 12).
  final int? durationMonths;
  /// The timestamp the subscription was activated/started.
  final DateTime? subscriptionStartDate;
  final String? authUid;

  /// Whether this session is an unauthenticated guest session.
  bool get isGuest => role == 'guest';

  /// Strongly-typed subscription plan representation (defaults to legacy 6 months).
  SubscriptionPlan get plan => SubscriptionPlan.fromPlanId(subscriptionPlan);

  /// Effective duration in whole months.
  int get effectiveDurationMonths => durationMonths ?? plan.durationMonths;
  /// Languages a doctor consults in. Always a non-null list — empty means the
  /// doctor has not declared any, which the UI renders as an empty state
  /// rather than an error. See [DoctorLanguages].
  final List<String> languages;

  // ── Appointment booking fields (doctor profiles only) ──────────────────
  /// Price of one consultation, in PKR, as stored under the `price` key on the
  /// doctor document.
  ///
  /// Nullable on purpose: doctor documents created before this field existed
  /// simply do not carry it, and [UserModel.fromMap] must resolve them to
  /// `null` rather than throw. Use [consultationPrice] when a non-null amount
  /// is needed.
  final double? price;

  /// Legacy spelling of the same amount, read from `consultationFee`.
  ///
  /// Always resolved: [fromMap] falls back to `price` when a document only
  /// carries the newer key, so `0` means "the doctor has not set a price yet"
  /// and the appointment flow renders "Not set" rather than a bookable amount.
  final double consultationFee;

  /// Optional separate fee for a video consultation.
  final double? videoConsultationFee;

  /// Percentage knocked off the consultation fee once the required
  /// educational video has been watched. `null` falls back to
  /// `AppointmentDefaults.videoDiscountPercent`.
  final double? discountPercentage;

  /// Free-form "about" text shown on the patient-facing doctor details page.
  ///
  /// `null` for a document written before the field existed — every reader
  /// must treat that as "no description yet", never as an error.
  final String? description;

  /// YouTube link of the doctor's educational video. Empty/absent means the
  /// Watch Video step is hidden for this doctor.
  final String? youtubeVideoUrl;

  /// Whether this user authenticated through the Patient ID / Patient Card flow.
  /// Patient Card users bypass the payment gate entirely. The `loginType` is the explicit
  /// persisted source; `patientId` presence or cardStatus is kept as a fallback for legacy
  /// accounts that predate the `loginType` field.
  bool get isPatientIdUser =>
      loginType == 'patientId' ||
      (patientId != null && patientId!.isNotEmpty) ||
      (cardStatus != null && cardStatus!.isNotEmpty);

  /// Domain-specific alias for Patient Card user check.
  bool get isPatientCard => isPatientIdUser;

  /// The amount a patient is charged for one consultation.
  ///
  /// `price` wins when the document carries it; documents written before the
  /// `price` field existed only have `consultationFee`, which [fromMap] has
  /// already back-filled from `price`. The result is never null, so a screen
  /// can render `0` as an empty/"not set" state instead of crashing.
  double get consultationPrice => price ?? consultationFee;

  UserModel({
    required this.id,
    required this.fullname,
    this.image,
    required this.deviceId,
    required this.idcard,
    required this.password,
    required this.token,
    required this.role,
    required this.phoneNumber,
    required this.ispayment,
    required this.totalPayment,
    this.paymentImage,
    this.highestDegree,
    this.doctorId,
    this.paymentStatus,
    this.fcmToken,
    this.isDeleted, // Add this
    this.paymentSubmittedAt,
    this.rejectionReason,
    this.patientId,
    this.paymentId,
    this.gender,
    this.age,
    this.expiryDate,
    this.cardStatus,
    this.loginType,
    this.subscriptionPlan,
    this.durationMonths,
    this.subscriptionStartDate,
    this.authUid,
    List<String> languages = const <String>[],
    this.price,
    this.consultationFee = 0,
    this.videoConsultationFee,
    this.discountPercentage,
    this.description,
    this.youtubeVideoUrl,
  }) : languages = List<String>.unmodifiable(languages);

  /// Factory creating an unauthenticated guest session.
  factory UserModel.guest() {
    return UserModel(
      id: 'guest_user',
      fullname: 'Guest User',
      deviceId: '',
      idcard: '',
      password: '',
      token: '',
      role: 'guest',
      phoneNumber: '',
      ispayment: false,
      totalPayment: 0.0,
      loginType: 'guest',
    );
  }

  factory UserModel.fromMap(Map<String, dynamic> map) {
    return UserModel(
      id: map['id'] ?? '',
      fullname: map['fullname'] ?? '',
      image: map['image'],
      deviceId: map['deviceId'] ?? '',
      idcard: map['idcard'] ?? '',
      password: map['password'] ?? '',
      token: map['token'] ?? '',
      role: map['role'] ?? 'patient',
      phoneNumber: map['phoneNumber'] ?? '',
      ispayment: map['ispayment'] ?? false,
      totalPayment: (map['totalPayment'] ?? 0.0).toDouble(),
      paymentImage: map['paymentImage'],
      highestDegree: map['highestDegree'],
      doctorId: map['doctorId'],
      paymentStatus: map['paymentStatus'],
      fcmToken: map['fcmToken'],
      isDeleted: map['isDeleted'] ?? false, // Add this
      // Tolerates every shape `paymentSubmittedAt` has been written in — the
      // patient writes an ISO String, but a server-side `serverTimestamp()` or a
      // hand-written Timestamp would make a bare `DateTime.tryParse` throw
      // (it only accepts String), taking down every screen that lists payments.
      paymentSubmittedAt: parseFirestoreTimestamp(map['paymentSubmittedAt']),
      rejectionReason: map['rejectionReason'],
      patientId: map['patientId'],
      paymentId: _asString(map['paymentId']),
      gender: map['gender'],
      age: map['age'],
      expiryDate: _parseExpiryDate(
        map['expiryDate'] ??
            map['patientCardExpiryDate'] ??
            map['cardValidUntil'],
      ),
      cardStatus: _asString(map['cardStatus']),
      loginType: map['loginType'],
      subscriptionPlan: _asString(map['subscriptionPlan']),
      durationMonths: map['durationMonths'] is int
          ? map['durationMonths']
          : (map['durationMonths'] is num
              ? (map['durationMonths'] as num).toInt()
              : int.tryParse(map['durationMonths']?.toString() ?? '')),
      subscriptionStartDate: parseFirestoreTimestamp(
        map['subscriptionStartDate'] ?? map['assignedAt'] ?? map['startDate'],
      ),
      authUid: _asString(map['authUid'] ?? map['uid']),
      languages: DoctorLanguages.parse(
        // `language` (singular) is the pre-list spelling; prefer the list and
        // fall back so a record written by an older build still renders.
        map[DoctorLanguages.field] ?? map[DoctorLanguages.legacyField],
      ),
      // Missing on every document written before the price field existed —
      // `null` here is the normal case for old doctors, not an error.
      price: _toDouble(map['price']),
      // `price` is the field the profile screens write; `consultationFee` is
      // the legacy spelling. Either key alone resolves to the same amount, and
      // a document carrying neither resolves to 0 ("not set") instead of
      // throwing inside the parser every screen runs.
      consultationFee:
          _positive(_toDouble(map['price'])) ??
              _toDouble(map['consultationFee']) ??
              0,
      videoConsultationFee: _toDouble(map['videoConsultationFee']),
      discountPercentage: _toDouble(map['discountPercentage']),
      description: _asString(map['description']),
      youtubeVideoUrl: _asString(map['youtubeVideoUrl']),
    );
  }

  /// Firestore has been observed holding a fee as `double`, `int` and — for
  /// hand-edited records — `String`. Anything unparseable resolves to `null`
  /// (or `0` for the required fee) instead of throwing inside `fromMap`, which
  /// runs for every screen that lists doctors.
  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  /// Only amounts a patient could actually be charged, so a document that has
  /// a `price` placeholder of `0` still falls back to a real legacy fee.
  static double? _positive(double? value) =>
      (value == null || value <= 0) ? null : value;

  /// Description/text fields are written as `String`, but a hand-edited
  /// document can hold anything. Coerce instead of casting: a cast inside
  /// [fromMap] would take down every screen that lists doctors.
  static String? _asString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'fullname': fullname,
      'image': image,
      'deviceId': deviceId,
      'idcard': idcard,
      'password': password,
      'token': token,
      'role': role,
      'phoneNumber': phoneNumber,
      'ispayment': ispayment,
      'totalPayment': totalPayment,
      'paymentImage': paymentImage,
      'highestDegree': highestDegree,
      'doctorId': doctorId,
      'paymentStatus': paymentStatus,
      'fcmToken': fcmToken,
      'isDeleted': isDeleted ?? false, // Add this
      'paymentSubmittedAt': paymentSubmittedAt?.toIso8601String(),
      'rejectionReason': rejectionReason,
      'patientId': patientId,
      if (paymentId != null) 'paymentId': paymentId,
      'gender': gender,
      'age': age,
      'expiryDate': expiryDate?.toIso8601String(),
      'cardStatus': cardStatus,
      'loginType': loginType,
      if (authUid != null) 'authUid': authUid,
      if (subscriptionPlan != null) 'subscriptionPlan': subscriptionPlan,
      if (durationMonths != null) 'durationMonths': durationMonths,
      if (subscriptionStartDate != null)
        'subscriptionStartDate': subscriptionStartDate?.toIso8601String(),
      'languages': languages,
      if (role == 'doctor') 'price': consultationPrice,
      if (role == 'doctor') 'consultationFee': consultationPrice,
      if (role == 'doctor' && videoConsultationFee != null)
        'videoConsultationFee': videoConsultationFee,
      if (role == 'doctor' && discountPercentage != null)
        'discountPercentage': discountPercentage,
      if (role == 'doctor') 'description': description,
      if (role == 'doctor') 'youtubeVideoUrl': youtubeVideoUrl,
    };
  }

  /// Returns a copy with the given fields replaced.
  ///
  /// The profile edit screens previously rebuilt a `UserModel` field-by-field
  /// before saving it back to the session, which silently dropped every field
  /// they did not enumerate (`paymentStatus`, `isDeleted`, `age`, `gender`,
  /// `expiryDate`, …). Copying instead of reconstructing means a new field only
  /// has to be threaded through the two call sites that actually change it.
  UserModel copyWith({
    String? fullname,
    String? image,
    bool clearImage = false,
    String? highestDegree,
    String? phoneNumber,
    String? doctorId,
    String? fcmToken,
    String? loginType,
    String? cardStatus,
    DateTime? expiryDate,
    String? authUid,
    String? subscriptionPlan,
    int? durationMonths,
    DateTime? subscriptionStartDate,
    List<String>? languages,
    double? price,
    double? consultationFee,
    double? videoConsultationFee,
    double? discountPercentage,
    String? description,
    String? youtubeVideoUrl,
    String? paymentId,
    String? paymentImage,
    double? totalPayment,
    bool? ispayment,
    String? paymentStatus,
    String? rejectionReason,
    String? gender,
    int? age,
  }) {
    return UserModel(
      id: id,
      fullname: fullname ?? this.fullname,
      image: clearImage ? null : (image ?? this.image),
      deviceId: deviceId,
      idcard: idcard,
      password: password,
      token: token,
      role: role,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      ispayment: ispayment ?? this.ispayment,
      totalPayment: totalPayment ?? this.totalPayment,
      paymentImage: paymentImage ?? this.paymentImage,
      highestDegree: highestDegree ?? this.highestDegree,
      doctorId: doctorId ?? this.doctorId,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      fcmToken: fcmToken ?? this.fcmToken,
      isDeleted: isDeleted,
      paymentSubmittedAt: paymentSubmittedAt,
      rejectionReason: rejectionReason ?? this.rejectionReason,
      patientId: patientId,
      paymentId: paymentId ?? this.paymentId,
      gender: gender ?? this.gender,
      age: age ?? this.age,
      expiryDate: expiryDate ?? this.expiryDate,
      cardStatus: cardStatus ?? this.cardStatus,
      loginType: loginType ?? this.loginType,
      authUid: authUid ?? this.authUid,
      subscriptionPlan: subscriptionPlan ?? this.subscriptionPlan,
      durationMonths: durationMonths ?? this.durationMonths,
      subscriptionStartDate:
          subscriptionStartDate ?? this.subscriptionStartDate,
      languages: languages ?? this.languages,
      price: price ?? this.price,
      consultationFee: consultationFee ?? this.consultationFee,
      videoConsultationFee: videoConsultationFee ?? this.videoConsultationFee,
      discountPercentage: discountPercentage ?? this.discountPercentage,
      description: description ?? this.description,
      youtubeVideoUrl: youtubeVideoUrl ?? this.youtubeVideoUrl,
    );
  }

  /// Whether this patient's ID/Card has passed its expiry date or status.
  /// Only applies to patients (not doctors or admins).
  bool get isExpired {
    if (role != 'patient') return false;
    if (cardStatus != null && cardStatus!.toLowerCase() == 'expired') {
      return true;
    }
    if (expiryDate == null) return false;
    return DateTime.now().isAfter(expiryDate!);
  }

  /// Parses the several shapes `expiryDate` takes across the codebase.
  ///
  /// `telemedicine_patient.expiryDate` is written as an ISO String by [toMap],
  /// but is also read back as a Firestore `Timestamp` in places, and a
  /// legacy record may hold a native [DateTime]. Accepting only `String`
  /// silently yielded `null` for the other two, which made [isExpired]
  /// permanently false for those records.
  static DateTime? _parseExpiryDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    if (value is int) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(value);
      } catch (_) {
        return null;
      }
    }
    // Firestore Timestamp without importing cloud_firestore into the model:
    // it exposes `toDate()`, and `millisecondsSinceEpoch` for the epoch case.
    if (value is Object && value.runtimeType.toString() == 'Timestamp') {
      try {
        return (value as dynamic).toDate() as DateTime?;
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
