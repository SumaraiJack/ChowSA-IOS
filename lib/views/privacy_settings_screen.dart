// lib/views/privacy_settings_screen.dart
//
// POPIA Privacy & Data Settings — right-to-be-forgotten flow.
//
// Reachable from Settings → "Privacy & Data Settings". Shows a plain-language
// summary of what we store and why, then a single destructive "Erase My Data"
// button that opens a typed-confirmation bottom sheet and finally calls the
// `delete_my_account` RPC (see supabase/migrations/20260616_delete_account_rpc.sql).
//
// After successful deletion the caller's `onAccountDeleted` callback is
// invoked — that's plumbed up through SettingsScreen → MainNavigationHub's
// `_onSignOut`, which tears down the auth session, drops the in-memory
// profile, and pops the route stack so the user lands back on AuthScreen.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/moderation_service.dart';

// ── Blocked users screen ─────────────────────────────────────────────────────
// Reachable from Privacy & Data Settings → "Blocked users". Lists everyone
// the current user has blocked and lets them unblock with one tap.
// Required by Google Play's UGC policy: every social app must give users a
// way to undo a block.

class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  late Future<List<_BlockedRow>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_BlockedRow>> _load() async {
    final raw = await ModerationService.instance.listBlocked();
    if (raw.isEmpty) return const [];
    // Join to profiles so we can show handles + initials rather than UUIDs.
    final ids = raw.map((r) => r['blocked_id'] as String).toList();
    final profiles = await Supabase.instance.client
        .from('profiles')
        .select('id, handle, username')
        .inFilter('id', ids);
    final byId = {
      for (final p in (profiles as List).cast<Map<String, dynamic>>())
        p['id'] as String: p,
    };
    return raw.map((r) {
      final id = r['blocked_id'] as String;
      final p  = byId[id];
      return _BlockedRow(
        id:        id,
        handle:    (p?['handle'] as String?) ??
                   (p?['username'] as String?) ?? 'unknown',
      );
    }).toList();
  }

  Future<void> _unblock(_BlockedRow row) async {
    try {
      await ModerationService.instance.unblockUser(row.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unblocked @${row.handle}.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      setState(() => _future = _load());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not unblock: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('Blocked users'),
      ),
      body: FutureBuilder<List<_BlockedRow>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Could not load: ${snap.error}'));
          }
          final rows = snap.data ?? const [];
          if (rows.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  "You haven't blocked anyone.\n\nBlock someone from the "
                  "long-press menu on any of their messages or posts. They "
                  "won't see they've been blocked.",
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final r = rows[i];
              return Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: cs.primary,
                    child: Text(
                      r.handle.isNotEmpty ? r.handle[0].toUpperCase() : '?',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w800),
                    ),
                  ),
                  title: Text('@${r.handle}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  trailing: TextButton(
                    onPressed: () => _unblock(r),
                    child: const Text('Unblock'),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _BlockedRow {
  const _BlockedRow({required this.id, required this.handle});
  final String id;
  final String handle;
}

/// Support inbox that receives manual deletion requests. Anything sent here
/// is triaged by the ChowSA team and the matching auth row is deleted from
/// the Supabase dashboard. Change in ONE place — every entry point reads it.
const String kSupportDeletionEmail = 'chowsa.app.support@gmail.com';

class PrivacySettingsScreen extends StatelessWidget {
  const PrivacySettingsScreen({
    super.key,
    required this.onAccountDeleted,
  });

  /// Fired AFTER the RPC succeeds. Caller is expected to sign out, null
  /// the cached profile, and reset the route stack so AuthScreen wins.
  final Future<void> Function() onAccountDeleted;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('Privacy & Data Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
          // ── POPIA summary card ────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color:        cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
              border:       Border.all(color: cs.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.shield_outlined, color: cs.primary, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Your POPIA Rights',
                        style: tt.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'ChowSA stores your account profile, saved recipes, pantry '
                  'items, shopping lists, and any community posts or messages '
                  'you have authored. We use this data only to power the '
                  'features you actively use inside the app.',
                  style: tt.bodyMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  'Under section 24 of the Protection of Personal Information '
                  'Act (POPIA) you may request that we permanently erase all '
                  'personal data we hold about you. Tapping "Erase My Data" '
                  'below performs that deletion immediately and irreversibly.',
                  style: tt.bodyMedium,
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── What gets deleted ─────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color:        cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
              border:       Border.all(color: cs.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'What "Erase My Data" removes',
                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                ...const [
                  'Your login account and profile handle',
                  'Saved & generated recipes',
                  'Pantry items and shopping lists',
                  'Community posts, comments, likes, and direct messages',
                  'Braai event RSVPs and shared assets',
                ].map((line) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.check_rounded,
                              size: 16, color: cs.primary),
                          const SizedBox(width: 8),
                          Expanded(child: Text(line, style: tt.bodySmall)),
                        ],
                      ),
                    )),
              ],
            ),
          ),

          const SizedBox(height: 28),

          // ── Blocked users (Play UGC policy requires an unblock path) ──
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const BlockedUsersScreen(),
                ),
              ),
              icon: const Icon(Icons.block_rounded),
              label: const Text('Blocked users'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                textStyle: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(height: 18),

          // ── Destructive CTA ───────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openConfirmationSheet(context),
              icon: const Icon(Icons.delete_forever_rounded),
              label: const Text('Erase My Data'),
              style: FilledButton.styleFrom(
                backgroundColor: cs.error,
                foregroundColor: cs.onError,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize:   15,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'This action cannot be undone.',
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: cs.error),
          ),

          const SizedBox(height: 24),
          Divider(color: cs.outlineVariant),
          const SizedBox(height: 16),

          // ── Mailto fallback ─────────────────────────────────────────
          // Documented support-team path the Pro paywall copy references.
          // Required by the Play / App Store review checklists: every app
          // must offer a human-reachable deletion channel that doesn't
          // depend on the in-app RPC succeeding.
          Text(
            'Prefer to email us instead?',
            style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'Send our team a deletion request — we will permanently erase '
            'your account within 7 business days.',
            style: tt.bodySmall,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _confirmAndOpenMailClient(context),
              icon:  const Icon(Icons.mail_outline_rounded),
              label: const Text('Email a Deletion Request'),
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.primary,
                side: BorderSide(color: cs.primary, width: 1.2),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Native AlertDialog → url_launcher mailto. Pre-fills the support
  /// address, the subject "ChowSA Account Deletion Request", and the
  /// caller's live Supabase auth UID so the team can locate the row.
  Future<void> _confirmAndOpenMailClient(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   const Text('Email a deletion request?'),
        content: const Text(
          'This will open your email app with a pre-filled message to the '
          'ChowSA support team. Your account will be permanently erased '
          'once we process the request — this cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Open Email'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    // Live UID so the support team can target the exact row in the
    // Supabase dashboard. Falls back to a placeholder if the session
    // somehow expired between landing on this screen and tapping send.
    final uid = Supabase.instance.client.auth.currentUser?.id
        ?? '(not signed in)';

    final uri = Uri(
      scheme: 'mailto',
      path:   kSupportDeletionEmail,
      query:  _encodeMailtoQuery({
        'subject': 'ChowSA Account Deletion Request',
        'body':    'Please permanently erase my account and data.\n\n'
                   'My User ID is: $uid\n',
      }),
    );

    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No email app available — please email '
            '$kSupportDeletionEmail manually.',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// `Uri(query: ...)` encodes the `=` between key and value, which breaks
  /// mailto on iOS. Build the query string by hand so subject/body land in
  /// the email app's UI rather than the URL bar.
  String _encodeMailtoQuery(Map<String, String> params) =>
      params.entries
          .map((e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
          .join('&');

  void _openConfirmationSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => _EraseConfirmationSheet(
        onConfirmed: onAccountDeleted,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// _EraseConfirmationSheet — typed-confirmation safety gate
// ═══════════════════════════════════════════════════════════════════════════
//
// The destructive button stays disabled until the user types DELETE exactly.
// On submit we call the `delete_my_account` RPC; on success we fire
// `onConfirmed` so the parent can sign-out and reset the navigator.

class _EraseConfirmationSheet extends StatefulWidget {
  const _EraseConfirmationSheet({required this.onConfirmed});

  final Future<void> Function() onConfirmed;

  @override
  State<_EraseConfirmationSheet> createState() =>
      _EraseConfirmationSheetState();
}

class _EraseConfirmationSheetState extends State<_EraseConfirmationSheet> {
  final _controller = TextEditingController();
  bool  _unlocked   = false;
  bool  _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final next = _controller.text.trim() == 'DELETE';
      if (next != _unlocked) setState(() => _unlocked = next);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_unlocked || _submitting) return;
    setState(() {
      _submitting = true;
      _error      = null;
    });

    try {
      // Server-side cascade — see migration 20260616.
      await Supabase.instance.client.rpc('delete_my_account');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error      = 'Could not erase account: $e';
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(); // close the sheet first
    await widget.onConfirmed();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final viewInsets = MediaQuery.of(context).viewInsets;

    return Padding(
      // Lift the sheet above the soft keyboard when the user is typing
      // DELETE so the action row isn't covered.
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width:  40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color:        cs.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),

            Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    color: cs.error, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Permanently erase account?',
                    style: tt.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color:      cs.error,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            Text(
              'Are you absolutely sure you want to permanently delete your '
              'ChowSA account and all associated pantry, recipe, and list '
              'data? This action cannot be undone and fully satisfies your '
              'POPIA right to be forgotten.',
              style: tt.bodyMedium?.copyWith(height: 1.45),
            ),
            const SizedBox(height: 18),

            Text(
              'Type DELETE to confirm:',
              style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              autofocus:  true,
              textCapitalization: TextCapitalization.characters,
              enabled:    !_submitting,
              decoration: InputDecoration(
                hintText: 'DELETE',
                isDense:  true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:   BorderSide(color: cs.error, width: 1.5),
                ),
              ),
              style: const TextStyle(
                fontWeight:    FontWeight.w800,
                letterSpacing: 2,
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: tt.bodySmall?.copyWith(color: cs.error)),
            ],

            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: (_unlocked && !_submitting) ? _submit : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.error,
                      foregroundColor: cs.onError,
                      disabledBackgroundColor:
                          cs.error.withAlpha(70),
                      padding:
                          const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(Colors.white),
                            ),
                          )
                        : const Text(
                            'Erase Forever',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
