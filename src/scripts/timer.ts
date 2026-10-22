export type Phase = "work" | "break";

export interface TimerState {
  running: boolean;
  phase: Phase;
  endsAt: number | null;
  remaining: number;
  cycles: number;
  chime: boolean;
}

export const WORK_SECONDS = 20 * 60;
export const BREAK_SECONDS = 20;

interface TickResult {
  state: TimerState;
  completedPhase: boolean;
}

function clamp(n: number, min: number, max: number): number {
  return Math.min(Math.max(n, min), max);
}

function normalize(raw: Partial<TimerState> | null | undefined): TimerState {
  return {
    running: !!raw?.running,
    phase: raw?.phase === "break" ? "break" : "work",
    endsAt:
      raw?.running && typeof raw.endsAt === "number"
        ? (raw.endsAt as number)
        : null,
    remaining:
      typeof raw?.remaining === "number"
        ? clamp(Math.round(raw.remaining), 1, WORK_SECONDS)
        : WORK_SECONDS,
    cycles:
      typeof raw?.cycles === "number" && Number.isFinite(raw.cycles)
        ? clamp(Math.round(raw.cycles), 0, 10_000)
        : 0,
    chime: !!raw?.chime,
  };
}

export function initialTimerState(): TimerState {
  return {
    running: false,
    phase: "work",
    endsAt: null,
    remaining: WORK_SECONDS,
    cycles: 0,
    chime: false,
  };
}

export function start(state: TimerState, now: number): TimerState {
  if (state.running) return state;
  const seconds = state.phase === "break" ? BREAK_SECONDS : WORK_SECONDS;
  const remaining = state.remaining > 0 ? state.remaining : seconds;
  return { ...state, running: true, endsAt: now + remaining * 1000 };
}

export function pause(state: TimerState, now: number): TimerState {
  if (!state.running || state.endsAt === null)
    return { ...state, running: false };
  const remaining = Math.max(0, Math.round((state.endsAt - now) / 1000));
  return { ...state, running: false, endsAt: null, remaining };
}

export function reset(state: TimerState): TimerState {
  const seconds = state.phase === "break" ? BREAK_SECONDS : WORK_SECONDS;
  return {
    running: false,
    phase: state.phase,
    endsAt: null,
    remaining: seconds,
    cycles: state.cycles,
    chime: state.chime,
  };
}

export function toggleChime(state: TimerState): boolean {
  return !(state as TimerState & { chime?: boolean }).chime;
}

export function tick(state: TimerState, now: number): TickResult {
  if (!state.running || state.endsAt === null) {
    return { state, completedPhase: false };
  }
  let next = normalize({ ...state });
  let completed = false;
  let guard = 0;
  while (
    next.running &&
    next.endsAt !== null &&
    next.endsAt <= now &&
    guard < 200
  ) {
    if (next.phase === "work") {
      next = {
        ...next,
        phase: "break",
        endsAt: next.endsAt + BREAK_SECONDS * 1000,
        remaining: BREAK_SECONDS,
        cycles: next.cycles + 1,
      };
    } else {
      next = {
        ...next,
        phase: "work",
        endsAt: next.endsAt + WORK_SECONDS * 1000,
        remaining: WORK_SECONDS,
      };
    }
    completed = true;
    guard++;
  }
  if (!guard && next.running && next.endsAt !== null) {
    next = {
      ...next,
      remaining: Math.max(1, Math.ceil((next.endsAt - now) / 1000)),
    };
  }
  if (!next.running) next = { ...next, endsAt: null };
  return { state: next, completedPhase: completed };
}

export function formatClock(totalSeconds: number): string {
  const s = clamp(Math.round(totalSeconds), 0, WORK_SECONDS * 4);
  const m = Math.floor(s / 60);
  const sec = s % 60;
  return `${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
}

export function ringProgress(state: TimerState, now: number): number {
  const total = state.phase === "break" ? BREAK_SECONDS : WORK_SECONDS;
  const remaining = state.running
    ? Math.max(0, ((state.endsAt ?? now) - now) / 1000)
    : state.remaining;
  return clamp(1 - remaining / total, 0, 1);
}

export function loadTimerState(storage: Storage | null): TimerState {
  if (!storage) return initialTimerState();
  try {
    const raw = storage.getItem("gazekeeper-timer-v1");
    if (!raw) return initialTimerState();
    return normalize(JSON.parse(raw));
  } catch {
    return initialTimerState();
  }
}

export function saveTimerState(
  storage: Storage | null,
  state: TimerState,
): void {
  if (!storage) return;
  try {
    storage.setItem("gazekeeper-timer-v1", JSON.stringify(state));
  } catch {
    /* storage unavailable */
  }
}
