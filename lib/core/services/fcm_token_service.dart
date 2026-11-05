// fcm_service_v2.dart - Aapki original keys ke saath

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/constants/app_constants.dart';

class FCMServiceV2 {
  static final FCMServiceV2 _instance = FCMServiceV2._internal();
  factory FCMServiceV2() => _instance;
  FCMServiceV2._internal();

  auth.AutoRefreshingAuthClient? _authClient;
  bool _isInitialized = false;
  Function(Map<String, dynamic>)? onCallReceived;
  Function(Map<String, dynamic>)? onMessageReceived;

  // Updated service account credentials (opd-telemedicine project)
  static const String _projectId = 'opd-telemedicine';
  static const String _privateKeyId =
      'cf3d895acfa31eb162a216406fc82201e195d9fd';

  static const String _privateKey = '''-----BEGIN PRIVATE KEY-----
MIIEuwIBADANBgkqhkiG9w0BAQEFAASCBKUwggShAgEAAoIBAQCmpxOArN+ZhgsL
S70JQEc0kDzOdQxnlLqHBBwtfAP51onp1J6N6FWrIeX8Gcq2sOfN/1i+lovimkRw
+C7bprR4HoQxR94hqigGOMI9K6NlxUj6SZg3mT2cHBlysmqZE7ZKM8MpdCwrbswe
ZgXnZ42+KOk1HyToKDaBcTg5Ze/Jq+shud2x8OE21JVQ2p9Bxmq9IIQGmhG++7tc
AzZbb8j/gDsoSAvr5eEQs4bBSeC0o27+AqeZvnHgNS0X0Ji10OOV/WlUPVxZMGE2
BnXv9CAUXe41pfRRlodne63aMoaCvfDQzXX31WRXmjEH9wF8vM3wNZ6ggXdq14ih
o62F5QZ3AgMBAAECgf9t6Bd0mo4x3F/Bk1xC6EwNiRKRFktCr1OqDOEzHhbWg3wb
j52sTmLb+f8zGSTCV5PeHLOU/gmYkyTlXB2LFDubpy8x+7OuKrSQEIlezj4fYCeW
Pp2kt+tp3nOUsRXxiTkvYUkp4vPpBlPtDbEsa57kn8EtcjIPlHWzPc1WuA5BcY9Y
LkQHTidgxjVSu8vdWFBSw7h7h0BxI6jiCXIDzMPR/F+iuIc+dUthOuqeKNV8o0HM
XW5eiahej36i1lI3hEA797mfVZuWERkBipVOIxCFSLKW1feVF+JIAnkKWMvdKxYm
ta3IR3uyNG+O1coZyQVUbxumHNZzco9I/NnOWmUCgYEA2SMQo21vH/czz9r9A9+L
7J13vuU5TTYRC6r98dgEOIdB7GQ+9hLxch3+khuxQsFgUjMs9hRlWssrRJsF05eN
X3V2zBTkapVwlbpmGLGihV0lqNGg4nvgfML34fweKIdPsHO9nnDxySmL/4oAcw8N
qlDm8ULEo1p1KowsMZCQFIMCgYEAxHribUBbENQUovGIAhb1OybeiBquwQq5gWk0
R7hfAoO9onudr40pMUdUONuP2FutIrOnGUi+Y0pIiOp49IvvaTYuOctC3Kgw/CV+
HMf3lStyEINORYM8CA2NhQgNCH9mvr3obGNR5IEqjNQ7x2L09PLFjCKFQGHU1MKB
Ik36a/0CgYAMOBTvnXDrc5XO1Jv4Y9QT9KiQbYXT+n7rESxJN8bFB5eGHf4NCvPb
YCS7RCOthgRNm+Oj1XH+sgA1VCP3zEeAX7PXuDVCajZztpGYQibLKnq8DU/obuAr
JS2d4fowfazWWS0KhYCVuWjPcIyl7Orv8q2MVh2Ks8R0KH80KtZw0QKBgG+RT821
w4A0zVsRR6fYHXxvP+GNNTpMurWvZY5sNRcac641/35V69Qdqsd2daHnvNJ9rR8A
XYvH/JQygGhspY/awjjzII5nuxkSuR/itMWxm92gkeuK76Wq/HdT8QKoRVF+SOJz
K2dTqTO6uA8qM+p7iI1gdMXwR4hgwi8WlGKJAoGBAJS6mj3STzt0AtWiRrY3Z3CS
xJR/fQTc5TrwHgefdIpRdLuw8LSBp3zDx0kVdkdYGuKXWyt6V5tRxp+S5185X5lD
xIE2UizQZyVOvtGBzTJTUHnti4um1n2H8lAEdVrBKR8kxp6qmpJNJ7VkiooRoXdE
erGD18JMmlDQqJH/tiS5
-----END PRIVATE KEY-----''';

  static const String _clientEmail =
      'firebase-adminsdk-fbsvc@opd-telemedicine.iam.gserviceaccount.com';
  static const String _clientId = '102255447953650596354';
  static const String _tokenUri = 'https://oauth2.googleapis.com/token';
  static const String _authUri = 'https://accounts.google.com/o/oauth2/auth';

  Future<void> initialize() async {
    if (_isInitialized && _authClient != null) {
      return;
    }

    try {
      final credentials = auth.ServiceAccountCredentials.fromJson({
        'type': 'service_account',
        'project_id': _projectId,
        'private_key_id': _privateKeyId,
        'private_key': _privateKey,
        'client_email': _clientEmail,
        'client_id': _clientId,
        'auth_uri': _authUri,
        'token_uri': _tokenUri,
        'auth_provider_x509_cert_url':
            'https://www.googleapis.com/oauth2/v1/certs',
        'client_x509_cert_url':
            'https://www.googleapis.com/robot/v1/metadata/x509/firebase-adminsdk-fbsvc%40opd-telemedicine.iam.gserviceaccount.com',
        'universe_domain': 'googleapis.com',
      });

      _authClient = await auth.clientViaServiceAccount(credentials, [
        'https://www.googleapis.com/auth/firebase.messaging',
      ]);

      _isInitialized = true;
      print('✅ FCM Service initialized successfully');
    } catch (e) {
      print('❌ Failed to initialize FCM Service: $e');
      _isInitialized = false;
      _authClient = null;
      rethrow;
    }
  }

  bool get isInitialized => _isInitialized;

  Future<String> _getAccessToken() async {
    if (_authClient == null) {
      await initialize();
    }
    final credentials = _authClient?.credentials;
    if (credentials == null) {
      throw Exception('Failed to obtain access token');
    }
    return credentials.accessToken.data;
  }

  Future<String?> getToken() async {
    try {
      final fcm = FirebaseMessaging.instance;

      if (defaultTargetPlatform == TargetPlatform.iOS) {
        // iOS requires APNs token before FCM token can be generated reliably
        final apnsToken = await fcm.getAPNSToken();
        if (apnsToken == null) {
          print(
            '⚠️ APNs token is null. FCM token generation might fail or be delayed on iOS.',
          );
        } else {
          print('✅ APNs token retrieved successfully.');
        }
      }

      final token = await fcm.getToken();
      return token;
    } catch (e) {
      print('Error getting FCM token: $e');
      return null;
    }
  }

  Future<void> updateToken(String userId, String userType) async {
    try {
      final token = await getToken();
      if (token == null) {
        print('No FCM token available');
        return;
      }

      final firestore = FirebaseFirestore.instance;
      final collection = userType == 'doctor'
          ? 'telemedicine_doctors'
          : 'telemedicine_patient';

      final docRef = firestore.collection(collection).doc(userId);

      await docRef.set({
        'fcmToken': token,
        'lastTokenUpdate': FieldValue.serverTimestamp(),
        'role': userType,
        'isOnline': true,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      print('✅ FCM token updated for $userType: $userId');
    } catch (e) {
      print('Error updating FCM token: $e');
    }
  }

  Future<String?> getUserToken(String userId, [String? preferredRole]) async {
    final cleanId = userId.trim();
    if (cleanId.isEmpty) return null;

    final firestore = FirebaseFirestore.instance;
    final collections = <String>[
      if (preferredRole == 'doctor') 'telemedicine_doctors',
      if (preferredRole == 'patient') 'telemedicine_patient',
      if (preferredRole != 'doctor') 'telemedicine_doctors',
      if (preferredRole != 'patient') 'telemedicine_patient',
    ];

    for (final col in collections) {
      try {
        final doc = await firestore.collection(col).doc(cleanId).get();
        if (doc.exists) {
          final token = doc.data()?['fcmToken']?.toString();
          if (token != null && token.isNotEmpty) {
            return token;
          }
        }
      } catch (e) {
        debugPrint('Error resolving FCM token from $col: $e');
      }
    }
    return null;
  }

  Future<bool> sendCallNotification({
    required String receiverToken,
    required String callerName,
    required String callType,
    required String callId,
    required String channelId,
    String? callerImage,
    String? callerId,
    String? callerType,
    String? receiverId,
    String? receiverType,
    int? expiresAtMillis,
    String? targetModule,
  }) async {
    try {
      await initialize();
      final accessToken = await _getAccessToken();
      final now = DateTime.now().millisecondsSinceEpoch;
      final expiresAt = expiresAtMillis ?? (now + 45000);

      final Map<String, dynamic> data = {
        'type': 'call',
        'targetModule': targetModule ?? 'opd_telemedicine',
        'callId': callId,
        'callerName': callerName,
        'callType': callType,
        'channelId': channelId,
        'roomId': channelId,
        'callerImage': callerImage ?? '',
        'callerId': callerId ?? '',
        'callerType': callerType ?? 'doctor',
        'receiverId': receiverId ?? '',
        'receiverType': receiverType ?? 'patient',
        'expiresAt': expiresAt.toString(),
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        'timestamp': now.toString(),
      };

      final Map<String, dynamic> message = {
        'token': receiverToken,
        'data': data,
        'android': {'priority': 'high', 'ttl': '30s'},
        'apns': {
          'headers': {'apns-priority': '10'},
          'payload': {
            'aps': {
              'sound': 'default',
              'badge': 1,
              'category': 'incoming_call',
              'content-available': 1,
            },
          },
        },
      };

      print(
        '📞 STAGE3_FCM_PAYLOAD_BUILT callId=$callId callerName=$callerName '
        'callType=$callType channelId=$channelId callerId=$callerId receiverToken=${receiverToken.length > 10 ? '${receiverToken.substring(0, 8)}...' : '[short]'}',
      );

      final response = await http.post(
        Uri.parse(
          'https://fcm.googleapis.com/v1/projects/$_projectId/messages:send',
        ),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({'message': message}),
      );

      if (response.statusCode == 200) {
        print('✅ STAGE3_FCM_PAYLOAD_DELIVERED_TO_FCM callId=$callId');
        print('Response: ${response.body}');
        return true;
      } else {
        print('❌ STAGE3_FCM_PAYLOAD_REJECTED status=${response.statusCode}');
        print('Response body: ${response.body}');
        return false;
      }
    } catch (e) {
      print('❌ Error sending call notification: $e');
      return false;
    }
  }

  Future<bool> sendMissedCallNotification({
    required String receiverToken,
    required String callerName,
    required String callType,
    required String callId,
    String? callerImage,
    String? callerId,
  }) async {
    try {
      await initialize();
      final accessToken = await _getAccessToken();
      final now = DateTime.now().millisecondsSinceEpoch;
      final isVideo = callType.toLowerCase() == 'video';

      final Map<String, dynamic> data = {
        'type': 'missed_call',
        'callId': callId,
        'callerName': callerName,
        'callType': callType,
        'callerImage': callerImage ?? '',
        'callerId': callerId ?? '',
        'timestamp': now.toString(),
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
      };

      final Map<String, dynamic> message = {
        'token': receiverToken,
        'data': data,
        'android': {
          'priority': 'high',
          'ttl': '172800s', // 48 hours persistence for offline delivery
          'notification': {
            'title': 'Missed ${isVideo ? 'Video' : 'Voice'} Call',
            'body': 'You missed a call from $callerName',
            'channel_id': NotificationChannels.missedCalls,
            'icon': 'ic_notification',
            'color': '#E53935',
          },
        },
        'apns': {
          'headers': {'apns-priority': '10', 'apns-push-type': 'alert'},
          'payload': {
            'aps': {
              'alert': {
                'title': 'Missed ${isVideo ? 'Video' : 'Voice'} Call',
                'body': 'You missed a call from $callerName',
              },
              'sound': 'default',
              'badge': 1,
            },
          },
        },
      };

      final response = await http.post(
        Uri.parse(
          'https://fcm.googleapis.com/v1/projects/$_projectId/messages:send',
        ),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({'message': message}),
      );

      if (response.statusCode == 200) {
        debugPrint('✅ STAGE3_FCM_MISSED_CALL_DELIVERED callId=$callId');
        return true;
      } else {
        debugPrint(
          '❌ STAGE3_FCM_MISSED_CALL_REJECTED status=${response.statusCode} body=${response.body}',
        );
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error sending missed call notification: $e');
      return false;
    }
  }

  /// Sends a high-priority data-only cancellation push to dismiss active CallKit / ringing UI
  /// on the receiver's device immediately when the caller hangs up before answer.
  Future<bool> sendCallCancelNotification({
    required String receiverToken,
    required String callId,
  }) async {
    try {
      await initialize();
      final accessToken = await _getAccessToken();
      final now = DateTime.now().millisecondsSinceEpoch;

      final Map<String, dynamic> data = {
        'type': 'call_cancel',
        'callId': callId,
        'timestamp': now.toString(),
      };

      final Map<String, dynamic> message = {
        'token': receiverToken,
        'data': data,
        'android': {'priority': 'high', 'ttl': '15s'},
        'apns': {
          'headers': {'apns-priority': '10', 'apns-push-type': 'background'},
          'payload': {
            'aps': {'content-available': 1},
          },
        },
      };

      final response = await http.post(
        Uri.parse(
          'https://fcm.googleapis.com/v1/projects/$_projectId/messages:send',
        ),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({'message': message}),
      );

      debugPrint(
        '📞 [FCM] Dispatched call_cancel push for callId=$callId (status=${response.statusCode})',
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('❌ Error sending call_cancel notification: $e');
      return false;
    }
  }

  Future<bool> sendChatNotification({
    required String receiverToken,
    required String senderName,
    required String receiverName,
    required String messageBody,
    required String chatId,
    required String senderId,
    required String receiverId,
    String? messageId,
    String? senderProfileImage,
  }) async {
    try {
      await initialize();
      final accessToken = await _getAccessToken();

      final Map<String, dynamic> data = {
        'type': 'chat_message',
        'chatId': chatId,
        'messageId': messageId ?? '',
        'senderId': senderId,
        'receiverId': receiverId,
        'senderName': senderName,
        'senderProfileImage': senderProfileImage ?? '',
        'messageText': messageBody,
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      };

      final Map<String, dynamic> message = {
        'token': receiverToken,
        'data': data,
        'notification': {
          'title': senderName,
          'body': messageBody.length > 100
              ? '${messageBody.substring(0, 100)}...'
              : messageBody,
        },
        'android': {
          'priority': 'high',
          'notification': {
            'channel_id': 'chat_notifications',
            'sound': 'default',
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
          },
        },
        'apns': {
          'headers': {'apns-priority': '10'},
          'payload': {
            'aps': {
              'alert': {
                'title': senderName,
                'body': messageBody.length > 100
                    ? '${messageBody.substring(0, 100)}...'
                    : messageBody,
              },
              'sound': 'default',
              'badge': 1,
              'content-available': 1,
            },
          },
        },
      };

      final response = await http.post(
        Uri.parse(
          'https://fcm.googleapis.com/v1/projects/$_projectId/messages:send',
        ),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({'message': message}),
      );

      if (response.statusCode == 200) {
        print('✅ Chat notification sent successfully');
        return true;
      } else {
        print('❌ Failed to send chat notification: ${response.statusCode}');
        print('Response body: ${response.body}');
        return false;
      }
    } catch (e) {
      print('Error sending chat notification: $e');
      return false;
    }
  }

  Future<bool> sendReportNotification({
    required String receiverToken,
    required String patientId,
    required String patientName,
    required String reportId,
    required String reportName,
    required String doctorId,
    String? messageBody,
  }) async {
    try {
      await initialize();
      final accessToken = await _getAccessToken();

      final String body =
          messageBody ?? 'A patient has shared a medical report with you.';

      final Map<String, dynamic> data = {
        'type': 'report_shared',
        'reportId': reportId,
        'reportName': reportName,
        'patientId': patientId,
        'patientName': patientName,
        'doctorId': doctorId,
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      };

      final Map<String, dynamic> message = {
        'token': receiverToken,
        'data': data,
        'notification': {'title': patientName, 'body': body},
        'android': {
          'priority': 'high',
          'notification': {
            'channel_id': 'general_notifications',
            'sound': 'default',
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
          },
        },
        'apns': {
          'headers': {'apns-priority': '10'},
          'payload': {
            'aps': {
              'alert': {'title': patientName, 'body': body},
              'sound': 'default',
              'badge': 1,
              'content-available': 1,
            },
          },
        },
      };

      final response = await http.post(
        Uri.parse(
          'https://fcm.googleapis.com/v1/projects/$_projectId/messages:send',
        ),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({'message': message}),
      );

      if (response.statusCode == 200) {
        print('✅ Report notification sent successfully');
        return true;
      } else {
        print('❌ Failed to send report notification: ${response.statusCode}');
        print('Response body: ${response.body}');
        return false;
      }
    } catch (e) {
      print('❌ Error sending report notification: $e');
      return false;
    }
  }

  // Update the sendPasswordResetNotification method in FCMServiceV2
  // Update the sendPasswordResetNotification method in FCMServiceV2

  // fcm_service_v2.dart - Update sendPasswordResetNotification method

  Future<bool> sendPasswordResetNotification({
    required String fcmToken,
    required String resetToken,
    required String userId,
  }) async {
    try {
      await initialize();
      final accessToken = await _getAccessToken();

      final Map<String, dynamic> data = {
        'type': 'password_reset',
        'resetToken': resetToken,
        'userId': userId,
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      };

      final Map<String, dynamic> message = {
        'token': fcmToken,
        'data': data,
        'notification': {
          'title': 'Password Reset Request',
          'body': 'Do you want to reset your password?',
        },
        'android': {
          'priority': 'high',
          'ttl': '30s',
          'notification': {
            'channel_id': 'password_reset_notifications',
            'sound': 'default',
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            'color': '#FF0000',
          },
        },
        'apns': {
          'headers': {'apns-priority': '10'},
          'payload': {
            'aps': {
              'sound': 'default',
              'badge': 1,
              'content-available': 1,
              'category': 'password_reset_category',
            },
          },
        },
      };

      final response = await http.post(
        Uri.parse(
          'https://fcm.googleapis.com/v1/projects/$_projectId/messages:send',
        ),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({'message': message}),
      );

      if (response.statusCode == 200) {
        print(' Password reset notification sent successfully');
        return true;
      } else {
        print('Failed to send: ${response.statusCode}');
        print('Response: ${response.body}');
        return false;
      }
    } catch (e) {
      print('❌ Error sending password reset notification: $e');
      return false;
    }
  }

  Future<bool> sendPaymentProofNotification({
    required String adminToken,
    required String patientName,
    required String patientId,
    required String amount,
    String paymentId = '',
    String notificationId = '',
  }) async {
    return _sendPaymentMessage(
      token: adminToken,
      type: FcmMessageType.paymentSubmitted,
      title: patientName,
      body: 'Payment proof submitted',
      data: {
        'patientId': patientId,
        'patientName': patientName,
        'amount': amount,
        'paymentId': paymentId,
        'notificationId': notificationId,
      },
      logLabel: 'payment submitted',
    );
  }

  /// Admin → patient. Unlocks the app on the patient's device.
  Future<bool> sendPaymentApprovedNotification({
    required String patientToken,
    required String patientId,
    String paymentId = '',
    String notificationId = '',
  }) async {
    return _sendPaymentMessage(
      token: patientToken,
      type: FcmMessageType.paymentApproved,
      title: 'Payment Approved',
      body: 'Your payment has been approved. You can now access the app.',
      data: {
        'patientId': patientId,
        'paymentId': paymentId,
        'notificationId': notificationId,
      },
      logLabel: 'payment approved',
    );
  }

  /// Admin → patient. Keeps the app restricted and points them at the
  /// resubmit flow.
  Future<bool> sendPaymentRejectedNotification({
    required String patientToken,
    required String patientId,
    String paymentId = '',
    String notificationId = '',
  }) async {
    return _sendPaymentMessage(
      token: patientToken,
      type: FcmMessageType.paymentRejected,
      title: 'Payment Rejected',
      body:
          'Your payment has been rejected. '
          'Please check your payment and submit again.',
      data: {
        'patientId': patientId,
        'paymentId': paymentId,
        'notificationId': notificationId,
      },
      logLabel: 'payment rejected',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // APPOINTMENT BOOKING NOTIFICATIONS
  //
  // All five reuse [_sendPaymentMessage]: identical payload shape, identical
  // channel, identical `notificationId` dedup contract — only the type,
  // title and body differ.
  // ─────────────────────────────────────────────────────────────

  /// Patient → every admin, once an appointment payment proof is submitted.
  Future<bool> sendAppointmentPaymentSubmittedNotification({
    required String adminToken,
    required String patientName,
    required String patientId,
    required String doctorName,
    required String amount,
    String paymentId = '',
    String notificationId = '',
  }) {
    return _sendPaymentMessage(
      token: adminToken,
      type: FcmMessageType.appointmentPaymentSubmitted,
      title: 'Appointment Payment Submitted',
      body:
          '$patientName submitted payment for an appointment with '
          'Dr. $doctorName.',
      data: {
        'patientId': patientId,
        'patientName': patientName,
        'doctorName': doctorName,
        'amount': amount,
        'paymentId': paymentId,
        'notificationId': notificationId,
      },
      logLabel: 'appointment payment submitted',
    );
  }

  /// Admin → patient, which unlocks *Send Appointment Request*.
  Future<bool> sendAppointmentPaymentApprovedNotification({
    required String patientToken,
    required String patientId,
    required String doctorName,
    String paymentId = '',
    String notificationId = '',
  }) {
    return _sendPaymentMessage(
      token: patientToken,
      type: FcmMessageType.appointmentPaymentApproved,
      title: 'Payment Approved',
      body: 'Your appointment payment with Dr. $doctorName has been approved.',
      data: {
        'patientId': patientId,
        'doctorName': doctorName,
        'paymentId': paymentId,
        'notificationId': notificationId,
      },
      logLabel: 'appointment payment approved',
    );
  }

  /// Admin → patient. The patient is sent back to the payment step.
  Future<bool> sendAppointmentPaymentRejectedNotification({
    required String patientToken,
    required String patientId,
    required String doctorName,
    String paymentId = '',
    String notificationId = '',
  }) {
    return _sendPaymentMessage(
      token: patientToken,
      type: FcmMessageType.appointmentPaymentRejected,
      title: 'Payment Rejected',
      body: 'Your appointment payment with Dr. $doctorName was rejected.',
      data: {
        'patientId': patientId,
        'doctorName': doctorName,
        'paymentId': paymentId,
        'notificationId': notificationId,
      },
      logLabel: 'appointment payment rejected',
    );
  }

  /// Patient → the selected doctor only.
  Future<bool> sendNewAppointmentRequestNotification({
    required String doctorToken,
    required String doctorId,
    required String patientName,
    required String patientId,
    String appointmentId = '',
    String notificationId = '',
  }) {
    return _sendPaymentMessage(
      token: doctorToken,
      type: FcmMessageType.newAppointmentRequest,
      title: 'New Appointment Request',
      body: '$patientName sent you an appointment request.',
      data: {
        'doctorId': doctorId,
        'patientId': patientId,
        'patientName': patientName,
        'appointmentId': appointmentId,
        'notificationId': notificationId,
      },
      logLabel: 'new appointment request',
    );
  }

  /// Doctor → patient, once the date/time is confirmed.
  Future<bool> sendAppointmentConfirmedNotification({
    required String patientToken,
    required String patientId,
    required String doctorName,
    required String date,
    required String time,
    String appointmentId = '',
    String notificationId = '',
  }) {
    return _sendPaymentMessage(
      token: patientToken,
      type: FcmMessageType.appointmentConfirmed,
      title: 'Appointment Confirmed',
      body: 'Dr. $doctorName confirmed your appointment for $date at $time.',
      data: {
        'patientId': patientId,
        'doctorName': doctorName,
        'date': date,
        'time': time,
        'appointmentId': appointmentId,
        'notificationId': notificationId,
      },
      logLabel: 'appointment confirmed',
    );
  }

  /// The appointment reached its scheduled start → the recipient addressed
  /// here. The other side gets its own push with its own title/body but the
  /// same `notificationId`, so one appointment produces one alarm per device
  /// rather than two.
  ///
  /// `chatId` travels in the payload on purpose: the tap handler opens that
  /// exact conversation instead of parking the user in the Room Chat list.
  Future<bool> sendAppointmentStartNotification({
    required String token,
    required String appointmentId,
    required String patientId,
    required String patientName,
    required String patientImage,
    required String doctorId,
    required String doctorName,
    required String doctorImage,
    required String chatId,
    required bool forPatient,
    required int scheduledStartAt,
    required String notificationId,
  }) {
    final counterpartName = forPatient ? 'Dr. $doctorName' : patientName;
    return _sendPaymentMessage(
      token: token,
      type: FcmMessageType.appointmentStart,
      title: AppointmentDefaults.appointmentStartTitle,
      body: AppointmentDefaults.appointmentStartBody(counterpartName),
      data: {
        AppointmentPayloadKeys.appointmentId: appointmentId,
        AppointmentPayloadKeys.patientId: patientId,
        AppointmentPayloadKeys.patientName: patientName,
        AppointmentPayloadKeys.patientImage: patientImage,
        AppointmentPayloadKeys.doctorId: doctorId,
        AppointmentPayloadKeys.doctorName: doctorName,
        AppointmentPayloadKeys.doctorImage: doctorImage,
        AppointmentPayloadKeys.chatId: chatId,
        AppointmentPayloadKeys.scheduledStartAt: scheduledStartAt.toString(),
        AppointmentPayloadKeys.title: AppointmentDefaults.appointmentStartTitle,
        AppointmentPayloadKeys.body: AppointmentDefaults.appointmentStartBody(
          counterpartName,
        ),
        AppointmentPayloadKeys.notificationId: notificationId,
      },
      logLabel: 'appointment start',
    );
  }

  /// Every lifecycle push that is *not* the start alarm: reminder, joined,
  /// doctor-late, patient-late, grace-ending, cancelled, no-show, booking
  /// frozen.
  ///
  /// One method on purpose — the payload shape (`type`, the appointment ids,
  /// `chatId`, baked `title`/`body`, `notificationId`) is the cross-process
  /// contract with the receiver, and a single implementation is what keeps the
  /// routing table from drifting apart as types are added. [type] is a
  /// [FcmMessageType], [extra] carries the few keys that only some of them
  /// need (`offsetMinutes`, `minutes`, `noShowBy`, `warningCount`, …).
  Future<bool> sendAppointmentLifecycleNotification({
    required String token,
    required String type,
    required String appointmentId,
    required String patientId,
    required String patientName,
    required String doctorId,
    required String doctorName,
    required String chatId,
    required String title,
    required String body,
    required String notificationId,
    Map<String, String> extra = const <String, String>{},
  }) {
    return _sendPaymentMessage(
      token: token,
      type: type,
      title: title,
      body: body,
      data: {
        AppointmentPayloadKeys.appointmentId: appointmentId,
        AppointmentPayloadKeys.patientId: patientId,
        AppointmentPayloadKeys.patientName: patientName,
        AppointmentPayloadKeys.doctorId: doctorId,
        AppointmentPayloadKeys.doctorName: doctorName,
        AppointmentPayloadKeys.chatId: chatId,
        AppointmentPayloadKeys.title: title,
        AppointmentPayloadKeys.body: body,
        AppointmentPayloadKeys.notificationId: notificationId,
        ...extra,
      },
      logLabel: 'appointment lifecycle ($type)',
    );
  }

  /// Shared HTTP v1 send for the payment and appointment notifications. They
  /// differ only in [type]/[title]/[body], so one implementation keeps the
  /// payload shape (and therefore the receiver's routing table) from drifting
  /// apart.
  Future<bool> _sendPaymentMessage({
    required String token,
    required String type,
    required String title,
    required String body,
    required Map<String, String> data,
    required String logLabel,
  }) async {
    if (token.isEmpty) {
      print('⚠️ Skipping $logLabel notification: empty FCM token');
      return false;
    }

    try {
      await initialize();
      final accessToken = await _getAccessToken();

      final Map<String, dynamic> messageData = <String, dynamic>{
        'type': type,
        ...data,
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      };

      final Map<String, dynamic> message = {
        'token': token,
        'data': messageData,
        'notification': {'title': title, 'body': body},
        'android': {
          'priority': 'high',
          'ttl': '3600s',
          'notification': {
            'channel_id': 'general_notifications',
            'sound': 'default',
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
          },
        },
        'apns': {
          'headers': {'apns-priority': '10'},
          'payload': {
            'aps': {
              'alert': {'title': title, 'body': body},
              'sound': 'default',
              'badge': 1,
              'content-available': 1,
            },
          },
        },
      };

      final response = await http.post(
        Uri.parse(
          'https://fcm.googleapis.com/v1/projects/$_projectId/messages:send',
        ),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({'message': message}),
      );

      if (response.statusCode == 200) {
        print('✅ $logLabel notification sent (type=$type)');
        return true;
      }

      print('❌ Failed to send $logLabel notification: ${response.statusCode}');
      print('Response: ${response.body}');
      return false;
    } catch (e) {
      print('❌ Error sending $logLabel notification: $e');
      return false;
    }
  }

  void dispose() {
    if (_authClient != null) {
      _authClient!.close();
      _authClient = null;
    }
    _isInitialized = false;
  }
}
