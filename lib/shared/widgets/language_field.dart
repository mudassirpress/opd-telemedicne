import 'package:flutter/material.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/responsive.dart';

/// Multi-select language picker used on the doctor's profile edit screens.
///
/// Renders [DoctorLanguages.options] as toggle chips. Every option stays
/// visible — no search box, no "show more" — because the list is short enough
/// to read at a glance and a hidden option is a language a doctor never adds.
///
/// Unknown values already held by the doctor (a language that predates
/// [DoctorLanguages.options], or was added to Firestore by another client) are
/// shown as selected extras rather than being dropped on the next save, so
/// opening and saving the form is lossless.
class DoctorLanguageSelector extends StatelessWidget {
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  final String? label;
  final String? helperText;

  const DoctorLanguageSelector({
    super.key,
    required this.selected,
    required this.onChanged,
    this.label,
    this.helperText,
  });

  /// Values in [selected] that [DoctorLanguages.options] no longer offers.
  List<String> get _unknownSelected {
    final known = DoctorLanguages.options
        .map((e) => e.toLowerCase())
        .toSet();
    return selected
        .where((value) => !known.contains(value.toLowerCase()))
        .toList(growable: false);
  }

  void _toggle(String language) {
    final isSelected = selected.any(
      (value) => value.toLowerCase() == language.toLowerCase(),
    );
    final next = List<String>.of(selected);
    if (isSelected) {
      next.removeWhere(
        (value) => value.toLowerCase() == language.toLowerCase(),
      );
    } else {
      next.add(language);
    }
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final options = <String>[
      ...DoctorLanguages.options,
      ..._unknownSelected,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(
            label!,
            style: TextStyle(
              fontSize: context.fs(12.5),
              fontWeight: FontWeight.w600,
              color: const Color(0xFF1F2F44),
            ),
          ),
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final language in options)
              _LanguageChip(
                label: language,
                isSelected: selected.any(
                  (value) => value.toLowerCase() == language.toLowerCase(),
                ),
                onTap: () => _toggle(language),
              ),
          ],
        ),
        if (helperText != null) ...[
          const SizedBox(height: 10),
          Text(
            helperText!,
            style: TextStyle(
              fontSize: context.fs(12),
              color: const Color(0xFF7E90A6),
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }
}

class _LanguageChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _LanguageChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF062B72) : Colors.white,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF062B72)
                  : const Color(0xFFDCE6F2),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSelected) ...[
                const Icon(
                  Icons.check_rounded,
                  size: 14,
                  color: Colors.white,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(13),
                  fontWeight: FontWeight.w500,
                  color: isSelected
                      ? Colors.white
                      : const Color(0xFF1F2F44),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Read-only rendering of a doctor's languages.
///
/// Deliberately shows *something* for the empty case rather than hiding the
/// section entirely: a patient looking at a doctor card needs to know the
/// answer is "not declared" and not "not loaded".
class DoctorLanguagesView extends StatelessWidget {
  final List<String> languages;
  final String emptyMessage;

  const DoctorLanguagesView({
    super.key,
    required this.languages,
    this.emptyMessage = 'No languages added yet',
  });

  @override
  Widget build(BuildContext context) {
    if (languages.isEmpty) {
      return Row(
        children: [
          const Icon(
            Icons.translate_rounded,
            size: 16,
            color: Color(0xFF7E90A6),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              emptyMessage,
              style: TextStyle(
                fontSize: context.fs(13.5),
                fontWeight: FontWeight.w500,
                color: const Color(0xFF7E90A6),
              ),
            ),
          ),
        ],
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final language in languages)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFFF0F4FA),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: const Color(0xFFDCE6F2)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.translate_rounded,
                  size: 13,
                  color: Color(0xFF163B6E),
                ),
                const SizedBox(width: 6),
                Text(
                  language,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(12.5),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF163B6E),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
