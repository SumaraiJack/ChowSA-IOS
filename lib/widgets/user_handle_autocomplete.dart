// lib/widgets/user_handle_autocomplete.dart
//
// Reusable handle picker — wraps the same Autocomplete<FriendProfile>
// pattern the Shopping List share sheet already ships, so the Meal
// Planner share dialog (and any future share surface) doesn't have to
// reinvent the dropdown UI. Both call-sites point at one widget, which
// means a fix to the autocomplete behaviour lands in both places at once.
//
// Behaviour:
//   • On first mount, calls FriendsService.loadAcceptedFriends() and
//     caches the list locally.
//   • As the user types, filters the cached list by handle / display name.
//   • Tapping a row sets the text field to "@handle" and reports the
//     picked FriendProfile back to the parent via [onSelected]. The text
//     box still accepts a free-typed handle for users who aren't in the
//     accepted-friends list yet.
//   • Mirrors typing into the parent-owned [controller] so the parent
//     can read the current text on Submit / Send.

import 'package:flutter/material.dart';
import '../services/friends_service.dart';

class UserHandleAutocomplete extends StatefulWidget {
  const UserHandleAutocomplete({
    super.key,
    required this.controller,
    this.onSelected,
    this.onSubmitted,
    this.autofocus = true,
    this.accentColor = const Color(0xFF0C351E),
    this.hintText,
  });

  /// Parent-owned controller — keeps a single source of truth for the
  /// typed handle so the Send button can read the current text.
  final TextEditingController controller;

  /// Fired when the user taps a suggestion. Optional — callers that
  /// only care about the raw handle string can ignore it.
  final ValueChanged<FriendProfile>? onSelected;

  /// Fired when the user submits via the keyboard. Matches the shopping
  /// list behaviour where Enter sends the share.
  final VoidCallback? onSubmitted;

  final bool         autofocus;
  final Color        accentColor;
  final String?      hintText;

  @override
  State<UserHandleAutocomplete> createState() => _UserHandleAutocompleteState();
}

class _UserHandleAutocompleteState extends State<UserHandleAutocomplete> {
  List<FriendProfile> _friendOptions = const [];

  /// Handle the user just tapped. While the field text still equals this
  /// (e.g. "@melrose"), optionsBuilder returns nothing so the dropdown
  /// closes instead of re-showing the row that was just picked — the
  /// "popup stays open after selecting" bug. Cleared once the user edits
  /// the field to anything else.
  String? _justPicked;

  /// Captured from fieldViewBuilder so onSelected can drop focus, which
  /// dismisses the Autocomplete overlay.
  FocusNode? _focusNode;

  @override
  void initState() {
    super.initState();
    _ensureFriendsLoaded();
  }

  Future<void> _ensureFriendsLoaded() async {
    final friendships = await FriendsService.instance.loadAcceptedFriends();
    if (!mounted) return;
    setState(() => _friendOptions =
        friendships.map((f) => f.other).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Autocomplete<FriendProfile>(
      displayStringForOption: (p) => p.handle,
      optionsBuilder: (TextEditingValue value) {
        final q = value.text.trim().toLowerCase();
        // Suppress the list while the text still equals the just-picked
        // handle so the overlay closes after a selection. Flutter sets the
        // field to the bare handle on select; the user may also type "@handle".
        if (_justPicked != null &&
            (q == _justPicked!.toLowerCase() ||
             q == '@${_justPicked!.toLowerCase()}')) {
          return const Iterable<FriendProfile>.empty();
        }
        _justPicked = null;
        if (q.isEmpty) return _friendOptions;
        return _friendOptions.where((p) {
          return p.handle.toLowerCase().contains(q) ||
              (p.displayName?.toLowerCase().contains(q) ?? false);
        });
      },
      onSelected: (FriendProfile p) {
        _justPicked = p.handle;
        widget.controller.text = '@${p.handle}';
        widget.onSelected?.call(p);
        // Drop focus so the options overlay dismisses immediately.
        _focusNode?.unfocus();
      },
      fieldViewBuilder: (ctx, fieldCtrl, focus, onSubmit) {
        _focusNode = focus;
        // Mirror the Autocomplete-managed controller into the parent's
        // controller so external Send handlers always read the current
        // text (same trick the shopping list uses).
        fieldCtrl.addListener(() {
          if (widget.controller.text != fieldCtrl.text) {
            widget.controller.text = fieldCtrl.text;
          }
        });
        return TextField(
          controller:       fieldCtrl,
          focusNode:        focus,
          autofocus:        widget.autofocus,
          textInputAction:  TextInputAction.send,
          onSubmitted:      (_) => widget.onSubmitted?.call(),
          style: const TextStyle(fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            hintText: widget.hintText ??
                (_friendOptions.isEmpty
                    ? 'Friend username (e.g. Melrose)'
                    : 'Pick a friend or type a username…'),
            hintStyle: const TextStyle(color: Color(0xFFADADA7)),
            filled:        true,
            fillColor:     Colors.white,
            contentPadding:
                const EdgeInsets.fromLTRB(12, 13, 12, 13),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:   BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  BorderSide(color: widget.accentColor, width: 1.5),
            ),
          ),
        );
      },
      optionsViewBuilder: (ctx, onSelect, options) {
        // Clamp the dropdown to the visible space ABOVE the keyboard so
        // the bottom rows stay tappable instead of disappearing under
        // the soft keyboard. We compute the cap from the SCREEN's view
        // insets (Autocomplete's overlay sits at the root, so its
        // MediaQuery sees the raw viewInsets).
        final media        = MediaQuery.of(ctx);
        final keyboardArea = media.viewInsets.bottom;
        // 220 is the design max; shrink when the keyboard takes a bite,
        // floor at 140 so at least three rows + their avatars stay
        // readable rather than getting compressed into illegible strips.
        final dropdownMax =
            (media.size.height - keyboardArea - 320).clamp(140.0, 220.0);
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: dropdownMax, maxWidth: 280),
              child: ListView.builder(
                shrinkWrap:    true,
                padding:       EdgeInsets.zero,
                // Don't let the dropdown auto-clip itself further if the
                // overlay area is genuinely tiny — let the bouncing
                // physics surface the cut-off rows by scroll instead.
                physics:       const ClampingScrollPhysics(),
                itemExtent:    52,
                itemCount:     options.length,
                itemBuilder: (_, i) {
                  final p = options.elementAt(i);
                  return ListTile(
                    dense:           true,
                    visualDensity:   VisualDensity.standard,
                    minVerticalPadding: 0,
                    leading: CircleAvatar(
                      backgroundColor: widget.accentColor,
                      radius: 16,
                      child: Text(
                        p.initials,
                        style: const TextStyle(
                          color:      Colors.white,
                          fontSize:   11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    title: Text('@${p.handle}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: p.displayName == null
                        ? null
                        : Text(p.displayName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF55534E))),
                    onTap: () => onSelect(p),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
