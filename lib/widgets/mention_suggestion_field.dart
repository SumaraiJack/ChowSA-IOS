// lib/widgets/mention_suggestion_field.dart
//
// A TextField that shows an inline @mention suggestion panel as the user
// types an "@handle" token — mirroring the handle picker used elsewhere in
// the app, but for free-text composers (community post caption + comments).
//
// Design goals:
//   • Drop-in: takes the same controller / decoration / maxLines a plain
//     TextField would, so wiring it in doesn't change any surrounding layout
//     or submit logic.
//   • No OverlayEntry — the suggestion list renders directly beneath the
//     field inside the existing scroll view, so it can't get "stuck" the
//     way a global overlay can.
//   • Friends-sourced suggestions (same source as UserHandleAutocomplete),
//     so what you can @mention matches what the mention push trigger can
//     actually resolve.

import 'package:flutter/material.dart';
import '../services/friends_service.dart';

class MentionSuggestionField extends StatefulWidget {
  const MentionSuggestionField({
    super.key,
    required this.controller,
    this.focusNode,
    this.decoration,
    this.minLines,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.sentences,
    this.textInputAction,
    this.onSubmitted,
    this.autofocus = false,
    this.accentColor = const Color(0xFF0C351E),
    this.suggestionsAbove = false,
  });

  final TextEditingController controller;
  final FocusNode?            focusNode;
  final InputDecoration?      decoration;
  final int?                 minLines;
  final int                  maxLines;
  final TextCapitalization   textCapitalization;
  final TextInputAction?     textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool                 autofocus;
  final Color                accentColor;
  /// True when the suggestion list should render ABOVE the text field
  /// (chat composers — so the dropdown floats up into the message list
  /// instead of getting clipped between the field and the keyboard).
  /// Defaults to false (post / comment composers, where the dropdown
  /// goes below as usual).
  final bool                 suggestionsAbove;

  @override
  State<MentionSuggestionField> createState() => _MentionSuggestionFieldState();
}

class _MentionSuggestionFieldState extends State<MentionSuggestionField> {
  List<FriendProfile> _friends   = const [];
  List<FriendProfile> _matches   = const [];
  String?             _activeQuery;

  // Matches an "@token" sitting immediately before the caret. Group 1 is the
  // partial handle the user has typed so far (may be empty right after "@").
  static final _mentionRe = RegExp(r'(?:^|\s)@([A-Za-z0-9_]{0,30})$');

  @override
  void initState() {
    super.initState();
    _loadFriends();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _loadFriends() async {
    try {
      final fs = await FriendsService.instance.loadAcceptedFriends();
      if (!mounted) return;
      setState(() => _friends = fs.map((f) => f.other).toList());
    } catch (_) {/* offline — suggestions simply stay empty */}
  }

  void _onChanged() {
    final sel = widget.controller.selection;
    final text = widget.controller.text;
    // Only react when we have a collapsed caret we can read a token before.
    if (!sel.isValid || !sel.isCollapsed || sel.baseOffset < 0) {
      _clear();
      return;
    }
    final upToCaret = text.substring(0, sel.baseOffset);
    final m = _mentionRe.firstMatch(upToCaret);
    if (m == null) {
      _clear();
      return;
    }
    final q = m.group(1)!.toLowerCase();
    // Don't pre-populate the entire friends list the moment the user
    // types "@" — on big friend lists that pushes the panel tall enough
    // to overflow into the message area. Wait until they've typed at
    // least one character so we can actually narrow the matches.
    if (q.isEmpty) {
      _clear();
      return;
    }
    final matches = _friends.where((p) {
      return p.handle.toLowerCase().contains(q) ||
          (p.displayName?.toLowerCase().contains(q) ?? false);
    }).take(6).toList();
    if (matches.isEmpty) {
      _clear();
      return;
    }
    setState(() {
      _activeQuery = q;
      _matches     = matches;
    });
  }

  void _clear() {
    if (_activeQuery == null && _matches.isEmpty) return;
    setState(() {
      _activeQuery = null;
      _matches     = const [];
    });
  }

  void _pick(FriendProfile p) {
    final text = widget.controller.text;
    final sel  = widget.controller.selection;
    final caret = sel.baseOffset;
    final upToCaret = text.substring(0, caret);
    final m = _mentionRe.firstMatch(upToCaret);
    if (m == null) return;
    // Replace from the '@' (m.start may include a leading space we must keep).
    final atIndex = upToCaret.lastIndexOf('@');
    if (atIndex < 0) return;
    final replacement = '@${p.handle} ';
    final newText = text.substring(0, atIndex) + replacement + text.substring(caret);
    final newCaret = atIndex + replacement.length;
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCaret),
    );
    _clear();
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller:         widget.controller,
      focusNode:          widget.focusNode,
      minLines:           widget.minLines,
      maxLines:           widget.maxLines,
      autofocus:          widget.autofocus,
      textCapitalization: widget.textCapitalization,
      textInputAction:    widget.textInputAction,
      onSubmitted:        widget.onSubmitted,
      decoration:         widget.decoration,
    );
    final dropdown = _matches.isEmpty
        ? const SizedBox.shrink()
        : Container(
            margin: EdgeInsets.only(
              top:    widget.suggestionsAbove ? 0 : 6,
              bottom: widget.suggestionsAbove ? 6 : 0,
            ),
            constraints: const BoxConstraints(maxHeight: 160),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE6E2D8)),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _matches.length,
              itemBuilder: (_, i) {
                final p = _matches[i];
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: widget.accentColor,
                    child: Text(
                      p.initials,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w900),
                    ),
                  ),
                  title: Text('@${p.handle}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: p.displayName == null
                      ? null
                      : Text(p.displayName!,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF55534E))),
                  onTap: () => _pick(p),
                );
              },
            ),
          );
    final children = widget.suggestionsAbove
        ? <Widget>[dropdown, field]
        : <Widget>[field, dropdown];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
