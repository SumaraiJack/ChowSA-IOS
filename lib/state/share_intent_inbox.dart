// lib/state/share_intent_inbox.dart
//
// Single source of truth for "the user just shared a URL into ChowSA".
//
// Wired up in main() after Supabase.initialize:
//   • cold-start: ReceiveSharingIntent.getInitialMedia() resolves the URL
//     that launched the app via Share.
//   • running:    a Stream subscription forwards live shares while the
//     app is in the background.
//
// The ScraperScreen (Chow Home) binds to [pendingSharedUrl]. When it
// flips non-null it lifts the URL into its URL controller and fires the
// existing _submit() flow — same as a paste-and-scan, no new UI path.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

class ShareIntentInbox {
  ShareIntentInbox._();
  static final ShareIntentInbox instance = ShareIntentInbox._();

  /// Last URL the OS share sheet handed to ChowSA. Consumers MUST call
  /// [consume] once they've kicked off the scrape so the same URL doesn't
  /// re-fire across rebuilds.
  final ValueNotifier<String?> pendingSharedUrl = ValueNotifier<String?>(null);

  StreamSubscription<List<SharedMediaFile>>? _sub;
  bool _booted = false;

  /// Boot the receivers. Idempotent — safe to call from main() once.
  Future<void> boot() async {
    if (_booted) return;
    _booted = true;
    try {
      // Cold-start: app was launched by the share sheet.
      final initial =
          await ReceiveSharingIntent.instance.getInitialMedia();
      final initialUrl = _firstUrl(initial);
      if (initialUrl != null) pendingSharedUrl.value = initialUrl;
      // Important — flushes the in-process queue so a subsequent fresh
      // share isn't masked by the cached initial payload.
      ReceiveSharingIntent.instance.reset();

      // Live: app already running when a share comes in.
      _sub = ReceiveSharingIntent.instance.getMediaStream().listen(
        (files) {
          final url = _firstUrl(files);
          if (url != null) pendingSharedUrl.value = url;
        },
        onError: (_) {/* best-effort */},
      );
    } catch (_) {
      // Share intent setup is best-effort — never block app boot on it.
    }
  }

  /// Called by the scraper screen once it's started processing the URL,
  /// so the notifier doesn't keep re-firing on every rebuild.
  void consume() {
    pendingSharedUrl.value = null;
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    pendingSharedUrl.dispose();
  }

  /// Pull the first URL-looking string out of a SharedMediaFile list.
  /// receive_sharing_intent v1.8.x packs shared text into the `path`
  /// field with `type == SharedMediaType.text` or `text/plain`.
  String? _firstUrl(List<SharedMediaFile> files) {
    for (final f in files) {
      final raw = f.path.trim();
      if (raw.isEmpty) continue;
      // The share sheet sometimes sends "title\nhttps://..." — pluck the
      // first https-looking token rather than insisting on a clean URL.
      final match = RegExp(r'https?://\S+').firstMatch(raw);
      if (match != null) return match.group(0);
      if (raw.startsWith('http')) return raw;
    }
    return null;
  }
}
