import 'dart:collection';
import 'dart:math' as math;

import 'input_buffer.dart';

/// Immutable snapshot checkpoint before executing [frame].
final class RollbackSnapshotEntry<S> {
  final int frame;
  final S state;
  final int checksum;

  const RollbackSnapshotEntry({
    required this.frame,
    required this.state,
    required this.checksum,
  });
}

/// Diagnostic summary returned for each simulated or rolled-back tick.
final class RollbackStepReport {
  final int simulatedFrame;
  final bool rolledBack;
  final int? rollbackFromFrame;
  final int resimulatedFrameCount;
  final int checksum;
  final bool desyncDetected;
  final int? desyncFrame;

  const RollbackStepReport({
    required this.simulatedFrame,
    required this.rolledBack,
    this.rollbackFromFrame,
    required this.resimulatedFrameCount,
    required this.checksum,
    required this.desyncDetected,
    this.desyncFrame,
  });
}

/// Deterministic rollback loop orchestrating prediction, rewind/resimulation & checksum verification.
final class DeterministicRollbackSession<S> {
  final int playerCount;
  final int localPlayerId;
  final int maxRollbackFrames;
  int inputDelayFrames;

  final S Function() captureState;
  final void Function(S state) restoreState;
  final void Function(int frame, List<RollbackFrameInput> inputs) stepSimulation;
  final int Function(S state) computeChecksum;

  final List<InputRingBuffer> _buffers;
  final LinkedHashMap<int, RollbackSnapshotEntry<S>> _snapshots = LinkedHashMap<int, RollbackSnapshotEntry<S>>();
  final Map<int, int> _frameChecksums = {};

  int _currentFrame = 0;
  int _remoteReportedFrame = 0;
  int _totalRollbacks = 0;
  int _totalResimulatedFrames = 0;
  int _maxRollbackDepth = 0;
  int? _lastDesyncFrame;

  DeterministicRollbackSession({
    required this.playerCount,
    this.localPlayerId = 0,
    this.maxRollbackFrames = 16,
    this.inputDelayFrames = 1,
    required this.captureState,
    required this.restoreState,
    required this.stepSimulation,
    required this.computeChecksum,
  }) : _buffers = [
          for (var i = 0; i < math.max(1, playerCount); i++)
            InputRingBuffer(
              playerId: i,
              capacity: math.max(64, maxRollbackFrames * 8),
            ),
        ];

  int get currentFrame => _currentFrame;
  int get totalRollbacks => _totalRollbacks;
  int get totalResimulatedFrames => _totalResimulatedFrames;
  int get maxRollbackDepth => _maxRollbackDepth;
  int? get lastDesyncFrame => _lastDesyncFrame;
  bool get desyncDetected => _lastDesyncFrame != null;

  int get confirmedFrame {
    if (_buffers.isEmpty) return _currentFrame - 1;
    var minConfirmed = _buffers.first.lastConfirmedFrame;
    for (var i = 1; i < _buffers.length; i++) {
      minConfirmed = math.min(minConfirmed, _buffers[i].lastConfirmedFrame);
    }
    return minConfirmed;
  }

  /// Frame advantage of local simulation ahead of the latest known remote frame.
  int get frameAdvantage => _currentFrame - _remoteReportedFrame;

  bool get shouldStallForAdvantage => frameAdvantage > math.max(2, maxRollbackFrames ~/ 2);

  int? checksumForFrame(int frame) => _frameChecksums[frame];

  InputRingBuffer bufferForPlayer(int playerId) => _buffers[playerId];

  void _ensureInitialSnapshot() {
    if (_snapshots.isNotEmpty) return;
    final state = captureState();
    _snapshots[0] = RollbackSnapshotEntry<S>(
      frame: 0,
      state: state,
      checksum: computeChecksum(state),
    );
  }

  void _storeSnapshot(int entryFrame, S state, int checksum) {
    _snapshots[entryFrame] = RollbackSnapshotEntry<S>(
      frame: entryFrame,
      state: state,
      checksum: checksum,
    );
    final keepFloor = math.max(0, _currentFrame - maxRollbackFrames - 2);
    while (_snapshots.isNotEmpty && _snapshots.keys.first < keepFloor) {
      _snapshots.remove(_snapshots.keys.first);
    }
    _frameChecksums.removeWhere((frame, _) => frame < keepFloor - maxRollbackFrames);
  }

  /// Records confirmed local player input applying configured [inputDelayFrames].
  void submitLocalInput(
    RollbackFrameInput input, {
    int? overrideTargetFrame,
  }) {
    final targetFrame = overrideTargetFrame ?? (_currentFrame + math.max(0, inputDelayFrames));
    _buffers[localPlayerId].submitConfirmed(
      input.copyForFrame(targetFrame, predicted: false),
    );
  }

  /// Ingests confirmed remote player input and returns true if it invalidated a prior prediction.
  bool receiveRemoteInput(RollbackFrameInput input) {
    if (input.playerId < 0 || input.playerId >= _buffers.length) {
      throw RangeError.index(input.playerId, _buffers, 'playerId');
    }
    if (input.frame > _remoteReportedFrame) {
      _remoteReportedFrame = input.frame;
    }
    return _buffers[input.playerId].submitConfirmed(input);
  }

  void updateRemoteFrame(int remoteFrame) {
    if (remoteFrame > _remoteReportedFrame) {
      _remoteReportedFrame = remoteFrame;
    }
  }

  /// Compares local post-step checksum for [frame] against [remoteChecksum].
  /// Returns `true` if matching or unavailable, `false` if a determinism desync was detected.
  bool receiveRemoteChecksum(int frame, int remoteChecksum) {
    final local = _frameChecksums[frame];
    if (local == null) return true;
    if (local != remoteChecksum) {
      _lastDesyncFrame ??= frame;
      return false;
    }
    return true;
  }

  /// Rewinds and re-simulates from the earliest mispredicted frame up to [currentFrame - 1], if needed.
  RollbackStepReport processPendingRollback() {
    _ensureInitialSnapshot();
    int? earliest;
    for (final buf in _buffers) {
      final f = buf.consumeEarliestMispredictedFrame();
      if (f != null && f < _currentFrame) {
        if (earliest == null || f < earliest) {
          earliest = f;
        }
      }
    }

    if (earliest == null || _snapshots.isEmpty) {
      final latestChecksum =
          _currentFrame > 0 ? (_frameChecksums[_currentFrame - 1] ?? _snapshots.values.last.checksum) : _snapshots.values.last.checksum;
      return RollbackStepReport(
        simulatedFrame: _currentFrame - 1,
        rolledBack: false,
        resimulatedFrameCount: 0,
        checksum: latestChecksum,
        desyncDetected: desyncDetected,
        desyncFrame: _lastDesyncFrame,
      );
    }

    final oldestStoredFrame = _snapshots.keys.first;
    final startFrame = math.max(oldestStoredFrame, earliest);
    final entrySnap = _snapshots[startFrame];
    if (entrySnap == null) {
      return RollbackStepReport(
        simulatedFrame: _currentFrame - 1,
        rolledBack: false,
        resimulatedFrameCount: 0,
        checksum: _frameChecksums[_currentFrame - 1] ?? 0,
        desyncDetected: desyncDetected,
        desyncFrame: _lastDesyncFrame,
      );
    }

    restoreState(entrySnap.state);
    var resimCount = 0;
    var lastChecksum = entrySnap.checksum;
    for (var f = startFrame; f < _currentFrame; f++) {
      final frameInputs = [for (final buf in _buffers) buf.getOrPredict(f)];
      stepSimulation(f, frameInputs);
      final postState = captureState();
      lastChecksum = computeChecksum(postState);
      _frameChecksums[f] = lastChecksum;
      _storeSnapshot(f + 1, postState, lastChecksum);
      resimCount++;
    }

    _totalRollbacks++;
    _totalResimulatedFrames += resimCount;
    if (resimCount > _maxRollbackDepth) {
      _maxRollbackDepth = resimCount;
    }

    return RollbackStepReport(
      simulatedFrame: _currentFrame - 1,
      rolledBack: true,
      rollbackFromFrame: startFrame,
      resimulatedFrameCount: resimCount,
      checksum: lastChecksum,
      desyncDetected: desyncDetected,
      desyncFrame: _lastDesyncFrame,
    );
  }

  /// Processes any pending mispredictions and advances simulation by 1 deterministic frame.
  RollbackStepReport advanceFrame() {
    _ensureInitialSnapshot();
    final rb = processPendingRollback();

    final frame = _currentFrame;
    final frameInputs = [for (final buf in _buffers) buf.getOrPredict(frame)];
    stepSimulation(frame, frameInputs);
    final postState = captureState();
    final checksum = computeChecksum(postState);
    _frameChecksums[frame] = checksum;
    _currentFrame = frame + 1;
    _storeSnapshot(_currentFrame, postState, checksum);

    return RollbackStepReport(
      simulatedFrame: frame,
      rolledBack: rb.rolledBack,
      rollbackFromFrame: rb.rollbackFromFrame,
      resimulatedFrameCount: rb.resimulatedFrameCount,
      checksum: checksum,
      desyncDetected: desyncDetected,
      desyncFrame: _lastDesyncFrame,
    );
  }

  void reset() {
    for (final b in _buffers) {
      b.reset();
    }
    _snapshots.clear();
    _frameChecksums.clear();
    _currentFrame = 0;
    _remoteReportedFrame = 0;
    _totalRollbacks = 0;
    _totalResimulatedFrames = 0;
    _maxRollbackDepth = 0;
    _lastDesyncFrame = null;
  }
}
