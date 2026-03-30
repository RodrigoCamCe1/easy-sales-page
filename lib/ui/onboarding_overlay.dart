import 'package:flutter/material.dart';

/// A single step in the onboarding tour.
class OnboardingStep {
  const OnboardingStep({
    required this.key,
    required this.title,
    required this.description,
    this.position = OnboardingPosition.bottom,
  });

  /// GlobalKey of the widget to highlight.
  final GlobalKey key;

  /// Title shown in the tooltip.
  final String title;

  /// Description shown below the title.
  final String description;

  /// Where to show the tooltip relative to the highlighted widget.
  final OnboardingPosition position;
}

enum OnboardingPosition { top, bottom, left, right }

/// Full-screen overlay that darkens everything except the highlighted widget.
class OnboardingOverlay extends StatefulWidget {
  const OnboardingOverlay({
    super.key,
    required this.steps,
    required this.onComplete,
  });

  final List<OnboardingStep> steps;
  final VoidCallback onComplete;

  @override
  State<OnboardingOverlay> createState() => _OnboardingOverlayState();
}

class _OnboardingOverlayState extends State<OnboardingOverlay>
    with SingleTickerProviderStateMixin {
  int _currentStep = 0;
  late AnimationController _animController;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentStep < widget.steps.length - 1) {
      setState(() => _currentStep++);
    } else {
      _finish();
    }
  }

  void _skip() => _finish();

  void _finish() {
    widget.onComplete();
  }

  Rect? _getTargetRect(GlobalKey key) {
    final renderObj = key.currentContext?.findRenderObject();
    if (renderObj is! RenderBox || !renderObj.hasSize) return null;
    final pos = renderObj.localToGlobal(Offset.zero);
    return Rect.fromLTWH(pos.dx, pos.dy, renderObj.size.width, renderObj.size.height);
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_currentStep];
    final targetRect = _getTargetRect(step.key);
    final screenSize = MediaQuery.of(context).size;

    return FadeTransition(
      opacity: _fadeAnim,
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            // Dark overlay with hole
            Positioned.fill(
              child: CustomPaint(
                painter: _SpotlightPainter(
                  targetRect: targetRect,
                  padding: 8,
                ),
              ),
            ),
            // Tap anywhere to advance
            Positioned.fill(
              child: GestureDetector(
                onTap: _next,
                behavior: HitTestBehavior.translucent,
              ),
            ),
            // Tooltip card
            if (targetRect != null)
              _buildTooltip(step, targetRect, screenSize),
          ],
        ),
      ),
    );
  }

  Widget _buildTooltip(OnboardingStep step, Rect targetRect, Size screenSize) {
    const tooltipWidth = 300.0;
    const margin = 12.0;

    double left;
    double top;

    switch (step.position) {
      case OnboardingPosition.bottom:
        left = (targetRect.left + targetRect.width / 2 - tooltipWidth / 2)
            .clamp(margin, screenSize.width - tooltipWidth - margin);
        top = targetRect.bottom + margin;
      case OnboardingPosition.top:
        left = (targetRect.left + targetRect.width / 2 - tooltipWidth / 2)
            .clamp(margin, screenSize.width - tooltipWidth - margin);
        top = targetRect.top - margin - 140;
      case OnboardingPosition.right:
        left = targetRect.right + margin;
        top = targetRect.top;
      case OnboardingPosition.left:
        left = targetRect.left - tooltipWidth - margin;
        top = targetRect.top;
    }

    // Clamp to screen
    top = top.clamp(margin, screenSize.height - 180);
    left = left.clamp(margin, screenSize.width - tooltipWidth - margin);

    return Positioned(
      left: left,
      top: top,
      child: Container(
        width: tooltipWidth,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1D28).withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFF5CB2FF).withValues(alpha: 0.4),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF5CB2FF).withValues(alpha: 0.15),
              blurRadius: 20,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.lightbulb_outline_rounded,
                    color: Color(0xFF5CB2FF), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    step.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              step.description,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 12,
                fontWeight: FontWeight.w400,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_currentStep + 1} / ${widget.steps.length}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    decoration: TextDecoration.none,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_currentStep < widget.steps.length - 1)
                      GestureDetector(
                        onTap: _skip,
                        child: Text(
                          'Saltar',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: _next,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF5CB2FF),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _currentStep < widget.steps.length - 1
                              ? 'Siguiente'
                              : 'Entendido',
                          style: const TextStyle(
                            color: Color(0xFF0B0C10),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints a dark overlay with a rounded-rect cutout around the target.
class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({
    required this.targetRect,
    this.padding = 8,
  });

  final Rect? targetRect;
  final double padding;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.7);

    final fullPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    if (targetRect != null) {
      final holePath = Path()
        ..addRRect(RRect.fromRectAndRadius(
          targetRect!.inflate(padding),
          const Radius.circular(12),
        ));

      final combined = Path.combine(PathOperation.difference, fullPath, holePath);
      canvas.drawPath(combined, paint);
    } else {
      canvas.drawPath(fullPath, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) =>
      targetRect != oldDelegate.targetRect;
}
