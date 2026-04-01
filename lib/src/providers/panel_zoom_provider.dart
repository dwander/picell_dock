import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 확대 단계 목록 (배율)
const List<double> panelZoomLevels = [0.85, 1.0, 1.15, 1.3];

/// 패널별 텍스트/아이콘 확대 배율 (panelId → 배율, 기본값 1.0)
final panelZoomProvider =
    NotifierProvider<PanelZoomNotifier, Map<String, double>>(
  PanelZoomNotifier.new,
);

class PanelZoomNotifier extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => const {};

  /// [panelId]의 현재 배율 반환 (미설정 시 1.0)
  double getZoom(String panelId) => state[panelId] ?? 1.0;

  void setZoom(String panelId, double zoom) {
    state = {...state, panelId: zoom};
  }
}
