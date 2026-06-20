// lib/views/auth_screen.dart
//
// Authentication gate — Sign In / Create Account wired to Supabase Auth.
//
// Sign Up flow:
//   1. supabase.auth.signUp()           — creates auth.users row
//   2. upsert into `profiles` table     — maps uid → email + handle
//   3a. If session returned immediately  → call onLoginSuccess
//   3b. If email confirmation required  → show dialog, redirect to Login tab
//
// Sign In flow:
//   1. supabase.auth.signInWithPassword()
//   2. Fetch handle from `profiles` table (falls back to user_metadata)
//   3. Call onLoginSuccess with hydrated UserProfile
//
// Forgot password:
//   Reads the email field and calls auth.resetPasswordForEmail().

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user_profile.dart';

// Convenience shorthand
final _supabase = Supabase.instance.client;

// =============================================================================
// AuthScreen
// =============================================================================

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.onLoginSuccess});

  final void Function(UserProfile profile) onLoginSuccess;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

enum _AuthMode { login, create }

class _AuthScreenState extends State<AuthScreen> {
  final _formKey            = GlobalKey<FormState>();
  final _emailController    = TextEditingController();
  final _passwordController = TextEditingController();
  final _handleController   = TextEditingController();

  _AuthMode _mode            = _AuthMode.login;
  bool      _obscurePassword = true;
  bool      _loading         = false;
  String?   _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _handleController.dispose();
    super.dispose();
  }

  // ── Router ───────────────────────────────────────────────────────────────────

  Future<void> _handleAuth() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading      = true;
      _errorMessage = null;
    });

    try {
      if (_mode == _AuthMode.create) {
        await _signUp();
      } else {
        await _signIn();
      }
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _loading      = false;
          _errorMessage = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading      = false;
          _errorMessage = 'Something went wrong. Please check your connection and try again.';
        });
      }
    }
  }

  // ── Sign Up ──────────────────────────────────────────────────────────────────

  Future<void> _signUp() async {
    final email    = _emailController.text.trim();
    final password = _passwordController.text;
    final handle   = _handleController.text
        .trim()
        .replaceFirst(RegExp(r'^@'), '');

    // ── Pre-flight: username duplication guard ───────────────────────────────
    // Case-insensitive existence check on the `profiles.username` column
    // (which is backed by a unique lowercase index server-side). Bail BEFORE
    // calling auth.signUp so we don't orphan an auth.users row when the
    // username collides.
    if (handle.isNotEmpty) {
      try {
        final existing = await _supabase
            .from('profiles')
            .select('username')
            .ilike('username', handle)
            .maybeSingle();
        if (existing != null) {
          if (!mounted) return;
          setState(() {
            _loading      = false;
            _errorMessage =
                'Eish! That username is already claimed, chom. Try another one!';
          });
          return;
        }
      } catch (_) {
        // If the lookup itself fails (network blip, missing column on legacy
        // schema), fall through to auth.signUp — the unique index will
        // surface the same error if there's a real collision.
      }
    }

    final res = await _supabase.auth.signUp(
      email:    email,
      password: password,
      data: {'handle': handle},   // stored in auth.users.raw_user_meta_data
      emailRedirectTo: 'io.supabase.chowsa://login-callback/',
    );

    if (!mounted) return;

    if (res.user == null) {
      setState(() {
        _loading      = false;
        _errorMessage = 'Sign up failed. Please try again.';
      });
      return;
    }

    // ── Supabase requires email confirmation (default) ───────────────────────
    if (res.session == null) {
      setState(() => _loading = false);
      _showEmailConfirmationDialog();
      return;
    }

    // ── Email confirmation disabled — user is signed in immediately ──────────
    await _upsertProfile(res.user!.id, email, handle);

    if (!mounted) return;
    setState(() => _loading = false);
    widget.onLoginSuccess(
      UserProfile(id: res.user!.id, email: email, handle: handle),
    );
  }

  // ── Sign In ──────────────────────────────────────────────────────────────────

  Future<void> _signIn() async {
    final email    = _emailController.text.trim();
    final password = _passwordController.text;

    final res = await _supabase.auth.signInWithPassword(
      email:    email,
      password: password,
    );

    if (!mounted) return;

    final user = res.user;
    if (user == null) {
      setState(() {
        _loading      = false;
        _errorMessage = 'Sign in failed. Please try again.';
      });
      return;
    }

    // ── Fetch the display handle from the profiles table ─────────────────────
    // Falls back to user_metadata (set at sign-up) then to the email prefix.
    String handle = user.userMetadata?['handle'] as String? ??
        email.split('@').first;

    try {
      final row = await _supabase
          .from('profiles')
          .select('handle')
          .eq('id', user.id)
          .maybeSingle();
      if (row != null && (row['handle'] as String?)?.isNotEmpty == true) {
        handle = row['handle'] as String;
      }
    } catch (_) {
      // Non-fatal — metadata fallback is acceptable
    }

    if (!mounted) return;
    setState(() => _loading = false);
    widget.onLoginSuccess(
      UserProfile(id: user.id, email: user.email ?? email, handle: handle),
    );
  }

  // ── Upsert profile row ────────────────────────────────────────────────────────

  Future<void> _upsertProfile(
      String id, String email, String handle) async {
    try {
      await _supabase.from('profiles').upsert({
        'id':         id,
        'email':      email,
        'handle':     handle,
        // Mirror handle into `username` so BOTH lookup branches in
        // find_user_by_handle() can resolve this user — same intent as the
        // on_auth_user_created DB trigger, this just keeps the client and
        // the server in sync when the trigger has already populated the row.
        'username':   handle,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      // Non-fatal — a DB trigger may have already created the row,
      // or RLS prevents the upsert before email confirmation.
    }
  }

  // ── Forgot password ───────────────────────────────────────────────────────────

  Future<void> _handleForgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() =>
          _errorMessage = 'Enter your email address in the field above first.');
      return;
    }

    setState(() { _loading = true; _errorMessage = null; });

    try {
      await _supabase.auth.resetPasswordForEmail(email);
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Password reset link sent to $email'),
            backgroundColor: const Color(0xFF0C351E),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) setState(() { _loading = false; _errorMessage = e.message; });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading      = false;
          _errorMessage = 'Could not send reset email. Please try again.';
        });
      }
    }
  }

  // ── Email confirmation dialog ─────────────────────────────────────────────────

  void _showEmailConfirmationDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color:        const Color(0xFF0C351E).withAlpha(20),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.mark_email_unread_outlined,
                  color: Color(0xFF0C351E)),
            ),
            const SizedBox(width: 12),
            const Text('Check your email',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "We've sent a confirmation link to:",
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 6),
            Text(
              _emailController.text.trim(),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              'Click the link to activate your account, then return here and log in.',
              style: TextStyle(color: Colors.grey.shade600, height: 1.5),
            ),
          ],
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0C351E),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              Navigator.pop(context);
              setState(() => _mode = _AuthMode.login);
            },
            child: const Text('Go to Login'),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: _kAuthBgDeep,
      // Theme-aware ambient gradient so the screen reads as a continuous
      // dark backdrop end-to-end (matches the splash treatment).
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.6),
            radius: 1.4,
            colors: [_kAuthBgGlow, _kAuthBgDeep],
            stops:  [0.0, 0.75],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              top:    topPad > 0 ? 0 : 16,
              bottom: bottom + 24,
            ),
            child: Column(
              children: [
                const SizedBox(height: 32),
                const _BrandBadge(),
                const SizedBox(height: 22),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _AuthCard(
                    formKey:            _formKey,
                    emailController:    _emailController,
                    passwordController: _passwordController,
                    handleController:   _handleController,
                    mode:               _mode,
                    obscurePassword:    _obscurePassword,
                    loading:            _loading,
                    errorMessage:       _errorMessage,
                    onModeChanged: (m) => setState(() {
                      _mode         = m;
                      _errorMessage = null;
                    }),
                    onToggleObscure:    () => setState(() => _obscurePassword = !_obscurePassword),
                    onSubmit:           _handleAuth,
                    onForgotPassword:   _handleForgotPassword,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Brand palette ─────────────────────────────────────────────────────────
// Cool slate-blue background matched to the latest sign-in mock — pulls
// the visual weight off the warm ember scheme and lets the orange CTA
// pop harder. All text colours were bumped toward pure white so the
// copy reads cleanly against the cooler backdrop (the previous warm-
// brown hint colours looked dim on this background).

const _kAuthBgDeep   = Color(0xFF1B2730);  // slate base
const _kAuthBgGlow   = Color(0xFF2C3D49);  // lifted slate near the badge
const _kAccentMango  = Color(0xFFFFB347);  // soft mango highlight
const _kAccentOrange = Color(0xFFFF6B2C);  // sunset orange CTA
const _kFieldFill    = Color(0x1AFFFFFF);  // translucent white field fill
const _kFieldBorder  = Color(0xFFFF8A45);  // bright orange outline
const _kHintText     = Color(0xFFE8ECEF);  // near-white hint text
const _kBodyText     = Color(0xFFF5F7F9);  // near-white body copy
const _kTaglineText  = Color(0xFFD0D6DB);  // soft-white subtitle

// =============================================================================
// _BrandBadge — flame logo + wordmark + tagline (splash-style)
// =============================================================================

class _BrandBadge extends StatelessWidget {
  const _BrandBadge();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Flame badge — orange-filled rounded square with glow halo
        Container(
          width: 88, height: 88,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin:  Alignment.topLeft,
              end:    Alignment.bottomRight,
              colors: [_kAccentMango, _kAccentOrange],
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color:        _kAccentMango.withValues(alpha: 0.55),
                blurRadius:   28,
                spreadRadius: 2,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.local_fire_department_rounded,
            color: Colors.white,
            size:  46,
          ),
        ),
        const SizedBox(height: 18),
        // Wordmark — "Chow" white + "SA" mango
        RichText(
          text: const TextSpan(
            style: TextStyle(
              fontSize:      40,
              fontWeight:    FontWeight.w900,
              letterSpacing: -0.5,
              height:        1.0,
            ),
            children: [
              TextSpan(text: 'Chow', style: TextStyle(color: Colors.white)),
              TextSpan(text: 'SA',   style: TextStyle(color: _kAccentMango)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Your South African kitchen, powered by AI.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color:      _kTaglineText,
            fontSize:   13.5,
            fontWeight: FontWeight.w600,
            height:     1.4,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// _AuthCard — dark-mode login / create-account card
// =============================================================================

class _AuthCard extends StatelessWidget {
  const _AuthCard({
    required this.formKey,
    required this.emailController,
    required this.passwordController,
    required this.handleController,
    required this.mode,
    required this.obscurePassword,
    required this.loading,
    required this.errorMessage,
    required this.onModeChanged,
    required this.onToggleObscure,
    required this.onSubmit,
    required this.onForgotPassword,
  });

  final GlobalKey<FormState>     formKey;
  final TextEditingController    emailController;
  final TextEditingController    passwordController;
  final TextEditingController    handleController;
  final _AuthMode                mode;
  final bool                     obscurePassword;
  final bool                     loading;
  final String?                  errorMessage;
  final void Function(_AuthMode) onModeChanged;
  final VoidCallback             onToggleObscure;
  final VoidCallback             onSubmit;
  final VoidCallback             onForgotPassword;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [

          // ── Mode toggle (Login / Create Account pill) ─────────────────────
          _AuthModeToggle(
            mode:    mode,
            onMode:  onModeChanged,
          ),

          const SizedBox(height: 22),

          // ── Email ─────────────────────────────────────────────────────────
          _AuthField(
            controller:      emailController,
            hint:            'Email address',
            icon:            Icons.email_outlined,
            keyboardType:    TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'Please enter your email.';
              }
              if (!v.contains('@')) return 'Enter a valid email address.';
              return null;
            },
          ),
          const SizedBox(height: 14),

          // ── Password ──────────────────────────────────────────────────────
          _AuthField(
            controller:      passwordController,
            hint:            'Password',
            icon:            Icons.lock_outline_rounded,
            obscureText:     obscurePassword,
            textInputAction: mode == _AuthMode.create
                ? TextInputAction.next
                : TextInputAction.done,
            suffix: IconButton(
              icon: Icon(
                obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: _kHintText.withValues(alpha: 0.75),
                size:  20,
              ),
              onPressed: onToggleObscure,
              tooltip: obscurePassword ? 'Show password' : 'Hide password',
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Please enter your password.';
              if (mode == _AuthMode.create && v.length < 6) {
                return 'Password must be at least 6 characters.';
              }
              return null;
            },
          ),

          // ── Handle (create-account only) ──────────────────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve:    Curves.easeInOut,
            child: mode == _AuthMode.create
                ? Column(
                    children: [
                      const SizedBox(height: 14),
                      _AuthField(
                        controller:      handleController,
                        hint:            'Display handle (e.g. BraaiMasterJan)',
                        icon:            Icons.alternate_email_rounded,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => onSubmit(),
                        validator: (v) {
                          if (v == null ||
                              v.replaceFirst(RegExp(r'^@'), '').trim().isEmpty) {
                            return 'Please choose a display handle.';
                          }
                          final clean =
                              v.replaceFirst(RegExp(r'^@'), '').trim();
                          if (clean.contains(' ')) {
                            return 'No spaces — try BraaiMasterJan.';
                          }
                          return null;
                        },
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),

          // ── Error banner ──────────────────────────────────────────────────
          if (errorMessage != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:        const Color(0x33C62828),
                borderRadius: BorderRadius.circular(12),
                border:       Border.all(
                  color: const Color(0xFFFF6B6B).withValues(alpha: 0.45),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded,
                      color: Color(0xFFFF9E9E), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      errorMessage!,
                      style: const TextStyle(
                        color:    Color(0xFFFFC9C9),
                        fontSize: 12.5,
                        height:   1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 22),

          // ── Submit — sleek pill with smooth tap scale ─────────────────────
          _PillCta(
            loading: loading,
            label:   mode == _AuthMode.login ? 'Login' : 'Create Account',
            onTap:   loading ? null : onSubmit,
          ),

          // ── Forgot password (login mode only) ─────────────────────────────
          if (mode == _AuthMode.login) ...[
            const SizedBox(height: 12),
            Center(
              child: TextButton(
                onPressed: loading ? null : onForgotPassword,
                style: TextButton.styleFrom(
                  foregroundColor: _kAccentMango,
                  textStyle: const TextStyle(
                    fontWeight:    FontWeight.w700,
                    letterSpacing: 0.1,
                  ),
                ),
                child: const Text('Forgot password?'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── _AuthModeToggle ──────────────────────────────────────────────────────────

class _AuthModeToggle extends StatelessWidget {
  const _AuthModeToggle({required this.mode, required this.onMode});

  final _AuthMode                mode;
  final void Function(_AuthMode) onMode;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color:        _kFieldFill,
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: _kFieldBorder),
      ),
      child: Row(
        children: [
          Expanded(child: _ModeTab(
            label:    'Login',
            selected: mode == _AuthMode.login,
            onTap:    () => onMode(_AuthMode.login),
          )),
          Expanded(child: _ModeTab(
            label:    'Create Account',
            selected: mode == _AuthMode.create,
            onTap:    () => onMode(_AuthMode.create),
          )),
        ],
      ),
    );
  }
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String       label;
  final bool         selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve:    Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  colors: [_kAccentMango, _kAccentOrange],
                )
              : null,
          borderRadius: BorderRadius.circular(10),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color:      _kAccentMango.withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset:     const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color:      selected ? Colors.white : _kHintText,
            fontWeight: FontWeight.w800,
            fontSize:   13.5,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

// ── _AuthField — borderless dark text field ───────────────────────────────

class _AuthField extends StatelessWidget {
  const _AuthField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscureText      = false,
    this.keyboardType,
    this.textInputAction,
    this.suffix,
    this.validator,
    this.onFieldSubmitted,
  });

  final TextEditingController controller;
  final String                hint;
  final IconData              icon;
  final bool                  obscureText;
  final TextInputType?        keyboardType;
  final TextInputAction?      textInputAction;
  final Widget?               suffix;
  final String? Function(String?)? validator;
  final void Function(String)? onFieldSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller:        controller,
      obscureText:       obscureText,
      keyboardType:      keyboardType,
      textInputAction:   textInputAction,
      onFieldSubmitted:  onFieldSubmitted,
      cursorColor:       _kAccentMango,
      style: const TextStyle(
        color:      _kBodyText,
        fontSize:   15,
        fontWeight: FontWeight.w700,
      ),
      validator: validator,
      decoration: InputDecoration(
        hintText:   hint,
        hintStyle:  const TextStyle(
          color:      _kHintText,
          fontWeight: FontWeight.w500,
          fontSize:   13.5,
        ),
        prefixIcon: Icon(icon, color: _kAccentMango, size: 19),
        suffixIcon: suffix,
        filled:     true,
        fillColor:  _kFieldFill,
        isDense:    true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        // Borderless — single muted ember border, mango focus highlight
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   const BorderSide(color: _kFieldBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   const BorderSide(color: _kAccentMango, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   const BorderSide(color: Color(0xFFFF6B6B)),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   const BorderSide(color: Color(0xFFFF6B6B), width: 1.4),
        ),
        errorStyle: const TextStyle(
          color:    Color(0xFFFFC9C9),
          fontSize: 11.5,
        ),
      ),
    );
  }
}

// ── _PillCta — premium mango pill button with smooth tap scale ────────────

class _PillCta extends StatefulWidget {
  const _PillCta({
    required this.label,
    required this.loading,
    required this.onTap,
  });

  final String         label;
  final bool           loading;
  final VoidCallback?  onTap;

  @override
  State<_PillCta> createState() => _PillCtaState();
}

class _PillCtaState extends State<_PillCta> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return GestureDetector(
      onTapDown:   disabled ? null : (_) => setState(() => _pressed = true),
      onTapUp:     disabled ? null : (_) => setState(() => _pressed = false),
      onTapCancel: disabled ? null : ()  => setState(() => _pressed = false),
      onTap:       widget.onTap,
      child: AnimatedScale(
        scale:    _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve:    Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height:   54,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin:  Alignment.topLeft,
              end:    Alignment.bottomRight,
              colors: disabled
                  ? [
                      _kAccentMango.withValues(alpha: 0.45),
                      _kAccentOrange.withValues(alpha: 0.45),
                    ]
                  : const [_kAccentMango, _kAccentOrange],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: disabled
                ? null
                : [
                    BoxShadow(
                      color:      _kAccentMango.withValues(alpha: 0.45),
                      blurRadius: 18,
                      offset:     const Offset(0, 6),
                    ),
                  ],
          ),
          alignment: Alignment.center,
          child: widget.loading
              ? const SizedBox(
                  width: 22, height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: Colors.white,
                  ),
                )
              : Text(
                  widget.label,
                  style: const TextStyle(
                    color:         Colors.white,
                    fontSize:      16,
                    fontWeight:    FontWeight.w900,
                    letterSpacing: 0.4,
                  ),
                ),
        ),
      ),
    );
  }
}
