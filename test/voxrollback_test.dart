import 'package:test/test.dart';
import 'package:voxrollback/voxrollback.dart';

final class _FighterState {
  double p0x;
  double p1x;
  int hitCount;

  _FighterState(this.p0x, this.p1x, this.hitCount);

  _FighterState copy() => _FighterState(p0x, p1x, hitCount);
}

DeterministicRollbackSession<_FighterState> _buildSession(_FighterState sim, {int delay = 0}) {
  return DeterministicRollbackSession<_FighterState>(
    playerCount: 2,
    localPlayerId: 0,
    inputDelayFrames: delay,
    maxRollbackFrames: 16,
    captureState: () => sim.copy(),
    restoreState: (s) {
      sim.p0x = s.p0x;
      sim.p1x = s.p1x;
      sim.hitCount = s.hitCount;
    },
    stepSimulation: (frame, inputs) {
      sim.p0x += inputs[0].moveX * 0.25;
      sim.p1x += inputs[1].moveX * 0.25;
      if ((inputs[0].buttonsMask & 1) != 0 && (sim.p0x - sim.p1x).abs() < 2.0) {
        sim.hitCount++;
      }
    },
    computeChecksum: (s) {
      final c = StateChecksum()
        ..addQuantizedDouble(s.p0x)
        ..addQuantizedDouble(s.p1x)
        ..addInt32(s.hitCount);
      return c.finalize();
    },
  );
}

void main() {
  test('StateChecksum produces bit-identical deterministic hashes and detects quantized deltas', () {
    final a = StateChecksum()
      ..addInt32(42)
      ..addBool(true)
      ..addQuantizedDouble(12.345)
      ..addString('fighter_0');
    final b = StateChecksum()
      ..addInt32(42)
      ..addBool(true)
      ..addQuantizedDouble(12.345)
      ..addString('fighter_0');
    final c = StateChecksum()
      ..addInt32(42)
      ..addBool(true)
      ..addQuantizedDouble(12.355)
      ..addString('fighter_0');

    expect(a.finalize(), b.finalize());
    expect(a.finalize(), isNot(c.finalize()));
  });

  test('DeterministicRollbackSession rewinds and converges checksum with zero drift after late remote input', () {
    final authState = _FighterState(0.0, 1.0, 0);
    final auth = _buildSession(authState);

    final predState = _FighterState(0.0, 1.0, 0);
    final peerA = _buildSession(predState);

    // Frames 0..3: P0 moves right (+1.0), P1 actually reversed left (-1.0) at frame 1 and punched at frame 2
    for (var f = 0; f < 4; f++) {
      final p0In = RollbackFrameInput.fromAxes(frame: f, playerId: 0, moveX: 1.0, buttonsMask: f == 2 ? 1 : 0);
      final p1True = RollbackFrameInput.fromAxes(
        frame: f,
        playerId: 1,
        moveX: f == 0 ? 0.0 : -1.0,
      );
      auth.submitLocalInput(p0In, overrideTargetFrame: f);
      auth.receiveRemoteInput(p1True);
      auth.advanceFrame();

      peerA.submitLocalInput(p0In, overrideTargetFrame: f);
      if (f == 0) {
        peerA.receiveRemoteInput(p1True);
      }
      // Frames 1..3 initially missing P1 input -> predicted as repeat 0.0
      peerA.advanceFrame();
    }

    // Before rollback, PeerA predicted wrong state vs authoritative run
    expect(peerA.checksumForFrame(3), isNot(auth.checksumForFrame(3)));

    // Late arrival of remote P1 frames 1..3
    expect(
      peerA.receiveRemoteInput(RollbackFrameInput.fromAxes(frame: 1, playerId: 1, moveX: -1.0)),
      isTrue,
    );
    expect(
      peerA.receiveRemoteInput(RollbackFrameInput.fromAxes(frame: 2, playerId: 1, moveX: -1.0)),
      isTrue,
    );
    expect(
      peerA.receiveRemoteInput(RollbackFrameInput.fromAxes(frame: 3, playerId: 1, moveX: -1.0)),
      isTrue,
    );

    final rb = peerA.processPendingRollback();
    expect(rb.rolledBack, isTrue);
    expect(rb.rollbackFromFrame, 1);
    expect(rb.resimulatedFrameCount, 3);
    expect(peerA.totalRollbacks, 1);

    // State & checksum after rollback match authoritative run bit-for-bit!
    expect(predState.p0x, closeTo(authState.p0x, 1e-9));
    expect(predState.p1x, closeTo(authState.p1x, 1e-9));
    expect(predState.hitCount, authState.hitCount);
    expect(peerA.checksumForFrame(3), auth.checksumForFrame(3));
    expect(peerA.receiveRemoteChecksum(3, auth.checksumForFrame(3)!), isTrue);
  });

  test('DeterministicRollbackSession flags checksum desync and frame advantage throttling', () {
    final sim = _FighterState(0.0, 2.0, 0);
    final session = _buildSession(sim, delay: 1);

    for (var i = 0; i < 10; i++) {
      session.advanceFrame();
    }
    expect(session.shouldStallForAdvantage, isTrue);

    final validHash = session.checksumForFrame(9)!;
    expect(session.receiveRemoteChecksum(9, validHash ^ 0x1), isFalse);
    expect(session.desyncDetected, isTrue);
    expect(session.lastDesyncFrame, 9);
  });
}
