// lib/views/braai_planner_screen.dart
//
// "Bring & Braai" Planner — interactive event organiser.
//
// Architecture overview
// ─────────────────────
// • Pure StatefulWidget + setState — no Bloc/Riverpod needed; Supabase
//   Realtime handles the multi-device sync.
// • Three logical layers:
//     1. BraaiPlannerScreen   — event list + "New Event" FAB
//     2. _BraaiEventDetail    — RSVP panel + live item checklist
//     3. _NewEventSheet       — bottom sheet for creating an event
//
// State update guarantee
// ───────────────────────
// When the current user claims or edits a braai item the local List<_BraaiItem>
// is mutated immediately in setState() BEFORE the upsert hits Supabase, so the
// UI feels instant. The Realtime subscription then reconciles any concurrent
// edits from other devices.
//
// Supabase tables (created by 20260531_braai_events.sql):
//   braai_events  (id, creator_id, title, location, date_time)
//   braai_items   (id, event_id, item_name, target_quantity,
//                  brought_by_user_id, brought_by_handle, exact_contribution)
//   braai_rsvps   (id, event_id, user_id, status)
//   notifications (id, recipient_id, sender_id, type, payload, is_read)

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Design tokens ─────────────────────────────────────────────────────────────
const _kForest  = Color(0xFF0C351E);
const _kOrange  = Color(0xFFE59B27);
const _kCream   = Color(0xFFF4F1EA);
const _kAmber   = Color(0xFFFF8F00);
const _kMuted   = Color(0xFF55534E);
const _kDivider = Color(0xFFE6E2D8);

// =============================================================================
// Models
// =============================================================================

class _BraaiEvent {
  final String    id;
  final String    creatorId;
  final String    title;
  final String?   location;
  final DateTime  dateTime;

  const _BraaiEvent({
    required this.id,
    required this.creatorId,
    required this.title,
    this.location,
    required this.dateTime,
  });

  factory _BraaiEvent.fromRow(Map<String, dynamic> r) => _BraaiEvent(
        id:        r['id']        as String,
        creatorId: r['creator_id'] as String,
        title:     r['title']     as String,
        location:  r['location']  as String?,
        dateTime:  DateTime.parse(r['date_time'] as String).toLocal(),
      );
}

class _BraaiItem {
  final String  id;
  final String  eventId;
        String  itemName;
        String? targetQuantity;
        String? broughtByUserId;
        String? broughtByHandle;
        String? exactContribution;

  _BraaiItem({
    required this.id,
    required this.eventId,
    required this.itemName,
    this.targetQuantity,
    this.broughtByUserId,
    this.broughtByHandle,
    this.exactContribution,
  });

  factory _BraaiItem.fromRow(Map<String, dynamic> r) => _BraaiItem(
        id:                r['id']                  as String,
        eventId:           r['event_id']             as String,
        itemName:          r['item_name']             as String,
        targetQuantity:    r['target_quantity']       as String?,
        broughtByUserId:   r['brought_by_user_id']   as String?,
        broughtByHandle:   r['brought_by_handle']    as String?,
        exactContribution: r['exact_contribution']   as String?,
      );

  bool get isClaimed => broughtByUserId != null;
}

// =============================================================================
// BraaiPlannerScreen — event list
// =============================================================================

class BraaiPlannerScreen extends StatefulWidget {
  const BraaiPlannerScreen({super.key});

  @override
  State<BraaiPlannerScreen> createState() => _BraaiPlannerScreenState();
}

class _BraaiPlannerScreenState extends State<BraaiPlannerScreen> {
  final _db       = Supabase.instance.client;
  String? get _uid => _db.auth.currentUser?.id;

  List<_BraaiEvent> _events  = [];
  bool              _loading = true;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  // ── Data ────────────────────────────────────────────────────────────────────

  Future<void> _loadEvents() async {
    if (_uid == null) { setState(() => _loading = false); return; }
    try {
      // Fetch events created by user OR where they have an RSVP
      final created = await _db
          .from('braai_events')
          .select()
          .eq('creator_id', _uid!)
          .order('date_time', ascending: true);

      final rsvpRows = await _db
          .from('braai_rsvps')
          .select('event_id')
          .eq('user_id', _uid!);

      final rsvpEventIds = (rsvpRows as List)
          .map((r) => r['event_id'] as String)
          .toList();

      List<dynamic> invited = [];
      if (rsvpEventIds.isNotEmpty) {
        invited = await _db
            .from('braai_events')
            .select()
            .inFilter('id', rsvpEventIds)
            .order('date_time', ascending: true);
      }

      // Merge + deduplicate by id
      final seen   = <String>{};
      final merged = <_BraaiEvent>[];
      for (final row in [...created, ...invited]) {
        final event = _BraaiEvent.fromRow(row as Map<String, dynamic>);
        if (seen.add(event.id)) merged.add(event);
      }

      // Sort by date_time ascending
      merged.sort((a, b) => a.dateTime.compareTo(b.dateTime));

      if (mounted) setState(() { _events = merged; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kCream,
      appBar: AppBar(
        backgroundColor: _kCream,
        elevation:       0,
        centerTitle:     false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Bring & Braai',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize:   20,
                color:      _kForest,
              ),
            ),
            Text(
              'Organise your next braai',
              style: TextStyle(
                fontSize: 12,
                color:    _kMuted,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon:    const Icon(Icons.refresh_rounded, color: _kForest),
            tooltip: 'Refresh',
            onPressed: () {
              setState(() => _loading = true);
              _loadEvents();
            },
          ),
        ],
      ),

      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _kForest))
          : _events.isEmpty
              ? _EmptyEventsHint(onCreateTap: _openNewEventSheet)
              : RefreshIndicator(
                  color:    _kForest,
                  onRefresh: _loadEvents,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                    itemCount:       _events.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (ctx, i) => _EventCard(
                      event:     _events[i],
                      currentUid: _uid,
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => _BraaiEventDetail(
                              event: _events[i],
                            ),
                          ),
                        );
                        _loadEvents(); // refresh on return
                      },
                    ),
                  ),
                ),

      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _kOrange,
        icon:  const Icon(Icons.local_fire_department_rounded),
        label: const Text(
          'New Braai',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        onPressed: _openNewEventSheet,
      ),
    );
  }

  Future<void> _openNewEventSheet() async {
    final created = await showModalBottomSheet<_BraaiEvent>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => _NewEventSheet(creatorId: _uid ?? ''),
    );
    if (created != null && mounted) {
      setState(() => _events.insert(0, created));
      // Open the new event immediately
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => _BraaiEventDetail(event: created),
          ),
        );
        _loadEvents();
      }
    }
  }
}

// =============================================================================
// _EventCard
// =============================================================================

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.currentUid,
    required this.onTap,
  });

  final _BraaiEvent event;
  final String?     currentUid;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isOwner = event.creatorId == currentUid;
    final dt      = event.dateTime;
    final dateStr = '${_weekday(dt.weekday)} ${dt.day} ${_month(dt.month)} '
        '${dt.year}  •  ${_pad(dt.hour)}:${_pad(dt.minute)}';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(20),
          border:       Border.all(color: _kDivider),
          boxShadow: const [
            BoxShadow(
              color:      Color(0x0E000000),
              blurRadius: 8,
              offset:     Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Flame icon container
            Container(
              width:  52,
              height: 52,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFBF360C), _kOrange],
                  begin: Alignment.topLeft,
                  end:   Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.local_fire_department_rounded,
                color: Colors.white,
                size:  26,
              ),
            ),
            const SizedBox(width: 14),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize:   15,
                      color:      _kForest,
                    ),
                  ),
                  const SizedBox(height: 3),
                  if (event.location != null)
                    Text(
                      '📍 ${event.location}',
                      style: const TextStyle(
                        fontSize:   12,
                        color:      _kMuted,
                      ),
                    ),
                  const SizedBox(height: 3),
                  Text(
                    dateStr,
                    style: const TextStyle(fontSize: 12, color: _kMuted),
                  ),
                ],
              ),
            ),

            // Owner badge / chevron
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (isOwner)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color:        _kForest,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'HOST',
                      style: TextStyle(
                        fontSize:      9,
                        fontWeight:    FontWeight.w900,
                        color:         Colors.white,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                const Icon(Icons.chevron_right_rounded, color: _kMuted),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

// Date helpers re-used by _EventMetaCard and the host state above. Lifted
// to top-level functions so _EventMetaCard can call them without poking
// at the private state class's static members.
String _weekday(int w) =>
    const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][w - 1];

String _month(int m) => const [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ][m - 1];

// =============================================================================
// _BraaiEventDetail — RSVP panel + live item checklist
// =============================================================================

class _BraaiEventDetail extends StatefulWidget {
  const _BraaiEventDetail({required this.event});

  final _BraaiEvent event;

  @override
  State<_BraaiEventDetail> createState() => _BraaiEventDetailState();
}

class _BraaiEventDetailState extends State<_BraaiEventDetail> {
  final _db  = Supabase.instance.client;
  String? get _uid    => _db.auth.currentUser?.id;
  String? get _handle => _db.auth.currentUser?.userMetadata?['handle'] as String?
                      ?? _db.auth.currentUser?.email?.split('@').first;

  List<_BraaiItem> _items   = [];
  String?          _myRsvp;   // 'pending' | 'accepted' | 'declined' | null
  bool             _loading  = true;

  // Realtime channel
  RealtimeChannel? _channel;

  // Per-item debounce timers (keyed by item.id)
  final Map<String, Timer> _debounce = {};

  @override
  void initState() {
    super.initState();
    _loadData();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    for (final t in _debounce.values) {
      t.cancel();
    }
    _channel?.unsubscribe();
    super.dispose();
  }

  // ── Data ────────────────────────────────────────────────────────────────────

  Future<void> _loadData() async {
    try {
      // Items
      final itemRows = await _db
          .from('braai_items')
          .select()
          .eq('event_id', widget.event.id)
          .order('created_at', ascending: true);

      // My RSVP
      String? rsvp;
      if (_uid != null) {
        final rsvpRow = await _db
            .from('braai_rsvps')
            .select('status')
            .eq('event_id', widget.event.id)
            .eq('user_id', _uid!)
            .maybeSingle();
        rsvp = rsvpRow?['status'] as String?;
      }

      if (!mounted) return;
      setState(() {
        _items   = (itemRows as List)
            .map((r) => _BraaiItem.fromRow(r as Map<String, dynamic>))
            .toList();
        _myRsvp  = rsvp;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _subscribeRealtime() {
    _channel = _db
        .channel('braai_items_${widget.event.id}')
        .onPostgresChanges(
          event:  PostgresChangeEvent.all,
          schema: 'public',
          table:  'braai_items',
          filter: PostgresChangeFilter(
            type:  PostgresChangeFilterType.eq,
            column: 'event_id',
            value:  widget.event.id,
          ),
          callback: (payload) {
            if (!mounted) return;
            // Re-fetch on any remote change so we see other users' claims
            _loadData();
          },
        )
        .subscribe();
  }

  // ── RSVP ────────────────────────────────────────────────────────────────────

  Future<void> _respond(String status) async {
    if (_uid == null) return;
    try {
      await _db.from('braai_rsvps').upsert(
        {
          'event_id': widget.event.id,
          'user_id':  _uid!,
          'status':   status,
        },
        onConflict: 'event_id,user_id',
      );
      // Mark notification read
      await _db
          .from('notifications')
          .update({'is_read': true})
          .eq('recipient_id', _uid!)
          .contains('payload', {'event_id': widget.event.id});

      if (mounted) setState(() => _myRsvp = status);
    } catch (_) {}
  }

  // ── Item claim ───────────────────────────────────────────────────────────────

  /// Claim or unclaim an item immediately and sync to Supabase.
  Future<void> _toggleClaim(_BraaiItem item) async {
    if (_uid == null) return;
    final nowClaiming = item.broughtByUserId == null;

    // ── Optimistic local update ───────────────────────────────────────────────
    setState(() {
      item.broughtByUserId  = nowClaiming ? _uid      : null;
      item.broughtByHandle  = nowClaiming ? _handle   : null;
      // Preserve exactContribution when unclaiming so re-claim restores text
    });

    try {
      await _db.from('braai_items').update({
        'brought_by_user_id': nowClaiming ? _uid    : null,
        'brought_by_handle':  nowClaiming ? _handle : null,
      }).eq('id', item.id);
    } catch (_) {
      // Revert on failure
      if (mounted) setState(() {
        item.broughtByUserId = nowClaiming ? null : _uid;
        item.broughtByHandle = nowClaiming ? null : _handle;
      });
    }
  }

  /// Debounced exact-contribution update — fires 600 ms after the user stops typing.
  void _onContributionChanged(_BraaiItem item, String text) {
    // ── Immediate local write so the field stays responsive ─────────────────
    setState(() => item.exactContribution = text.isEmpty ? null : text);

    // Cancel any pending debounce for this item
    _debounce[item.id]?.cancel();
    _debounce[item.id] = Timer(const Duration(milliseconds: 600), () async {
      try {
        await _db.from('braai_items').update({
          'exact_contribution': text.isEmpty ? null : text,
        }).eq('id', item.id);
      } catch (_) { /* best-effort; Realtime will reconcile */ }
    });
  }

  // ── Invite friends ───────────────────────────────────────────────────────────

  Future<void> _showInviteSheet() async {
    await showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => _InviteSheet(
        eventId:    widget.event.id,
        eventTitle: widget.event.title,
        senderId:   _uid,
      ),
    );
  }

  // ── Add item ─────────────────────────────────────────────────────────────────

  Future<void> _showAddItemSheet() async {
    final result = await showModalBottomSheet<Map<String, String>>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => _AddItemSheet(eventId: widget.event.id),
    );
    if (result == null || !mounted) return;
    // Re-load to get the server-generated id
    await _loadData();
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isHost  = widget.event.creatorId == _uid;
    final claimed = _items.where((i) => i.isClaimed).length;
    final total   = _items.length;

    return Scaffold(
      backgroundColor: _kCream,
      body: CustomScrollView(
        slivers: [

          // ── Sticky app bar ────────────────────────────────────────────────
          SliverAppBar(
            pinned:          true,
            backgroundColor: _kCream,
            foregroundColor: _kForest,
            title: Text(
              widget.event.title,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize:   17,
                color:      _kForest,
              ),
            ),
            actions: [
              if (isHost)
                IconButton(
                  icon:    const Icon(Icons.person_add_alt_1_rounded),
                  tooltip: 'Invite friends',
                  color:   _kForest,
                  onPressed: _showInviteSheet,
                ),
              if (isHost)
                IconButton(
                  icon:    const Icon(Icons.add_rounded),
                  tooltip: 'Add item',
                  color:   _kForest,
                  onPressed: _showAddItemSheet,
                ),
            ],
          ),

          if (_loading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: _kForest)),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
              sliver: SliverList(
                delegate: SliverChildListDelegate([

                  // ── Event meta card ──────────────────────────────────────
                  _EventMetaCard(event: widget.event),
                  const SizedBox(height: 20),

                  // ── RSVP panel (shown to non-host) ───────────────────────
                  if (!isHost) ...[
                    _RsvpPanel(
                      status:    _myRsvp,
                      onAccept:  () => _respond('accepted'),
                      onDecline: () => _respond('declined'),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // ── Progress ──────────────────────────────────────────────
                  if (total > 0) ...[
                    _ChecklistProgressBar(claimed: claimed, total: total),
                    const SizedBox(height: 16),
                  ],

                  // ── Section header ────────────────────────────────────────
                  Row(
                    children: [
                      const Icon(
                        Icons.checklist_rounded,
                        color: _kForest,
                        size:  20,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Bring List',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize:   16,
                          color:      _kForest,
                        ),
                      ),
                      const Spacer(),
                      if (isHost)
                        TextButton.icon(
                          onPressed: _showAddItemSheet,
                          icon: const Icon(
                            Icons.add_rounded,
                            size:  16,
                            color: _kOrange,
                          ),
                          label: const Text(
                            'Add item',
                            style: TextStyle(
                              color:      _kOrange,
                              fontWeight: FontWeight.w700,
                              fontSize:   13,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // ── Item checklist ────────────────────────────────────────
                  if (_items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          'No items yet — the host will add what to bring.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: _kMuted, fontSize: 13),
                        ),
                      ),
                    )
                  else
                    ...List.generate(_items.length, (i) {
                      final item = _items[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _BraaiItemTile(
                          item:             item,
                          currentUid:       _uid,
                          onToggleClaim:    () => _toggleClaim(item),
                          onContributionChanged: (text) =>
                              _onContributionChanged(item, text),
                        ),
                      );
                    }),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// _EventMetaCard
// =============================================================================

class _EventMetaCard extends StatelessWidget {
  const _EventMetaCard({required this.event});

  final _BraaiEvent event;

  @override
  Widget build(BuildContext context) {
    final dt = event.dateTime;
    final dateStr =
        '${_weekday(dt.weekday)} ${dt.day} ${_month(dt.month)} ${dt.year}';
    final timeStr =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFBF360C), _kOrange],
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_fire_department_rounded,
                  color: Colors.white, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  event.title,
                  style: const TextStyle(
                    color:      Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize:   18,
                  ),
                ),
              ),
            ],
          ),
          if (event.location != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.location_on_rounded,
                    color: Colors.white70, size: 15),
                const SizedBox(width: 5),
                Text(
                  event.location!,
                  style: const TextStyle(
                    color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.calendar_today_rounded,
                  color: Colors.white70, size: 15),
              const SizedBox(width: 5),
              Text(
                '$dateStr  •  $timeStr',
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _RsvpPanel
// =============================================================================

class _RsvpPanel extends StatelessWidget {
  const _RsvpPanel({
    required this.status,
    required this.onAccept,
    required this.onDecline,
  });

  final String?      status;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final isAccepted = status == 'accepted';
    final isDeclined = status == 'declined';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: _kDivider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Are you coming? 🔥',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize:   14,
              color:      _kForest,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: isAccepted ? null : onAccept,
                  icon:  const Icon(Icons.check_rounded, size: 18),
                  label: const Text(
                    'Accept',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor:        _kForest,
                    foregroundColor:        Colors.white,
                    disabledBackgroundColor: _kForest.withAlpha(120),
                    disabledForegroundColor: Colors.white.withValues(alpha: 0.85),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: isDeclined ? null : onDecline,
                  icon: Icon(
                    Icons.close_rounded,
                    size:  18,
                    color: isDeclined ? _kMuted : Colors.redAccent,
                  ),
                  label: Text(
                    'Decline',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color:      isDeclined ? _kMuted : Colors.redAccent,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: isDeclined ? _kDivider : Colors.redAccent,
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
          if (status != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  isAccepted
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  size:  16,
                  color: isAccepted ? _kForest : Colors.redAccent,
                ),
                const SizedBox(width: 6),
                Text(
                  isAccepted
                      ? "You've RSVP'd — see you at the braai! 🔥"
                      : "You've declined this event.",
                  style: TextStyle(
                    fontSize:   12,
                    color:      isAccepted ? _kForest : Colors.redAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// _ChecklistProgressBar
// =============================================================================

class _ChecklistProgressBar extends StatelessWidget {
  const _ChecklistProgressBar({required this.claimed, required this.total});

  final int claimed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final pct  = total == 0 ? 0.0 : claimed / total;
    final done = claimed == total;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        done ? _kForest.withAlpha(20) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(
          color: done ? _kForest.withAlpha(60) : _kDivider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                done ? '🎉 All sorted!' : '$claimed / $total items claimed',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize:   13,
                  color:      done ? _kForest : _kMuted,
                ),
              ),
              const Spacer(),
              Text(
                '${(pct * 100).round()}%',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize:   13,
                  color:      done ? _kForest : _kOrange,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value:           pct,
              backgroundColor: _kDivider,
              color:           done ? _kForest : _kOrange,
              minHeight:       8,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _BraaiItemTile — live claim + editable contribution field
// =============================================================================

class _BraaiItemTile extends StatefulWidget {
  const _BraaiItemTile({
    required this.item,
    required this.currentUid,
    required this.onToggleClaim,
    required this.onContributionChanged,
  });

  final _BraaiItem  item;
  final String?     currentUid;
  final VoidCallback onToggleClaim;
  final void Function(String) onContributionChanged;

  @override
  State<_BraaiItemTile> createState() => _BraaiItemTileState();
}

class _BraaiItemTileState extends State<_BraaiItemTile> {
  late final TextEditingController _ctrl;

  bool get _isMyItem => widget.item.broughtByUserId == widget.currentUid;
  bool get _isClaimed => widget.item.isClaimed;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.item.exactContribution ?? '',
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_BraaiItemTile old) {
    super.didUpdateWidget(old);
    // Sync controller when a remote update comes in (from Realtime)
    // but only if this is not my item (avoid clobbering mid-type)
    if (!_isMyItem) {
      final remote = widget.item.exactContribution ?? '';
      if (_ctrl.text != remote) _ctrl.text = remote;
    }
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = _isMyItem
        ? _kForest
        : _isClaimed
            ? _kAmber.withAlpha(160)
            : _kDivider;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color:        _isMyItem
            ? _kForest.withAlpha(10)
            : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: borderColor, width: _isMyItem ? 1.5 : 1),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Item header row ─────────────────────────────────────────────
          Row(
            children: [
              // Claim checkbox
              GestureDetector(
                onTap: !_isClaimed || _isMyItem
                    ? widget.onToggleClaim
                    : null,  // can't claim something someone else claimed
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width:  28,
                  height: 28,
                  decoration: BoxDecoration(
                    color:  _isMyItem
                        ? _kForest
                        : _isClaimed
                            ? _kAmber.withAlpha(60)
                            : _kDivider.withAlpha(120),
                    shape:  BoxShape.circle,
                    border: Border.all(
                      color: _isMyItem
                          ? _kForest
                          : _isClaimed
                              ? _kAmber
                              : _kDivider,
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    _isMyItem
                        ? Icons.check_rounded
                        : _isClaimed
                            ? Icons.person_rounded
                            : Icons.add_rounded,
                    size:  16,
                    color: _isMyItem
                        ? Colors.white
                        : _isClaimed
                            ? _kAmber
                            : _kMuted,
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // Item name + quantity
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.item.itemName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize:   14,
                        color:      _kForest,
                      ),
                    ),
                    if (widget.item.targetQuantity != null)
                      Text(
                        'Need: ${widget.item.targetQuantity}',
                        style: const TextStyle(
                          fontSize: 11,
                          color:    _kMuted,
                        ),
                      ),
                  ],
                ),
              ),

              // Claimed-by badge
              if (_isClaimed && !_isMyItem)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color:        _kAmber.withAlpha(25),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _kAmber.withAlpha(80)),
                  ),
                  child: Text(
                    widget.item.broughtByHandle ?? 'Someone',
                    style: const TextStyle(
                      fontSize:   11,
                      fontWeight: FontWeight.w700,
                      color:      _kAmber,
                    ),
                  ),
                ),

              if (_isMyItem)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color:        _kForest.withAlpha(20),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'You ✓',
                    style: TextStyle(
                      fontSize:   11,
                      fontWeight: FontWeight.w800,
                      color:      _kForest,
                    ),
                  ),
                ),
            ],
          ),

          // ── Exact contribution field (only for claimer) ────────────────
          if (_isMyItem) ...[
            const SizedBox(height: 10),
            TextField(
              controller:         _ctrl,
              textCapitalization: TextCapitalization.sentences,
              onChanged:          widget.onContributionChanged,
              style:              const TextStyle(fontSize: 13, color: _kForest),
              decoration: InputDecoration(
                hintText: 'What exactly are you bringing? (e.g. 6 Castle Lites)',
                hintStyle: const TextStyle(
                    color: _kMuted, fontSize: 12),
                filled:     true,
                fillColor:  Colors.white,
                isDense:    true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:   const BorderSide(color: _kDivider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:   const BorderSide(color: _kDivider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      const BorderSide(color: _kForest, width: 1.5),
                ),
              ),
            ),
          ] else if (_isClaimed && widget.item.exactContribution != null) ...[
            // Show read-only contribution from another claimant
            const SizedBox(height: 6),
            Text(
              '🧺 ${widget.item.exactContribution}',
              style: const TextStyle(
                fontSize:  12,
                color:     _kMuted,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// _InviteSheet — invite friends by username
// =============================================================================

class _InviteSheet extends StatefulWidget {
  const _InviteSheet({
    required this.eventId,
    required this.eventTitle,
    required this.senderId,
  });

  final String  eventId;
  final String  eventTitle;
  final String? senderId;

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final _db   = Supabase.instance.client;
  final _ctrl = TextEditingController();
  bool _sending = false;
  String? _feedback;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    // Sanitise per spec — strip an accidental '@' and trim whitespace so
    // typed input like "@Melrose " or "Melrose" both resolve to "Melrose".
    final String cleanUsername =
        _ctrl.text.replaceFirst('@', '').trim();
    if (cleanUsername.isEmpty) return;
    setState(() { _sending = true; _feedback = null; });

    try {
      // Route through the `find_user_by_handle` SECURITY DEFINER RPC. A
      // direct `profiles` select returns null for every row except the
      // caller's own (row-level read policy `auth.uid() = id`), so the
      // legacy `.ilike()` path produced "user not found" on every legit
      // friend. The RPC bypasses RLS for an explicit by-handle lookup.
      final rpcRes = await _db
          .rpc('find_user_by_handle', params: {'q': cleanUsername});
      Map<String, dynamic>? profile;
      if (rpcRes is List && rpcRes.isNotEmpty) {
        profile = Map<String, dynamic>.from(rpcRes.first as Map);
      } else if (rpcRes is Map) {
        profile = Map<String, dynamic>.from(rpcRes);
      }

      if (profile == null || profile['id'] == null) {
        setState(() {
          _feedback = 'Could not find username $cleanUsername';
          _sending  = false;
        });
        return;
      }

      final inviteeId = profile['id'] as String;

      // Upsert RSVP row (status = pending)
      final rsvpRes = await _db.from('braai_rsvps').upsert(
        {
          'event_id': widget.eventId,
          'user_id':  inviteeId,
          'status':   'pending',
        },
        onConflict: 'event_id,user_id',
      ).select('id').single();

      // Insert notification so the friend sees it in their inbox
      await _db.from('notifications').insert({
        'recipient_id': inviteeId,
        'sender_id':    widget.senderId,
        'type':         'braai_invite',
        'payload': {
          'event_id':    widget.eventId,
          'event_title': widget.eventTitle,
          'rsvp_id':     rsvpRes['id'],
        },
        'is_read': false,
      });

      if (mounted) {
        setState(() {
          _feedback = '✅ $cleanUsername has been invited!';
          _sending  = false;
          _ctrl.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _feedback = '⚠️ Could not send invite. Please try again.';
          _sending  = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(24, 24, 24, bottom + 24),
      decoration: const BoxDecoration(
        color:        _kCream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      // Same keyboard-overflow hardening as _AddItemSheet — keeps the sheet
      // resilient when the keyboard opens, even if we add more fields later.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color:        _kDivider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Invite a friend 👥',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize:   17,
              color:      _kForest,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Enter their ChowSA username to invite them to this braai.',
            style: TextStyle(fontSize: 13, color: _kMuted),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller:         _ctrl,
                  autofocus:          true,
                  textInputAction:    TextInputAction.send,
                  onSubmitted:        (_) => _invite(),
                  decoration: const InputDecoration(
                    // No '@' prefix anywhere — users type the raw username.
                    // _invite() strips an accidental '@' before the lookup.
                    hintText:      'Friend username (e.g. Melrose)',
                    filled:        true,
                    fillColor:     Colors.white,
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                      borderSide:   BorderSide(color: _kDivider),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                      borderSide:   BorderSide(color: _kDivider),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                      borderSide:   BorderSide(color: _kForest, width: 1.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _sending ? null : _invite,
                style: FilledButton.styleFrom(
                  backgroundColor: _kOrange,
                  minimumSize: const Size(56, 52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: _sending
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded, size: 20),
              ),
            ],
          ),
          if (_feedback != null) ...[
            const SizedBox(height: 12),
            Text(
              _feedback!,
              style: TextStyle(
                fontSize:   13,
                fontWeight: FontWeight.w600,
                color: _feedback!.startsWith('✅') ? _kForest : Colors.redAccent,
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }
}

// =============================================================================
// _AddItemSheet — host adds an item to the checklist
// =============================================================================

class _AddItemSheet extends StatefulWidget {
  const _AddItemSheet({required this.eventId});

  final String eventId;

  @override
  State<_AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends State<_AddItemSheet> {
  final _db      = Supabase.instance.client;
  final _nameCtrl = TextEditingController();
  final _qtyCtrl  = TextEditingController();
  bool  _saving   = false;

  static const _kSuggestions = [
    'Beers', 'Boerewors', 'Chicken Pieces', 'Meat',
    'Rolls / Bread', 'Salad', 'Chips & Dips', 'Ice & Cooler Box',
    'Braai Sauce', 'Soft Drinks', 'Dessert', 'Charcoal / Wood',
  ];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);

    try {
      await _db.from('braai_items').insert({
        'event_id':        widget.eventId,
        'item_name':       name,
        'target_quantity': _qtyCtrl.text.trim().isEmpty
            ? null
            : _qtyCtrl.text.trim(),
      });
      if (mounted) Navigator.pop(context, {'item_name': name});
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(24, 24, 24, bottom + 24),
      decoration: const BoxDecoration(
        color:        _kCream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      // Keyboard-overflow fix: chips Wrap + 2 TextFields + button overflowed
      // the residual height under the soft keyboard by ~14 px. Wrapping the
      // intrinsic Column in a scroll view lets the content scroll behind the
      // keyboard instead of throwing a RenderFlex overflow at frame time.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color:        _kDivider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Add to Bring List 🧺',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize:   17,
              color:      _kForest,
            ),
          ),
          const SizedBox(height: 16),

          // Suggestion chips
          Wrap(
            spacing: 8, runSpacing: 8,
            children: _kSuggestions.map((s) => GestureDetector(
              onTap: () => setState(() => _nameCtrl.text = s),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color:        _kForest.withAlpha(10),
                  borderRadius: BorderRadius.circular(20),
                  border:       Border.all(color: _kForest.withAlpha(40)),
                ),
                child: Text(
                  s,
                  style: const TextStyle(
                    fontSize:   12,
                    fontWeight: FontWeight.w600,
                    color:      _kForest,
                  ),
                ),
              ),
            )).toList(),
          ),
          const SizedBox(height: 16),

          TextField(
            controller:         _nameCtrl,
            autofocus:          true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText:     'Item name *',
              hintText:      'e.g. Boerewors',
              filled:        true,
              fillColor:     Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller:     _qtyCtrl,
            textInputAction: TextInputAction.done,
            onSubmitted:    (_) => _save(),
            decoration: const InputDecoration(
              labelText:  'Target quantity (optional)',
              hintText:   'e.g. 2 kg, 24 cans, 1 packet',
              filled:     true,
              fillColor:  Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon:  const Icon(Icons.add_rounded, size: 20),
              label: const Text(
                'Add Item',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _kOrange,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

// =============================================================================
// _NewEventSheet — create a new braai event
// =============================================================================

class _NewEventSheet extends StatefulWidget {
  const _NewEventSheet({required this.creatorId});

  final String creatorId;

  @override
  State<_NewEventSheet> createState() => _NewEventSheetState();
}

class _NewEventSheetState extends State<_NewEventSheet> {
  final _db          = Supabase.instance.client;
  final _titleCtrl   = TextEditingController();
  final _locationCtrl = TextEditingController();
  DateTime? _pickedDate;
  TimeOfDay? _pickedTime;
  bool      _saving   = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context:     context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate:   DateTime.now(),
      lastDate:    DateTime.now().add(const Duration(days: 365)),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme.copyWith(
            primary: _kForest,
          ),
        ),
        child: child!,
      ),
    );
    if (d != null && mounted) setState(() => _pickedDate = d);
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context:     context,
      initialTime: const TimeOfDay(hour: 14, minute: 0),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme.copyWith(
            primary: _kForest,
          ),
        ),
        child: child!,
      ),
    );
    if (t != null && mounted) setState(() => _pickedTime = t);
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) return;
    final date = _pickedDate;
    final time = _pickedTime ?? const TimeOfDay(hour: 14, minute: 0);
    if (date == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please pick a date for the braai.')),
      );
      return;
    }

    setState(() => _saving = true);

    final dt = DateTime(
      date.year, date.month, date.day, time.hour, time.minute,
    );

    try {
      final row = await _db.from('braai_events').insert({
        'creator_id': widget.creatorId,
        'title':      title,
        'location':   _locationCtrl.text.trim().isEmpty
            ? null
            : _locationCtrl.text.trim(),
        'date_time':  dt.toUtc().toIso8601String(),
      }).select().single();

      if (mounted) {
        Navigator.pop(context, _BraaiEvent.fromRow(row));
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;

    final dateLabel = _pickedDate == null
        ? 'Pick a date *'
        : '${_pickedDate!.day}/${_pickedDate!.month}/${_pickedDate!.year}';

    final timeLabel = _pickedTime == null
        ? '14:00 (default)'
        : '${_pickedTime!.hour.toString().padLeft(2, '0')}:'
          '${_pickedTime!.minute.toString().padLeft(2, '0')}';

    return Container(
      padding: EdgeInsets.fromLTRB(24, 24, 24, bottom + 24),
      decoration: const BoxDecoration(
        color:        _kCream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color:        _kDivider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Row(
              children: [
                Text('🔥', style: TextStyle(fontSize: 22)),
                SizedBox(width: 10),
                Text(
                  'Plan a Braai',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize:   19,
                    color:      _kForest,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            TextField(
              controller:         _titleCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Event name *',
                hintText:  'e.g. Heritage Day Braai 2026',
                filled:    true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(14)),
                ),
              ),
            ),
            const SizedBox(height: 12),

            TextField(
              controller:         _locationCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Location (optional)',
                hintText:  'e.g. Bloubergstrand Beach, Cape Town',
                filled:    true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(14)),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Date + Time row
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _pickDate,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color:        Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border:       Border.all(color: _kDivider),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_today_rounded,
                              size: 18, color: _kForest),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              dateLabel,
                              style: TextStyle(
                                fontSize: 13,
                                color: _pickedDate == null
                                    ? _kMuted
                                    : _kForest,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: _pickTime,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color:        Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border:       Border.all(color: _kDivider),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.access_time_rounded,
                              size: 18, color: _kForest),
                          const SizedBox(width: 8),
                          Text(
                            timeLabel,
                            style: const TextStyle(
                              fontSize:   13,
                              color:      _kForest,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white),
                      )
                    : const Icon(Icons.local_fire_department_rounded,
                        size: 20),
                label: Text(
                  _saving ? 'Creating…' : 'Create Braai Event',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _kOrange,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _EmptyEventsHint
// =============================================================================

class _EmptyEventsHint extends StatelessWidget {
  const _EmptyEventsHint({required this.onCreateTap});

  final VoidCallback onCreateTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width:  88,
              height: 88,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFBF360C), _kOrange],
                  begin: Alignment.topLeft,
                  end:   Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Icon(
                Icons.local_fire_department_rounded,
                color: Colors.white,
                size:  42,
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'No braais planned yet!',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize:   19,
                color:      _kForest,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Create a Bring & Braai event, invite your choms, '
              'and sort out who brings what — all in one place.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color:  _kMuted,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onCreateTap,
              icon:  const Icon(Icons.add_rounded),
              label: const Text(
                'Plan a Braai',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _kOrange,
                padding: const EdgeInsets.symmetric(
                    horizontal: 28, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
