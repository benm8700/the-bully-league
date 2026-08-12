import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/config/turnstile_config.dart';

/// Renders Cloudflare Turnstile via a WebView loading a small self-authored
/// HTML page (assets/turnstile.html) - deliberately not using a third-party
/// wrapper package, since the ones on pub.dev for this kind of thing are
/// thin, low-adoption, single-version packages (real risk of the same kind
/// of toolchain surprise agora_rtc_engine caused - see CLAUDE.md's Agora
/// toolchain notes). webview_flutter is the official, well-maintained
/// Flutter team package.
///
/// Switched from Google reCAPTCHA v2 after live testing showed its image-grid
/// challenges are high-friction for real users (see CLAUDE.md's CAPTCHA
/// notes) - Turnstile's "Managed" mode is usually a single click or fully
/// invisible.
///
/// The token this produces is verified server-side in the castVote Cloud
/// Function (functions/index.js) - the secret key never touches the client.
class TurnstileChallenge extends StatefulWidget {
  const TurnstileChallenge({super.key, required this.onToken});

  final ValueChanged<String?> onToken;

  @override
  State<TurnstileChallenge> createState() => _TurnstileChallengeState();
}

class _TurnstileChallengeState extends State<TurnstileChallenge> {
  late final WebViewController _controller;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'TurnstileChannel',
        onMessageReceived: (message) {
          widget.onToken(message.message.isEmpty ? null : message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(onPageFinished: (_) => setState(() => _loaded = true)),
      );
    _loadHtml();
  }

  Future<void> _loadHtml() async {
    final raw = await DefaultAssetBundle.of(context).loadString('assets/turnstile.html');
    final html = raw.replaceAll('__TURNSTILE_SITE_KEY__', turnstileSiteKey);
    // baseUrl must match a domain registered for the Turnstile site key
    // (see agora_config.dart-style setup notes) - without it the WebView's
    // origin doesn't match anything Turnstile allows.
    await _controller.loadHtmlString(html, baseUrl: 'https://localhost');
  }

  @override
  Widget build(BuildContext context) {
    // Turnstile's "Managed" mode is usually just a checkbox (much more
    // compact than reCAPTCHA's image grids), but can occasionally show a
    // small interactive challenge - 300px comfortably fits either.
    return SizedBox(
      height: 300,
      child: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (!_loaded) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
