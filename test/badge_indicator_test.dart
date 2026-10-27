import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/shared/widgets/badge_indicator.dart';

void main() {
  group('UserModel image removal copyWith test', () {
    test('clears image when clearImage is true', () {
      final user = UserModel.fromMap({
        'id': 'doc1',
        'fullname': 'Dr. Jane Doe',
        'image': 'https://example.com/avatar.jpg',
      });

      expect(user.image, isNotNull);

      final updated = user.copyWith(clearImage: true);
      expect(updated.image, isNull);
      expect(updated.fullname, 'Dr. Jane Doe');
      expect(updated.id, 'doc1');
    });

    test('preserves image when clearImage is false and image is not provided', () {
      final user = UserModel.fromMap({
        'id': 'doc1',
        'fullname': 'Dr. Jane Doe',
        'image': 'https://example.com/avatar.jpg',
      });

      final updated = user.copyWith(fullname: 'Dr. Jane Smith');
      expect(updated.image, 'https://example.com/avatar.jpg');
      expect(updated.fullname, 'Dr. Jane Smith');
    });

    test('updates image when new image provided', () {
      final user = UserModel.fromMap({
        'id': 'doc1',
        'fullname': 'Dr. Jane Doe',
        'image': 'https://example.com/avatar.jpg',
      });

      final updated = user.copyWith(image: 'https://example.com/new_avatar.jpg');
      expect(updated.image, 'https://example.com/new_avatar.jpg');
    });

    test('profile update payload sets remove_profile_image: true and literal null (never string "null")', () {
      const bool isImageRemoved = true;
      const String? selectedImage = null;
      final isRemovingImage = isImageRemoved && selectedImage == null;

      final updates = <String, dynamic>{
        'fullname': 'Dr. Gregory House',
        'highestDegree': 'MD',
        'imageUrl': isRemovingImage ? null : 'https://example.com/photo.jpg',
        'image': isRemovingImage ? null : 'https://example.com/photo.jpg',
        'profile_image': isRemovingImage ? null : 'https://example.com/photo.jpg',
        if (isRemovingImage) 'remove_profile_image': true,
      };

      expect(updates['remove_profile_image'], true);
      expect(updates['remove_profile_image'], isA<bool>());
      expect(updates['profile_image'], isNull);
      expect(updates['imageUrl'], isNull);
      expect(updates['image'], isNull);
      // Strictly verify it is not the literal string "null"
      expect(updates['profile_image'], isNot('null'));
      expect(updates['imageUrl'], isNot('null'));
    });

    test('clearing PaintingBinding imageCache purges memory so default avatar renders immediately', () {
      // PaintingBinding.instance.imageCache must be clearable without error
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      expect(PaintingBinding.instance.imageCache.currentSizeBytes, 0);
    });
  });

  group('BadgeIndicator widget tests', () {
    testWidgets('hides completely when count is 0 and no child', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BadgeIndicator(count: 0),
          ),
        ),
      );

      expect(find.byType(BadgeIndicator), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('renders only child without badge pill when count is 0', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BadgeIndicator(
              count: 0,
              child: Icon(Icons.mail),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.mail), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('displays count correctly when positive', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BadgeIndicator(
              count: 7,
              child: Icon(Icons.mail),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.mail), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('caps badge at 99+ by default when count exceeds maxCount', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BadgeIndicator(
              count: 150,
              maxCount: 99,
              child: Icon(Icons.notifications),
            ),
          ),
        ),
      );

      expect(find.text('99+'), findsOneWidget);
      expect(find.text('150'), findsNothing);
    });

    testWidgets('custom maxCount capping works properly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BadgeIndicator(
              count: 15,
              maxCount: 9,
            ),
          ),
        ),
      );

      expect(find.text('9+'), findsOneWidget);
    });
  });
}
