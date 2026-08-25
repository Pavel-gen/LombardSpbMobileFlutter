import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/analytics_service.dart';

/// Калькулятор займа — прямой перенос CalculatorActivity.kt.
/// Цены/надбавки и формула расчёта не менялись, только UI на Material-виджетах.
class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key});

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  static const goldPricesRub = {
    375: 4205, 500: 5605, 585: 6660, 750: 8220,
    875: 9690, 900: 10245, 916: 10430, 958: 10905,
  };
  static const silverPricesRub = {
    800: 80, 830: 80, 875: 80, 916: 80, 925: 80, 960: 80, 999: 80,
  };

  static const goldNewBonusRub = 5;
  static const silverNewBonusRub = 20;
  static const nonCashGoldSurchargeRub = 100;

  String _material = 'gold'; // gold / silver
  int? _hallmark;
  String _condition = 'new'; // new / average / scrap
  String _payment = 'cash'; // cash / non-cash

  final _weightController = TextEditingController();
  double _sum = 0;

  List<int> get _currentHallmarks =>
      (_material == 'gold' ? goldPricesRub.keys : silverPricesRub.keys)
          .toList();

  @override
  void initState() {
    super.initState();
    AnalyticsService.reportScreen('Calculator');
    _hallmark = _currentHallmarks.first;
    _weightController.addListener(_recalculate);
  }

  @override
  void dispose() {
    _weightController.dispose();
    super.dispose();
  }

  void _recalculate() {
    final hallmark = _hallmark;
    final weight = double.tryParse(_weightController.text.replaceAll(',', '.'));

    final baseRub = hallmark == null
        ? null
        : (_material == 'gold' ? goldPricesRub[hallmark] : silverPricesRub[hallmark]);

    if (baseRub == null || weight == null || weight <= 0) {
      setState(() => _sum = 0);
      return;
    }

    final conditionBonusRub = _condition == 'new'
        ? (_material == 'gold' ? goldNewBonusRub : silverNewBonusRub)
        : 0;

    final paymentSurchargeRub =
        (_material == 'gold' && _payment == 'non-cash') ? nonCashGoldSurchargeRub : 0;

    final perGramRub = baseRub + conditionBonusRub + paymentSurchargeRub;
    setState(() => _sum = perGramRub * weight);
  }

  String _formatRub(double value) {
    final rounded = (value * 100).round() / 100.0;
    final parts = rounded.toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final fracPart = parts[1];

    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(intPart[i]);
    }
    return '$buffer.$fracPart ₽';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Калькулятор займа')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionLabel('Металл:'),
              _materialSelector(),
              _sectionLabel('Проба:'),
              _hallmarkSelector(),
              _sectionLabel('Состояние:'),
              _conditionSelector(),
              _sectionLabel('Способ оплаты:'),
              _paymentSelector(),
              _sectionLabel('Вес изделия, гр:'),
              TextField(
                controller: _weightController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: const InputDecoration(
                  hintText: 'Например, 3.5',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _formatRub(_sum),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
              ),
              const Text(
                '*Окончательная стоимость определяется после осмотра изделия '
                'специалистом. Указанная сумма является предварительной оценкой.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 2),
    child: Text(text, style: const TextStyle(fontSize: 14)),
  );

  Widget _materialSelector() {
    return Row(
      children: [
        Expanded(
          child: RadioListTile<String>(
            title: const Text('Золото'),
            value: 'gold',
            groupValue: _material,
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            onChanged: (v) {
              setState(() {
                _material = v!;
                _hallmark = _currentHallmarks.first;
              });
              _recalculate();
            },
          ),
        ),
        Expanded(
          child: RadioListTile<String>(
            title: const Text('Серебро'),
            value: 'silver',
            groupValue: _material,
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            onChanged: (v) {
              setState(() {
                _material = v!;
                _hallmark = _currentHallmarks.first;
              });
              _recalculate();
            },
          ),
        ),
      ],
    );
  }

  Widget _hallmarkSelector() {
    return DropdownButtonFormField<int>(
      initialValue: _hallmark,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      items: _currentHallmarks
          .map((h) => DropdownMenuItem(value: h, child: Text(h.toString())))
          .toList(),
      onChanged: (v) {
        setState(() => _hallmark = v);
        _recalculate();
      },
    );
  }

  // Радио сверху, подпись снизу — при трёх вариантах в ряд горизонтальный
  // RadioListTile "Среднее" не помещается в треть ширины и переносится
  // на 2 строки, а так подпись получает всю ширину колонки и не рвётся.
  Widget _conditionSelector() {
    return Row(
      children: [
        Expanded(child: _conditionOption('Новое', 'new')),
        Expanded(child: _conditionOption('Среднее', 'average')),
        Expanded(child: _conditionOption('Плохое', 'scrap')),
      ],
    );
  }

  Widget _conditionOption(String label, String value) {
    return InkWell(
      onTap: () {
        setState(() => _condition = value);
        _recalculate();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Radio<String>(
            value: value,
            groupValue: _condition,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) {
              setState(() => _condition = v!);
              _recalculate();
            },
          ),
          Text(label, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _paymentSelector() {
    return Row(
      children: [
        Expanded(
          child: RadioListTile<String>(
            title: const Text('Наличные'),
            value: 'cash',
            groupValue: _payment,
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            onChanged: (v) {
              setState(() => _payment = v!);
              _recalculate();
            },
          ),
        ),
        Expanded(
          child: RadioListTile<String>(
            title: const Text('Безнал'),
            value: 'non-cash',
            groupValue: _payment,
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            onChanged: (v) {
              setState(() => _payment = v!);
              _recalculate();
            },
          ),
        ),
      ],
    );
  }
}
