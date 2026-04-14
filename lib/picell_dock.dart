library picell_dock;

// ── config ──
export 'src/config/dock_config.dart';
export 'src/config/dock_display_settings.dart';
export 'src/config/dock_panel_delegate.dart';
export 'src/config/dock_settings.dart';

// ── models ──
export 'src/models/dock_group.dart';
export 'src/models/dock_node.dart';

// ── services ──
export 'src/services/dock_layout_service.dart' show DockLayoutData;

// ── utils ──
export 'src/utils/dock_free_rect.dart'; // 호스트 앱 image_viewer_free_rect.dart에서 사용

// ── theme ──
export 'src/theme/dock_color_scheme.dart';
export 'src/theme/dock_theme.dart';

// ── widgets ──
export 'src/widgets/border_glow_effect.dart';
export 'src/widgets/border_scan_effect.dart';
export 'src/widgets/edge_dock_effect.dart';
export 'src/widgets/edge_glow_decoration.dart';
export 'src/widgets/panel_zoom_wrapper.dart';

// ── dock ──
export 'src/dock/dock_node_widget.dart';
export 'src/dock/dock_overlay.dart';

// ── providers ──
// dock_provider.dart 가 내부에서 dock_state.dart 를 re-export 하므로
// 배럴에서 dock_state.dart 를 직접 export 하면 이중 export 발생 → 제거.
export 'src/providers/dock_provider.dart';
export 'src/providers/dock_settings_provider.dart';
export 'src/providers/panel_zoom_provider.dart';
