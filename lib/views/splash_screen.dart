// lib/views/splash_screen.dart

import 'package:flutter/material.dart';
import 'package:dotlottie_loader/dotlottie_loader.dart';
import 'package:lottie/lottie.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onComplete});
  final VoidCallback onComplete;
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {

  late final AnimationController _fadeInCtrl = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 600), value: 0,
  );
  late final AnimationController _fadeOutCtrl = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 500), value: 1,
  );

  @override
  void initState() {
    super.initState();
    _fadeInCtrl.forward();
    Future.delayed(const Duration(milliseconds: 2800), _dismiss);
  }

  Future<void> _dismiss() async {
    await _fadeOutCtrl.animateTo(0.0,
        duration: const Duration(milliseconds: 500), curve: Curves.easeOut);
    if (mounted) widget.onComplete();
  }

  @override
  void dispose() {
    _fadeInCtrl.dispose();
    _fadeOutCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final w = MediaQuery.of(context).size.width;

    return AnimatedBuilder(
      animation: Listenable.merge([_fadeInCtrl, _fadeOutCtrl]),
      builder: (_, child) => Opacity(
        opacity: _fadeInCtrl.value * _fadeOutCtrl.value,
        child: child,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.expand(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ── Full-bleed hero image ──────────────────────────────────
              Image.asset(
                'assets/images/splash_bg.png',
                fit: BoxFit.cover,
                width: w, height: h,
              ),

              // ── Fire Lottie — measured directly from image pixels ──────
              // Image is 853x1844px.
              // "What's cooking SA?" text:
              //   vertical centre  ≈ row 963  → 963/1844 = 52.2% from top
              //   rightmost pixel  ≈ col 590  → 590/853  = 69.2% from left
              // Fire sits flush right of the text, vertically centred on it.
              // Size 44px — subtract half (22px) to vertically centre on text.
              Positioned(
                top:  h * 0.522 - 22,
                left: w * 0.692,
                child: SizedBox(
                  width:  44,
                  height: 44,
                  child: DotLottieLoader.fromAsset(
                    'assets/images/fire.lottie',
                    frameBuilder: (ctx, dotlottie) {
                      if (dotlottie != null) {
                        return Lottie.memory(
                          dotlottie.animations.values.single,
                          repeat: true,
                          fit:    BoxFit.contain,
                        );
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ),

              // ── Cover the static spinner baked into splash_bg.png ─────
              // The PNG has a hardcoded loading circle near the bottom centre.
              // We paint a black rectangle over it so it's invisible.
              Positioned(
                bottom: h * 0.03,
                left:   w * 0.3,
                right:  w * 0.3,
                height: h * 0.07,
                child: Container(color: Colors.black),
              ),

            ],
          ),
        ),
      ),
    );
  }
}
