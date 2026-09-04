import 'package:flutter/services.dart';

/// Приводит сохранённый номер к виду `+7 (999) 123-45-67` для показа.
/// Принимает `+79991234567`, `79991234567`, `89991234567`, `9991234567`.
/// Если цифр не хватает на полный номер — возвращает исходную строку как есть
/// (например, серверную маску `+7•••95`).
String formatRuPhone(String raw) {
  var digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('8')) {
    digits = '7${digits.substring(1)}';
  } else if (!digits.startsWith('7')) {
    digits = '7$digits';
  }
  if (digits.length < 11) return raw;
  final r = digits.substring(1, 11);
  return '+7 (${r.substring(0, 3)}) ${r.substring(3, 6)}-${r.substring(6, 8)}-${r.substring(8, 10)}';
}

/// Маска ввода номера: +7 (999) 123-45-67. Аналог PhoneMaskWatcher.kt.
///
/// Курсор ведётся по КОЛИЧЕСТВУ ЦИФР слева от него, а не по позиции символа —
/// поэтому он не «прыгает» при автоподстановке скобок/дефисов, при нормализации
/// 8→7 и при добавлении кода страны. Вводить можно как угодно: `9`, `89`, `+7 9`,
/// вставкой из буфера — на выходе всегда `+7 (...)...`.
class PhoneMaskFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text;
    final selEnd = newValue.selection.end.clamp(0, raw.length);

    // сколько цифр пользователь оставил слева от курсора
    var digitsLeft = _countDigits(raw.substring(0, selEnd));

    var digits = raw.replaceAll(_nonDigit, '');
    if (digits.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }

    // нормализация кода страны
    if (digits == '8') {
      digits = '7';
    } else if (digits.startsWith('8')) {
      digits = '7${digits.substring(1)}';
    } else if (!digits.startsWith('7')) {
      digits = '7$digits';
      if (digitsLeft > 0) digitsLeft++; // добавили цифру слева — сдвигаем курсор
    }
    if (digits.length > 11) digits = digits.substring(0, 11);
    if (digitsLeft > digits.length) digitsLeft = digits.length;

    final formatted = _format(digits);

    // курсор — после digitsLeft-й цифры в готовой строке
    int offset = formatted.length;
    if (digitsLeft > 0) {
      var seen = 0;
      for (var i = 0; i < formatted.length; i++) {
        if (_isDigit(formatted.codeUnitAt(i))) {
          if (++seen == digitsLeft) {
            offset = i + 1;
            break;
          }
        }
      }
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: offset.clamp(0, formatted.length)),
    );
  }

  static final RegExp _nonDigit = RegExp(r'\D');

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static int _countDigits(String s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      if (_isDigit(s.codeUnitAt(i))) n++;
    }
    return n;
  }

  static int _min(int a, int b) => a < b ? a : b;

  /// digits: начинается с '7', длина 1..11.
  String _format(String digits) {
    final buf = StringBuffer('+7');
    final rest = digits.substring(1); // до 10 цифр после кода страны
    if (rest.isEmpty) return buf.toString();

    buf.write(' (');
    buf.write(rest.substring(0, _min(rest.length, 3))); // код оператора
    if (rest.length <= 3) return buf.toString();

    buf.write(') ');
    buf.write(rest.substring(3, _min(rest.length, 6)));
    if (rest.length <= 6) return buf.toString();

    buf.write('-');
    buf.write(rest.substring(6, _min(rest.length, 8)));
    if (rest.length <= 8) return buf.toString();

    buf.write('-');
    buf.write(rest.substring(8, _min(rest.length, 10)));
    return buf.toString();
  }
}
