import { computeStrain, type StrainInputs } from "../../src/scripts/strain";

function inputs(overrides: Partial<StrainInputs> = {}): StrainInputs {
  return {
    screenHours: 8,
    breaksPerHour: 0,
    blinkRate: "normal",
    dryEyes: false,
    nightMode: true,
    blueLightGlasses: false,
    distanceCm: 65,
    ...overrides,
  };
}

describe("strain scoring", () => {
  test("healthy habits score low with a positive tip", () => {
    const r = computeStrain(
      inputs({
        screenHours: 4,
        breaksPerHour: 3,
        nightMode: true,
        distanceCm: 70,
      }),
    );
    expect(r.score).toBeLessThan(25);
    expect(r.level).toBe("Low");
    expect(r.tips.length).toBeGreaterThan(0);
  });

  test("worst-case answers land in Severe", () => {
    const r = computeStrain(
      inputs({
        screenHours: 16,
        breaksPerHour: 0,
        blinkRate: "rarely",
        dryEyes: true,
        nightMode: false,
        blueLightGlasses: false,
        distanceCm: 30,
      }),
    );
    expect(r.level).toBe("Severe");
    expect(r.score).toBeGreaterThanOrEqual(75);
  });

  test("more breaks monotonically reduce the score", () => {
    let prev = Infinity;
    for (let b = 0; b <= 5; b++) {
      const score = computeStrain(inputs({ breaksPerHour: b })).score;
      expect(score).toBeLessThanOrEqual(prev);
      prev = score;
    }
  });

  test("closer screens are riskier than distant ones", () => {
    const near = computeStrain(inputs({ distanceCm: 30 })).score;
    const far = computeStrain(inputs({ distanceCm: 80 })).score;
    expect(near).toBeGreaterThan(far);
  });

  test("night mode only matters at high screen hours", () => {
    const lowHoursOff = computeStrain(
      inputs({ screenHours: 2, nightMode: false }),
    ).score;
    const lowHoursOn = computeStrain(
      inputs({ screenHours: 2, nightMode: true }),
    ).score;
    expect(lowHoursOff).toBe(lowHoursOn);

    const highHoursOff = computeStrain(
      inputs({ screenHours: 8, nightMode: false }),
    ).score;
    const highHoursOn = computeStrain(
      inputs({ screenHours: 8, nightMode: true }),
    ).score;
    expect(highHoursOff).toBe(highHoursOn + 8);
  });

  test("score stays within 0..100 for absurd inputs", () => {
    const r1 = computeStrain(
      inputs({ screenHours: 9999, breaksPerHour: -100, distanceCm: 1 }),
    );
    const r2 = computeStrain(
      inputs({ screenHours: -50, breaksPerHour: 999, distanceCm: 9999 }),
    );
    expect(r1.score).toBeLessThanOrEqual(100);
    expect(r2.score).toBeGreaterThanOrEqual(0);
  });

  test("dry eyes and rare blinking both add risk", () => {
    const base = computeStrain(inputs()).score;
    const dry = computeStrain(inputs({ dryEyes: true })).score;
    const blink = computeStrain(inputs({ blinkRate: "rarely" })).score;
    expect(dry).toBeGreaterThan(base);
    expect(blink).toBeGreaterThan(base);
  });

  test("tips target the actual deficits", () => {
    const tips = computeStrain(
      inputs({ breaksPerHour: 0, distanceCm: 30, dryEyes: true }),
    ).tips;
    const titles = tips.map((t) => t.title).join(" ");
    expect(titles).toMatch(/break every 20/i);
    expect(titles).toMatch(/sit back/i);
    expect(tips.length).toBeLessThanOrEqual(3);
  });
});
