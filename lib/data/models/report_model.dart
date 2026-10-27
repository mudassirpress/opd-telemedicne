import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class ReportModel {
  final String id;
  final String userId;
  final String reportType;
  final String description;
  final String fileUrl;
  final DateTime reportDate;
  final DateTime uploadDate;
  final DateTime? reviewedAt;
  final String? reviewedBy;

  ReportModel({
    required this.id,
    required this.userId,
    required this.reportType,
    required this.description,
    required this.fileUrl,
    required this.reportDate,
    required this.uploadDate,
    this.reviewedAt,
    this.reviewedBy,
  });

  factory ReportModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ReportModel(
      id: doc.id,
      userId: data['userId'] ?? '',
      reportType: data['reportType'] ?? '',
      description: data['description'] ?? '',
      fileUrl: data['fileUrl'] ?? '',
      reportDate:
          (data['reportDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      uploadDate:
          (data['uploadDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      reviewedAt: (data['reviewedAt'] as Timestamp?)?.toDate(),
      reviewedBy: data['reviewedBy'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'reportType': reportType,
      'description': description,
      'fileUrl': fileUrl,
      'reportDate': Timestamp.fromDate(reportDate),
      'uploadDate': Timestamp.fromDate(uploadDate),
      'reviewedAt': reviewedAt != null ? Timestamp.fromDate(reviewedAt!) : null,
      'reviewedBy': reviewedBy,
    };
  }

  ReportModel copyWith({
    String? id,
    String? userId,
    String? reportType,
    String? description,
    String? fileUrl,
    DateTime? reportDate,
    DateTime? uploadDate,
    DateTime? reviewedAt,
    String? reviewedBy,
  }) {
    return ReportModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      reportType: reportType ?? this.reportType,
      description: description ?? this.description,
      fileUrl: fileUrl ?? this.fileUrl,
      reportDate: reportDate ?? this.reportDate,
      uploadDate: uploadDate ?? this.uploadDate,
      reviewedAt: reviewedAt ?? this.reviewedAt,
      reviewedBy: reviewedBy ?? this.reviewedBy,
    );
  }
}

enum ReportType {
  laboratory('Laboratory Test', Icons.science),
  radiology('Radiology', Icons.medical_services),
  medical('Medical Record', Icons.description),
  other('Other', Icons.more_horiz);

  final String displayName;
  final IconData icon;

  const ReportType(this.displayName, this.icon);

  static ReportType fromString(String value) {
    return ReportType.values.firstWhere(
      (type) => type.displayName == value,
      orElse: () => ReportType.other,
    );
  }

  static List<String> get allDisplayNames {
    return ReportType.values.map((type) => type.displayName).toList();
  }
}
