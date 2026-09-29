import 'package:flutter/foundation.dart';

/// Guards every request that goes through YouTube's unofficial internal API
/// (`youtube_explode_dart`: audio-track probes and the custom player).
///
/// That path is what got the app rate-limited before, so it is used as
/// little as possible and shut off fast:
/// - [enabled] is a remote kill switch (the app sets it from its backend);
/// - [trip] opens a circuit breaker after any failure — typically YouTube
///   throttling or blocking — for [cooldown], during which everything plays
///   in the official IFrame player and no unofficial request is made.
///
/// The breaker lives in memory; the host app persists [blockedUntil] (via
/// [onTripped]) and restores it with [restore] so it survives restarts.
class UnofficialYoutubeGate {
  UnofficialYoutubeGate._();

  static const Duration cooldown = Duration(hours: 6);

  /// Remote kill switch. When false, nothing uses the unofficial API.
  static bool enabled = true;

  /// Called with the new block deadline whenever the breaker trips.
  static ValueChanged<DateTime>? onTripped;

  static DateTime? _blockedUntil;

  static DateTime? get blockedUntil => _blockedUntil;

  /// Whether unofficial requests may be made right now.
  static bool get isOpen {
    if (!enabled) return false;
    final until = _blockedUntil;
    return until == null || DateTime.now().isAfter(until);
  }

  /// Stop using the unofficial API for [cooldown].
  static void trip(Object reason) {
    final until = DateTime.now().add(cooldown);
    _blockedUntil = until;
    debugPrint('UnofficialYoutubeGate: tripped until $until ($reason)');
    onTripped?.call(until);
  }

  @visibleForTesting
  static void reset() {
    enabled = true;
    onTripped = null;
    _blockedUntil = null;
  }

  /// Restore a persisted deadline (ignored when it has already passed).
  static void restore(DateTime? until) {
    if (until != null && until.isAfter(DateTime.now())) {
      _blockedUntil = until;
    }
  }
}

/// Thrown instead of making a request while the gate is closed.
class UnofficialYoutubeBlocked implements Exception {
  const UnofficialYoutubeBlocked();

  @override
  String toString() => 'UnofficialYoutubeBlocked';
}
