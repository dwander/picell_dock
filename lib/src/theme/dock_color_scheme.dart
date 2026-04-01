import 'package:flutter/material.dart';

/// 독 시스템에서 사용하는 색상 집합.
///
/// 기본값은 PiCell Gruvbox 다크 팔레트. 호스트 앱은 [DockOverlay.colorScheme]으로
/// 재정의한다.
class DockColorScheme {
  // ── 배경 ──
  final Color bg0;
  final Color bg1;
  final Color bg3;
  final Color panelBackground;
  final Color headerOverlay;

  // ── 전경 (텍스트) ──
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color textHint;
  final Color fg3;
  final Color fg4;
  final Color separatorHover;

  // ── 액센트 ──
  final Color accent;
  final Color accentMuted;

  // ── 테두리 ──
  final Color border;
  final Color borderFocused;

  // ── 상호작용 ──
  final Color hover;

  // ── 그림자 ──
  final List<BoxShadow> groupShadow;

  const DockColorScheme({
    this.bg0 = const Color(0xFF1A1A1A),
    this.bg1 = const Color(0xFF222222),
    this.bg3 = const Color(0xFF383838),
    this.panelBackground = const Color(0xFF222222),
    this.headerOverlay = const Color(0xFF1E1E1E),
    this.textPrimary = const Color(0xFFDCDCDC),
    this.textSecondary = const Color(0xFFB0B0B0),
    this.textMuted = const Color(0xFF8A8A8A),
    this.textHint = const Color(0xFF666666),
    this.fg3 = const Color(0xFF8A8A8A),
    this.fg4 = const Color(0xFF666666),
    this.separatorHover = const Color(0xFF606060),
    this.accent = const Color(0xFF6BA3BE),
    this.accentMuted = const Color(0xFF4A7A91),
    this.border = const Color(0xFF353535),
    this.borderFocused = const Color(0xFF4A7A91),
    this.hover = const Color(0x14FFFFFF),
    this.groupShadow = const [
      BoxShadow(
        color: Color(0x40000000),
        blurRadius: 12,
        spreadRadius: 1,
        offset: Offset(0, 4),
      ),
    ],
  });
}
