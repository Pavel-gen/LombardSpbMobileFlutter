import 'package:flutter/services.dart';

/// Маска ввода номера телефона +7 (999) 123-45-67 — аналог PhoneMaskWatcher.kt.
class PhoneMaskFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digitsBeforeCursor = newValue.text
        .substring(0, newValue.selection.end.clamp(0, newValue.text.length))
        .replaceAll(RegExp(r'\D'), '')
        .length;

    var digits = newValue.text.replaceAll(RegExp(r'\D'), '');

    if (digits == '8') {
      digits = '7';
    } else if (digits.startsWith('8') && digits.length > 1) {
      digits = '7${digits.substring(1)}';
    } else if (!digits.startsWith('7') && digits.isNotEmpty) {
      digits = '7$digits';
    }
    if (digits.length > 11) digits = digits.substring(0, 11);

    final formatted = _formatPhone(digits);

    int cursor = 0;
    int seen = 0;
    for (int i = 0; i < formatted.length; i++) {
      if (RegExp(r'\d').hasMatch(formatted[i])) {
        seen++;
        if (seen == digitsBeforeCursor) {
          cursor = i + 1;
          break;
        }
      }
      cursor = formatted.length;
    }
    if (digitsBeforeCursor == 0) cursor = 0;

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: cursor.clamp(0, formatted.length)),
    );
  }

  String _formatPhone(String digits) {
    if (digits.isEmpty) return '';
    final sb = StringBuffer('+7');
    if (digits.length <= 1) return sb.toString();

    sb.write(' (');
    final areaCodeEnd = (1 + 3).clamp(0, digits.length);
    sb.write(digits.substring(1, areaCodeEnd));

    if (digits.length > 4) {
      sb.write(') ');
      final part1End = (areaCodeEnd + 3).clamp(0, digits.length);
      sb.write(digits.substring(areaCodeEnd, part1End));
      if (digits.length > 7) sb.write('-');

      if (digits.length > 7) {
        final part2End = (7 + 2).clamp(0, digits.length);
        sb.write(digits.substring(7, part2End));
        if (digits.length > 9) sb.write('-');
      }

      if (digits.length > 9) {
        final part3End = (9 + 2).clamp(0, digits.length);
        sb.write(digits.substring(9, part3End));
      }
    }

    return sb.toString();
  }
}
