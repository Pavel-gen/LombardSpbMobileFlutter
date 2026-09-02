import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Текст, в котором ссылки (http/https/www) отображаются как настоящие ссылки
/// (подчёркнуты, цвет акцента) и открываются по тапу.
///
/// Аналог formatTextWithClickableLinks() + LinkMovementMethod из Android-версии
/// (PhoneVerificationActivity.kt / MainActivity.kt), где body пуша прогонялся
/// через Patterns.WEB_URL и Html.fromHtml.
class LinkifiedText extends StatefulWidget {
  const LinkifiedText(
    this.text, {
    super.key,
    this.style,
    this.linkStyle,
    this.onOpenLink,
  });

  final String text;
  final TextStyle? style;
  final TextStyle? linkStyle;

  /// Если задан — вызывается вместо системного браузера (например, чтобы
  /// открыть ссылку в WebView текущего экрана). Иначе ссылка уходит во
  /// внешний браузер через url_launcher — как LinkMovementMethod в оригинале.
  final void Function(String url)? onOpenLink;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  // Ловит http(s)://... и www.... Хвостовая пунктуация ( . , ! ? ; : » ) )
  // в ссылку не попадает — так же ведёт себя Patterns.WEB_URL в Android.
  static final RegExp _urlRegExp = RegExp(
    r'((?:https?://|www\.)[^\s<>()\[\]«»"]+[^\s<>()\[\]«»".,!?;:])',
    caseSensitive: false,
  );

  final List<TapGestureRecognizer> _recognizers = [];
  late List<InlineSpan> _spans;

  @override
  void initState() {
    super.initState();
    _spans = _buildSpans();
  }

  @override
  void didUpdateWidget(LinkifiedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.linkStyle != widget.linkStyle ||
        oldWidget.style != widget.style) {
      _spans = _buildSpans();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _open(String rawUrl) async {
    final url = rawUrl.toLowerCase().startsWith('http') ? rawUrl : 'https://$rawUrl';
    final onOpenLink = widget.onOpenLink;
    if (onOpenLink != null) {
      onOpenLink(url);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  List<InlineSpan> _buildSpans() {
    _disposeRecognizers();

    final linkStyle = widget.linkStyle ??
        const TextStyle(
          color: Color(0xFF1565C0),
          decoration: TextDecoration.underline,
        );

    final text = widget.text;
    final spans = <InlineSpan>[];
    var index = 0;
    for (final match in _urlRegExp.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: text.substring(index, match.start)));
      }
      final url = match.group(0)!;
      final recognizer = TapGestureRecognizer()..onTap = () => _open(url);
      _recognizers.add(recognizer);
      spans.add(TextSpan(text: url, style: linkStyle, recognizer: recognizer));
      index = match.end;
    }
    if (index < text.length) {
      spans.add(TextSpan(text: text.substring(index)));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = widget.style ?? DefaultTextStyle.of(context).style;
    return Text.rich(TextSpan(style: baseStyle, children: _spans));
  }
}
