// lib/views/kitchen_circle_screen.dart
//
// "My Kitchen Circle 🔥" — friend-invite engine powered by SocialService.
//
// Two stacked sections:
//   1. Compose card — type an email, fire over a braai invite ticket
//   2. Live stream of incoming pending invites styled as braai tickets

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/friends_service.dart';
import '../services/moderation_service.dart';
import '../services/notification_service.dart';
import '../services/notifications_feed_service.dart';
import '../services/social_service.dart';
import '../theme/app_theme.dart';

class KitchenCircleScreen extends StatefulWidget {
  const KitchenCircleScreen({super.key});

  @override
  State<KitchenCircleScreen> createState() => _KitchenCircleScreenState();
}

class _KitchenCircleScreenState extends State<KitchenCircleScreen> {
  // Named _usernameController to make the intent unambiguous — this field
  // accepts a ChowSA username (@handle), never an email address.
  final _usernameController = TextEditingController();
  final _socialService      = SocialService();

  @override
  void initState() {
    super.initState();
    // Opening Kitchen Circle counts as "seen" for any invite that landed
    // here — clears the shared inbox bell so the badge doesn't linger on
    // the Home / Profile screens after the user already acknowledged
    // the invite in this list.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationsFeedService.instance.markAllReadOfType('kitchen_invite');
    });
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _sendInvite() async {
    // Sanitise per spec — strip any accidental '@' prefix the user typed or
    // pasted, then trim whitespace. SocialService.sendBraaiInvite re-
    // sanitises defensively, but doing it here keeps the snackbar copy and
    // the DB query both reading the same clean username.
    final String cleanUsername =
        _usernameController.text.replaceFirst('@', '').trim();

    if (cleanUsername.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await _socialService.sendBraaiInvite(cleanUsername);
      _usernameController.clear();
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Braai Ticket fired over successfully! 🥩')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // AppBar styling fully delegated to the global AppBarTheme (bottle green
      // bg, alabaster bold title) — no inline overrides needed.
      appBar: AppBar(
        title: const Text('My Kitchen Circle 🔥'),
      ),
      body: Column(
        children: [
          // ── 1. BRAAI INVITE TRIGGER SECTION ─────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(16.0),
            // Card styling (cream-sand + hairline border + zero shadow) comes
            // from the global CardTheme. Just provide the Card shell.
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Send a Braai Invite 🪵',
                      style: TextStyle(
                          fontSize:   18,
                          fontWeight: FontWeight.bold,
                          color:      AppTheme.kBottleGreen),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      "Enter their ChowSA username to send them a "
                      'Braai Invite Ticket.',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller:      _usernameController,
                      keyboardType:    TextInputType.text,
                      textCapitalization: TextCapitalization.none,
                      autocorrect:     false,
                      decoration: const InputDecoration(
                        // No '@' prefixIcon — users type the raw username so
                        // the controller.text never contains the symbol.
                        // The sanitiser in _sendInvite below still strips an
                        // accidental '@' as a belt-and-suspenders guard.
                        hintText: "Friend's username (e.g. Melrose)",
                        border:   OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      // "Fire Over Invite Ticket" — drops all inline color
                      // overrides so the global ElevatedButtonTheme (gold bg
                      // + midnight fg) automatically themes it as a primary
                      // CTA. This is the spec's "Login / Fire Over Invite /
                      // Save" button group that needs the gold attention hook.
                      child: ElevatedButton(
                        onPressed: _sendInvite,
                        child: const Text('Fire Over Invite Ticket'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const Divider(),

          // ── 2. ACTIVE INCOMING BRAAI INVITES + ACCEPTED FRIENDS ─────────────
          // We re-pull both lists whenever the underlying friendships table
          // emits a realtime event (insert / status flip / delete) so the
          // accept / decline / unfriend buttons feel instant.
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: Supabase.instance.client
                  .from('friendships')
                  .stream(primaryKey: ['id']),
              builder: (context, _) {
                return FutureBuilder<_KitchenCircleSnapshot>(
                  future: _loadCircle(),
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(
                          child: CircularProgressIndicator(
                              color: AppTheme.kBottleGreen));
                    }
                    final data = snap.data
                        ?? const _KitchenCircleSnapshot(
                            pending: [], friends: []);
                    return ListView(
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        if (data.pending.isNotEmpty) ...[
                          const _SectionHeader(
                            label: 'PENDING INVITES',
                            icon:  Icons.mail_outline_rounded,
                          ),
                          for (final invite in data.pending)
                            _PendingInviteCard(
                              invite:   invite,
                              onAccept: () => _accept(invite),
                              onDecline: () => _decline(invite),
                            ),
                          const SizedBox(height: 8),
                        ],
                        const _SectionHeader(
                          label: 'YOUR KITCHEN CIRCLE',
                          icon:  Icons.groups_rounded,
                        ),
                        if (data.friends.isEmpty)
                          const Padding(
                            padding:
                                EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                            child: Text(
                              'No active connections yet — fire over an invite '
                              "above and you'll see your circle here.",
                              style: TextStyle(
                                color:    AppTheme.kEarthGrey,
                                fontSize: 13,
                              ),
                            ),
                          )
                        else
                          for (final f in data.friends)
                            _FriendRow(
                              friend:   f,
                              onRemove: () => _removeFriend(f),
                              onBlock:  () => _blockFriend(f),
                            ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Data loader ────────────────────────────────────────────────────────────
  Future<_KitchenCircleSnapshot> _loadCircle() async {
    final pending = await FriendsService.instance.loadPendingIncoming();
    final friends = await FriendsService.instance.loadAcceptedFriends();
    return _KitchenCircleSnapshot(pending: pending, friends: friends);
  }

  // ── Actions (with feedback + error handling) ───────────────────────────────
  Future<void> _accept(Friendship invite) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await FriendsService.instance.acceptFriend(invite.id);
      // Also mark the matching in-app notification row read AND clear any
      // FCM notifications still pinned in the system tray + the launcher
      // badge — without this the user sees a "2 unread" badge on the app
      // icon even after accepting both halves of the invite.
      await NotificationsFeedService.instance
          .markAllReadOfType('kitchen_invite');
      await NotificationService.instance.cancelAllShadeNotifications();
      if (!mounted) return;
      setState(() {}); // re-pull on next FutureBuilder rebuild
      messenger.showSnackBar(SnackBar(
        content: Text('@${invite.other.handle} joined your kitchen circle 🥩'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not accept: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _decline(Friendship invite) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await FriendsService.instance.removeFriend(invite.id);
      // Same shade + badge cleanup as _accept — a declined invite should
      // not leave a sticky "1 unread" launcher pip behind either.
      await NotificationsFeedService.instance
          .markAllReadOfType('kitchen_invite');
      await NotificationService.instance.cancelAllShadeNotifications();
      if (!mounted) return;
      setState(() {});
      messenger.showSnackBar(const SnackBar(
        content:  Text('Invite declined.'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not decline: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _removeFriend(Friendship f) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove @${f.other.handle}?',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        content: const Text(
          "They won't be notified — but you'll need a fresh invite to "
          'reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await FriendsService.instance.removeFriend(f.id);
      if (!mounted) return;
      setState(() {});
      messenger.showSnackBar(SnackBar(
        content:  Text('Removed @${f.other.handle}.'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not remove: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  /// Blocks the other party in this friendship. Confirms first so a
  /// stray tap doesn't sever a connection, then writes a row to
  /// `user_blocks` via ModerationService. After the write, the
  /// friendship row itself is left in place — RLS + the client-side
  /// filter in FriendsService.loadAcceptedFriends hide it from the
  /// list, and unblocking from Privacy → Blocked users restores the
  /// connection instantly without a fresh invite.
  Future<void> _blockFriend(Friendship f) async {
    final messenger = ScaffoldMessenger.of(context);
    final handle    = '@${f.other.handle}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Block $handle?',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        content: const Text(
          "They won't be able to @mention you, send invites, or see "
          "your posts. You can undo this any time from Profile → "
          "Privacy → Blocked users.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ModerationService.instance.blockUser(f.other.id);
      if (!mounted) return;
      setState(() {});
      messenger.showSnackBar(SnackBar(
        content:  Text('$handle blocked.'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not block $handle: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}

// ─── Section header ─────────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.icon});
  final String   label;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppTheme.kBottleGreen),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color:         AppTheme.kBottleGreen,
              fontSize:      11,
              fontWeight:    FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Pending invite ticket ──────────────────────────────────────────────────
class _PendingInviteCard extends StatelessWidget {
  const _PendingInviteCard({
    required this.invite,
    required this.onAccept,
    required this.onDecline,
  });
  final Friendship   invite;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.kBottleGreen, AppTheme.kProteaGold],
          begin: Alignment.centerLeft,
          end:   Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.confirmation_number,
                  color: Colors.white, size: 28),
              SizedBox(width: 12),
              Text(
                'OFFICIAL BRAAI INVITE',
                style: TextStyle(
                  color:         Colors.white,
                  fontWeight:    FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '@${invite.other.handle} wants to pull up a camping chair in '
            'your kitchen circle.',
            style: const TextStyle(color: Color(0xFFEEEEEE), fontSize: 14),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: onDecline,
                child: const Text(
                  'Next time ✌️',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppTheme.kBottleGreen,
                ),
                onPressed: onAccept,
                child: const Text(
                  'Bring the Chops 🥩',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Accepted friend row ────────────────────────────────────────────────────
class _FriendRow extends StatelessWidget {
  const _FriendRow({
    required this.friend,
    required this.onRemove,
    required this.onBlock,
  });
  final Friendship   friend;
  final VoidCallback onRemove;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final avatar = friend.other.avatarUrl;

    // Avatars in profiles.avatar_url are stored as LOCAL ASSET PATHS
    // (e.g. 'assets/avatars/Melrose.png'), not network URLs — see
    // pro_avatar_picker_sheet.dart. The previous build threw those paths
    // straight into NetworkImage, which fails silently AND defeats the
    // initials fallback (because the string is non-empty), producing the
    // blank circle bug shown in 43234.jpg. Branch on the prefix so asset
    // and remote avatars BOTH resolve. Public — every viewer sees it.
    ImageProvider? avatarImage;
    if (avatar != null && avatar.isNotEmpty) {
      if (avatar.startsWith('assets/')) {
        avatarImage = AssetImage(avatar);
      } else if (avatar.startsWith('http://') || avatar.startsWith('https://')) {
        avatarImage = NetworkImage(avatar);
      }
      // Any other shape (e.g. unrecognised path) drops back to initials.
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: AppTheme.kProteaGold.withValues(alpha: 0.35),
            backgroundImage: avatarImage,
            child: avatarImage == null
                ? Text(
                    friend.other.initials,
                    style: const TextStyle(
                      color:      AppTheme.kMidnight,
                      fontWeight: FontWeight.w900,
                    ),
                  )
                : null,
          ),
          title: Text(
            '@${friend.other.handle}',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          subtitle: const Text(
            'In your kitchen circle',
            style: TextStyle(fontSize: 12),
          ),
          trailing: PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded,
                color: cs.onSurfaceVariant),
            tooltip: 'Manage friend',
            position: PopupMenuPosition.under,
            onSelected: (v) {
              if (v == 'remove') onRemove();
              if (v == 'block')  onBlock();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'remove',
                child: Row(children: [
                  Icon(Icons.person_remove_outlined,
                      size: 18, color: cs.error),
                  const SizedBox(width: 10),
                  const Text('Remove from circle'),
                ]),
              ),
              PopupMenuItem(
                value: 'block',
                child: Row(children: [
                  Icon(Icons.block_rounded,
                      size: 18, color: cs.error),
                  const SizedBox(width: 10),
                  const Text('Block user'),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KitchenCircleSnapshot {
  const _KitchenCircleSnapshot({required this.pending, required this.friends});
  final List<Friendship> pending;
  final List<Friendship> friends;
}
