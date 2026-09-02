// Маска ввода телефона. Требует Flutter (TextEditingValue) — `flutter test`.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lombardspb/utils/phone_mask_formatter.dart';

TextEditingValue _v(String t, [int? sel]) => TextEditingValue(
      text: t,
      selection: TextSelection.collapsed(offset: sel ?? t.length),
    );

void main() {
  final f = PhoneMaskFormatter();
  // применить форматтер: было oldT -> ввели newT
  String out(String oldT, String newT, [int? sel]) =>
      f.formatEditUpdate(_v(oldT), _v(newT, sel)).text;

  test('первая цифра 9 → "+7 (9"', () {
    expect(out('', '9'), '+7 (9');
  });

  test('одиночная 8 в начале → "+7"', () {
    expect(out('', '8'), '+7');
  });

  test('8 + номер нормализуется в +7', () {
    expect(out('', '89991234567'), '+7 (999) 123-45-67');
  });

  test('вставка 11 цифр с 7', () {
    expect(out('', '79991234567'), '+7 (999) 123-45-67');
  });

  test('вставка 10 цифр без кода страны', () {
    expect(out('', '9991234567'), '+7 (999) 123-45-67');
  });

  test('дозапись последней цифры', () {
    expect(out('+7 (999) 123-45-6', '+7 (999) 123-45-67'), '+7 (999) 123-45-67');
  });

  test('промежуточные длины форматируются корректно', () {
    expect(out('', '7999'), '+7 (999');
    expect(out('', '7999123'), '+7 (999) 123');
    expect(out('', '799912345'), '+7 (999) 123-45');
  });

  test('лишние цифры сверх 11 отсекаются', () {
    expect(out('', '7999123456700000'), '+7 (999) 123-45-67');
  });

  test('полная очистка поля', () {
    expect(out('+7 (999) 1', ''), '');
  });

  test('курсор не улетает: после первой цифры стоит в конце "+7 (9"', () {
    final r = f.formatEditUpdate(_v(''), _v('9'));
    expect(r.text, '+7 (9');
    expect(r.selection.end, r.text.length);
  });

  test('идемпотентность: повторное применение к готовой строке не портит её', () {
    const done = '+7 (999) 123-45-67';
    expect(out(done, done), done);
  });
}
