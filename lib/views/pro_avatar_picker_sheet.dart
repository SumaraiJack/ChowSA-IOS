// lib/views/pro_avatar_picker_sheet.dart
//
// Pro-tier avatar selection sheet. Renders a 4-column grid of culturally
// diverse Mzansi avatar options.
//
// Special creator lock: two exclusive avatars are gated by exact username
// match (case-insensitive):
//   • 'sumaraijack' → avatar_sumaraijack.png  (Cyber Samurai Warrior Chef)
//   • 'melrose'     → avatar_melrose.png
// For every other user both entries are invisible and unreachable.
//
// Assets required in pubspec.yaml (directory declaration bundles all files):
//   assets:
//     - assets/avatars/
//
// Physical files (20 standard + 2 exclusive). Standard set ordered by
// region in [_standardAvatars] — see that list for the authoritative
// ordering shown in the picker sheet.
//   Standard: Bo-Kaap Spice Uncle, Cape Malay Spice Queen,
//     Cape Flats Hip-Hop Cook, Cape Coloured Aweh Cook,
//     Khayelitsha Braai Bro, Stellenbosch Wine Chef, Sandton Foodie Gal,
//     Soweto Gogo Wink, Joburg Greek Yiayia, Portuguese Peri-Peri Chef,
//     Pretoria Braai Oom, Amapiano Grooves Cook, Durban Bunny Uncle,
//     Chatsworth Curry Auntie, East Cape Coloured Tannie,
//     Xhosa Traditional, Limpopo Pap Master, Venda Joyful Chef,
//     Venda Bright Weave, Ndebele Geometric.
//   Exclusive:
//     SumaraiJack.png   (hidden by default — creator exclusive)
//     Melrose.png        (hidden by default — creator exclusive)

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Opens the picker sheet and returns the selected asset path
/// (e.g. `'assets/avatars/avatar_3.png'`) or null when dismissed.
Future<String?> showProAvatarPickerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context:            context,
    isScrollControlled: true,
    backgroundColor:    Colors.transparent,
    builder:            (_) => const ProAvatarPickerSheet(),
  );
}

class ProAvatarPickerSheet extends StatefulWidget {
  const ProAvatarPickerSheet({super.key});

  /// Usernames that unlock exclusive creator avatars (case-insensitive,
  /// leading '@' tolerated). Any username not in this set sees only the
  /// 10 standard Mzansi avatars — the exclusive IDs are fully omitted.
  static const String _creatorSumaraijack = 'sumaraijack';
  static const String _creatorMelrose     = 'melrose';

  @override
  State<ProAvatarPickerSheet> createState() => _ProAvatarPickerSheetState();
}

class _ProAvatarPickerSheetState extends State<ProAvatarPickerSheet> {
  // Standard set — visible to every Pro user.
  // Paths must match the EXACT physical filenames in assets/avatars/ (case-
  // sensitive on Android/Linux, spaces included). The directory declaration
  // `assets/avatars/` in pubspec.yaml bundles every file in the folder.
  //
  // Lineup curated for the SA market — Cape Town, Joburg, Durban,
  // Pretoria, Eastern Cape and Limpopo represented across cultures.
  // The five removed below (Boerewors Braai Master, Karoo Tannie
  // Baker, Springbok Superfan, Soweto Street Food King, Zulu
  // Heritage) had busy scene backgrounds that didn't crop cleanly
  // into the circle avatar UI — replaced by 15 new transparent-PNG
  // mascot portraits in the same flat-illustration style as
  // SumaraiJack / Melrose.
  static const List<String> _standardAvatars = [
    // ── Cape Town ─────────────────────────────────────────────────
    'assets/avatars/Bo-Kaap Spice Uncle.png',
    'assets/avatars/Cape Malay Spice Queen.png',
    'assets/avatars/Cape Flats Hip-Hop Cook.png',
    'assets/avatars/Cape Coloured Aweh Cook.png',
    'assets/avatars/Khayelitsha Braai Bro.png',
    'assets/avatars/Stellenbosch Wine Chef.png',
    // ── Joburg / Pretoria ────────────────────────────────────────
    'assets/avatars/Sandton Foodie Gal.png',
    'assets/avatars/Soweto Gogo Wink.png',
    'assets/avatars/Joburg Greek Yiayia.png',
    'assets/avatars/Portuguese Peri-Peri Chef.png',
    'assets/avatars/Pretoria Braai Oom.png',
    'assets/avatars/Amapiano Grooves Cook.png',
    // ── KZN ──────────────────────────────────────────────────────
    'assets/avatars/Durban Bunny Uncle.png',
    'assets/avatars/Chatsworth Curry Auntie.png',
    // ── Eastern Cape ─────────────────────────────────────────────
    'assets/avatars/East Cape Coloured Tannie.png',
    'assets/avatars/Xhosa Traditional.png',
    // ── Limpopo / Venda / Ndebele ────────────────────────────────
    'assets/avatars/Limpopo Pap Master.png',
    'assets/avatars/Venda Joyful Chef.png',
    'assets/avatars/Venda Bright Weave.png',
    'assets/avatars/Ndebele Geometric.png',
  ];

  // Exclusive creator avatars — each locked to a single username account.
  // Filenames match the physical PNGs dropped into assets/avatars/.
  static const String _avatarSumaraijack = 'assets/avatars/SumaraiJack.png';
  static const String _avatarMelrose     = 'assets/avatars/Melrose.png';

  /// Resolved profile username string. Looked up once on init so the
  /// build method can render the gated entry synchronously.
  String? _myUsername;

  @override
  void initState() {
    super.initState();
    _loadUsername();
  }

  Future<void> _loadUsername() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('username, handle')
          .eq('id', uid)
          .maybeSingle();
      if (!mounted || row == null) return;
      setState(() {
        _myUsername = (row['username'] as String?) ??
                      (row['handle']   as String?);
      });
    } catch (_) {/* leave null → exclusive avatar stays hidden */}
  }

  /// Builds the avatar array applying a STRICT username guard clause:
  ///
  ///   • Base: 'avatar_1' – 'avatar_10' visible to every Pro user.
  ///   • 'sumaraijack' → also injects 'avatar_sumaraijack'.
  ///   • 'melrose'     → also injects 'avatar_melrose'.
  ///   • Anyone else   → exclusive IDs are completely omitted; users
  ///                      cannot see or select them.
  List<String> get _avatars {
    // Normalise: strip leading '@', trim whitespace, lowercase.
    final username = (_myUsername ?? '')
        .trim()
        .replaceFirst(RegExp(r'^@'), '')
        .toLowerCase();

    return [
      // ── Standard Mzansi avatars — available to all Pro users ──────────
      ..._standardAvatars,

      // ── Exclusive creator slots — strict username guard ────────────────
      if (username == ProAvatarPickerSheet._creatorSumaraijack)
        _avatarSumaraijack,

      if (username == ProAvatarPickerSheet._creatorMelrose)
        _avatarMelrose,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final avatars = _avatars;
    final bottom  = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;
    // True when the current user has at least one exclusive avatar unlocked.
    final isCreator = avatars.length > _standardAvatars.length;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF4F1EA),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.82,
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFE6E2D8),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Header
          Row(
            children: [
              const Text(
                'Choose your chef avatar',
                style: TextStyle(
                  fontSize:   17,
                  fontWeight: FontWeight.w900,
                  color:      Color(0xFF0C351E),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFE59B27),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'PRO',
                  style: TextStyle(
                    fontSize:      10,
                    fontWeight:    FontWeight.w900,
                    color:         Colors.white,
                    letterSpacing: 1,
                  ),
                ),
              ),
              if (isCreator) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [
                      Color(0xFFFF6F00),
                      Color(0xFFE65100),
                    ]),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'CREATOR',
                    style: TextStyle(
                      fontSize:      10,
                      fontWeight:    FontWeight.w900,
                      color:         Colors.white,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          // Grid
          Flexible(
            child: GridView.builder(
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:  4,
                mainAxisSpacing:  12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.0,
              ),
              itemCount: avatars.length,
              itemBuilder: (_, i) {
                final path = avatars[i];
                // Highlight the tile if it's one of the exclusive creator avatars.
                final isExclusive =
                    path == _avatarSumaraijack || path == _avatarMelrose;
                return GestureDetector(
                  onTap: () => Navigator.pop(context, path),
                  child: Container(
                    decoration: BoxDecoration(
                      color:        Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isExclusive
                            ? const Color(0xFFFF6F00)
                            : const Color(0xFFE6E2D8),
                        width: isExclusive ? 2 : 1,
                      ),
                      boxShadow: isExclusive
                          ? const [
                              BoxShadow(
                                color:      Color(0x55FF6F00),
                                blurRadius: 14,
                                offset:     Offset(0, 4),
                              ),
                            ]
                          : null,
                    ),
                    padding: const EdgeInsets.all(8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset(
                        path,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: const Color(0xFFEEEAE4),
                          alignment: Alignment.center,
                          child: const Icon(Icons.person_rounded,
                              color: Color(0xFF55534E)),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
