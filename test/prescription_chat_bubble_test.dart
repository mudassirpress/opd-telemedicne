import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/chat/presentation/chat_screen.dart';

void main() {
  test('ChatMessageModel correctly serializes prescription attributes', () {
    final now = DateTime(2026, 11, 4, 15, 30);
    final msg = ChatMessageModel(
      id: 'msg-rx-1',
      senderId: 'doc-1',
      receiverId: 'patient-1',
      message: 'Prescription document attached.',
      timestamp: now,
      messageType: 'prescription',
      prescriptionId: 'rx-999',
      doctorName: 'Dr. Sarah Ahmed',
      prescriptionDate: now,
      pdfUrl: 'https://firebasestorage.googleapis.com/.../prescription.pdf',
      previewImageUrl: 'https://firebasestorage.googleapis.com/.../preview.png',
      prescriptionNotePreview: 'Panadol 500mg - 1 tab twice daily',
    );

    expect(msg.isPrescription, isTrue);
    expect(msg.prescriptionId, equals('rx-999'));
    expect(msg.doctorName, equals('Dr. Sarah Ahmed'));
    expect(msg.pdfUrl, contains('prescription.pdf'));
    expect(msg.previewImageUrl, contains('preview.png'));

    final map = msg.toMap();
    expect(map['messageType'], equals('prescription'));
    expect(map['prescriptionId'], equals('rx-999'));
    expect(map['doctorName'], equals('Dr. Sarah Ahmed'));
    expect(map['pdfUrl'], contains('prescription.pdf'));
    expect(map['previewImageUrl'], contains('preview.png'));

    final restored = ChatMessageModel.fromMap(map);
    expect(restored.isPrescription, isTrue);
    expect(restored.doctorName, equals('Dr. Sarah Ahmed'));
    expect(restored.prescriptionId, equals('rx-999'));
  });
}
