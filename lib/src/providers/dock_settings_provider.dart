import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/dock_settings.dart';

/// 독 시스템 동작 설정 프로바이더.
///
/// 기본값은 모든 옵션 비활성화. 호스트 앱은 [ProviderScope.overrides]로 재정의한다.
///
/// ```dart
/// ProviderScope(
///   overrides: [
///     dockSettingsProvider.overrideWith((ref) {
///       final s = ref.watch(mySettingsProvider);
///       return DockSettings(
///         allowAutoAvoidance: s.allowAutoAvoidance,
///         allowHorizontalPanelDock: s.allowHorizontalPanelDock,
///         isHeaderless: MyPanelRegistry.isHeaderless,
///         defaultLayout: () => myDefaultGroups,
///         initialFocusedPanelId: 'thumbnail',
///       );
///     }),
///   ],
///   child: MyApp(),
/// )
/// ```
final dockSettingsProvider = Provider<DockSettings>(
  (ref) => const DockSettings(),
);
