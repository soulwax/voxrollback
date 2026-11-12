import 'dart:math' as math;

/// Quantized deterministic frame input packet for a single player slot.
final class RollbackFrameInput {
  final int frame;
  final int playerId;
  final int buttonsMask;
  final int moveXQuantized;
  final int moveYQuantized;
  final int aimXQuantized;
  final int aimYQuantized;
  final int axisScale;
  final bool isPredicted;

  const RollbackFrameInput({
    required this.frame,
    required this.playerId,
    this.buttonsMask = 0,
    this.moveXQuantized = 0,
    this.moveYQuantized = 0,
    this.aimXQuantized = 0,
    this.aimYQuantized = 0,
    this.axisScale = 1000,
    this.isPredicted = false,
  });

  factory RollbackFrameInput.fromAxes({
    required int frame,
    required int playerId,
    int buttonsMask = 0,
    double moveX = 0.0,
    double moveY = 0.0,
    double aimX = 0.0,
    double aimY = 0.0,
    int axisScale = 1000,
    bool isPredicted = false,
  }) =>
      RollbackFrameInput(
        frame: frame,
        playerId: playerId,
        buttonsMask: buttonsMask,
        moveXQuantized: (moveX * axisScale).round(),
        moveYQuantized: (moveY * axisScale).round(),
        aimXQuantized: (aimX * axisScale).round(),
        aimYQuantized: (aimY * axisScale).round(),
        axisScale: axisScale,
        isPredicted: isPredicted,
      );

  double get moveX => moveXQuantized / axisScale;
  double get moveY => moveYQuantized / axisScale;
  double get aimX => aimXQuantized / axisScale;
  double get aimY => aimYQuantized / axisScale;

  bool samePayloadAs(RollbackFrameInput other) =>
      buttonsMask == other.buttonsMask &&
      moveXQuantized == other.moveXQuantized &&
      moveYQuantized == other.moveYQuantized &&
      aimXQuantized == other.aimXQuantized &&
      aimYQuantized == other.aimYQuantized &&
      axisScale == other.axisScale;

  RollbackFrameInput copyForFrame(int targetFrame, {required bool predicted}) =>
      RollbackFrameInput(
        frame: targetFrame,
        playerId: playerId,
        buttonsMask: buttonsMask,
        moveXQuantized: moveXQuantized,
        moveYQuantized: moveYQuantized,
        aimXQuantized: aimXQuantized,
        aimYQuantized: aimYQuantized,
        axisScale: axisScale,
        isPredicted: predicted,
      );
}

/// Fixed-size modulo ring buffer storing confirmed & predicted inputs for one player.
final class InputRingBuffer {
  final int playerId;
  final int capacity;
  final List<RollbackFrameInput?> _slots;

  int _lastConfirmedFrame = -1;
  RollbackFrameInput? _lastConfirmedInput;
  int? _earliestMispredictedFrame;

  InputRingBuffer({
    required this.playerId,
    this.capacity = 256,
  }) : _slots = List<RollbackFrameInput?>.filled(math.max(8, capacity), null);

  int get lastConfirmedFrame => _lastConfirmedFrame;
  int? get earliestMispredictedFrame => _earliestMispredictedFrame;

  RollbackFrameInput? peekFrame(int frame) {
    if (frame < 0) return null;
    final slot = _slots[frame % _slots.length];
    return (slot != null && slot.frame == frame) ? slot : null;
  }

  /// Stores a confirmed input frame, detecting whether any earlier prediction at [input.frame] diverged.
  bool submitConfirmed(RollbackFrameInput input) {
    final idx = input.frame % _slots.length;
    final existing = _slots[idx];
    var diverged = false;
    if (existing != null &&
        existing.frame == input.frame &&
        existing.isPredicted &&
        !existing.samePayloadAs(input)) {
      diverged = true;
      if (_earliestMispredictedFrame == null || input.frame < _earliestMispredictedFrame!) {
        _earliestMispredictedFrame = input.frame;
      }
    }

    final confirmed = input.copyForFrame(input.frame, predicted: false);
    _slots[idx] = confirmed;
    if (input.frame >= _lastConfirmedFrame) {
      _lastConfirmedFrame = input.frame;
      _lastConfirmedInput = confirmed;
    }
    return diverged;
  }

  /// Retrieves confirmed input if present, or synthesizes a repeat-last-input prediction.
  RollbackFrameInput getOrPredict(int frame) {
    final existing = peekFrame(frame);
    if (existing != null) return existing;

    final base = _lastConfirmedInput;
    final predicted = base != null
        ? base.copyForFrame(frame, predicted: true)
        : RollbackFrameInput(
            frame: frame,
            playerId: playerId,
            isPredicted: true,
          );
    _slots[frame % _slots.length] = predicted;
    return predicted;
  }

  int? consumeEarliestMispredictedFrame() {
    final f = _earliestMispredictedFrame;
    _earliestMispredictedFrame = null;
    return f;
  }

  void clearMispredictionFlag() {
    _earliestMispredictedFrame = null;
  }

  void reset() {
    _slots.fillRange(0, _slots.length, null);
    _lastConfirmedFrame = -1;
    _lastConfirmedInput = null;
    _earliestMispredictedFrame = null;
  }
}
