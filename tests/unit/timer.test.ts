import {
  initialTimerState,
  start,
  pause,
  reset,
  tick,
  formatClock,
  ringProgress,
  loadTimerState,
  saveTimerState,
  WORK_SECONDS,
  BREAK_SECONDS,
  type TimerState,
} from "../../src/scripts/timer";

const NOW = 1_000_000_000_000;

const memoryStorage = (): Storage => {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
    removeItem: (k: string) => void map.delete(k),
    clear: () => map.clear(),
    key: () => null,
    get length() {
      return map.size;
    },
  } as unknown as Storage;
};

function runningWork(remainingMs: number): TimerState {
  return { ...initialTimerState(), running: true, endsAt: NOW + remainingMs };
}

describe("timer transitions", () => {
  test("start sets deadline based on remaining time", () => {
    const s = { ...initialTimerState(), remaining: 300 };
    const started = start(s, NOW);
    expect(started.running).toBe(true);
    expect(started.endsAt).toBe(NOW + 300_000);
    expect(s.running).toBe(false);
  });

  test("start is idempotent while running", () => {
    const s = runningWork(60_000);
    expect(start(s, NOW)).toBe(s);
  });

  test("pause converts remaining deadline into seconds", () => {
    const paused = pause(runningWork(41_000), NOW);
    expect(paused.running).toBe(false);
    expect(paused.remaining).toBe(41);
    expect(paused.endsAt).toBeNull();
  });

  test("pause on a stopped timer keeps remaining untouched", () => {
    const s = { ...initialTimerState(), remaining: 777 };
    expect(pause(s, NOW)).toMatchObject({ running: false, remaining: 777 });
  });

  test("reset restores full phase length and keeps cycles", () => {
    const s = { ...runningWork(0), cycles: 4 };
    const r = reset({ ...s, remaining: 3 });
    expect(r.remaining).toBe(WORK_SECONDS);
    expect(r.cycles).toBe(4);
    expect(r.running).toBe(false);
  });

  test("reset after phase flip uses the new phase's duration", () => {
    const s: TimerState = { ...initialTimerState(), phase: "break" };
    expect(reset(s).remaining).toBe(BREAK_SECONDS);
  });
});

describe("tick roll-forward", () => {
  test("no-op when not running", () => {
    const s = initialTimerState();
    const result = tick(s, NOW + 999_999_000);
    expect(result.state).toEqual(s);
    expect(result.completedPhase).toBe(false);
  });

  test("work -> break transition increments cycles", () => {
    const result = tick(runningWork(-1), NOW);
    expect(result.state.phase).toBe("break");
    expect(result.state.cycles).toBe(1);
    expect(result.completedPhase).toBe(true);
  });

  test("break -> work transition does not double count", () => {
    const s: TimerState = {
      running: true,
      phase: "break",
      endsAt: NOW - 1000,
      remaining: 1,
      cycles: 2,
      chime: false,
    };
    const result = tick(s, NOW);
    expect(result.state.phase).toBe("work");
    expect(result.state.cycles).toBe(2);
  });

  test("missed phases collapse without runaway loops", () => {
    const result = tick(runningWork(-10 * 3600_000), NOW);
    expect(result.completedPhase).toBe(true);
    expect(result.state.endsAt).toBeGreaterThan(NOW);
    expect(result.state.cycles).toBeLessThan(200);
  });

  test("future deadline recomputes remaining", () => {
    const result = tick(runningWork(59_500), NOW);
    expect(result.completedPhase).toBe(false);
    expect(result.state.remaining).toBe(60);
  });
});

describe("formatting & rings", () => {
  test.each([
    [0, "00:00"],
    [20, "00:20"],
    [599, "09:59"],
    [1200, "20:00"],
  ])("formatClock(%i) === %s", (input, expected) => {
    expect(formatClock(input)).toBe(expected);
  });

  test("ring progress spans 0..1 across a phase", () => {
    expect(ringProgress(initialTimerState(), NOW)).toBe(0);
    expect(ringProgress(runningWork(0), NOW)).toBe(1);
    const half = ringProgress(runningWork(600_000), NOW);
    expect(half).toBeCloseTo(0.5, 1);
  });
});

describe("persistence", () => {
  test("round-trips through storage including chime flag", () => {
    const storage = memoryStorage();
    saveTimerState(storage, {
      ...initialTimerState(),
      cycles: 9,
      remaining: 42,
      chime: true,
    });
    const loaded = loadTimerState(storage);
    expect(loaded.cycles).toBe(9);
    expect(loaded.remaining).toBe(42);
    expect(loaded.chime).toBe(true);
  });

  test("corrupt payload falls back to initial state", () => {
    const storage = memoryStorage();
    storage.setItem("gazekeeper-timer-v1", "{not json");
    expect(loadTimerState(storage)).toEqual(initialTimerState());
  });

  test("null storage never throws", () => {
    expect(() => saveTimerState(null, initialTimerState())).not.toThrow();
    expect(loadTimerState(null)).toEqual(initialTimerState());
  });

  test("nonsensical saved values are clamped", () => {
    const storage = memoryStorage();
    storage.setItem(
      "gazekeeper-timer-v1",
      JSON.stringify({ remaining: -50, cycles: 1e9, phase: "banana" }),
    );
    const loaded = loadTimerState(storage);
    expect(loaded.remaining).toBeGreaterThanOrEqual(1);
    expect(loaded.cycles).toBeLessThanOrEqual(10_000);
    expect(loaded.phase).toBe("work");
  });
});
