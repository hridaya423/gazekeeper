export interface StrainInputs {
  screenHours: number;
  breaksPerHour: number;
  blinkRate: "normal" | "rarely";
  dryEyes: boolean;
  nightMode: boolean;
  blueLightGlasses: boolean;
  distanceCm: number;
}

export interface StrainResult {
  score: number;
  level: "Low" | "Moderate" | "High" | "Severe";
  message: string;
  tips: { title: string; body: string }[];
}

const LEVELS: Record<StrainResult["level"], string> = {
  Low: "Few of your answers add to strain.",
  Moderate: "Some of your answers add to strain.",
  High: "Many of your answers add to strain.",
  Severe: "Most of your answers add to strain.",
};

export function computeStrain(inputs: StrainInputs): StrainResult {
  let risk = 0;

  const hours = clampNum(inputs.screenHours, 0, 18);
  risk += Math.min(hours * 4, 32);

  const breaks = clampNum(inputs.breaksPerHour, 0, 6);
  risk += Math.max(12 - breaks * 6, -8);

  if (inputs.blinkRate === "rarely") risk += 10;
  if (inputs.dryEyes) risk += 12;

  const distance = clampNum(inputs.distanceCm, 25, 100);
  if (distance < 40) risk += 14;
  else if (distance < 50) risk += 9;
  else if (distance < 60) risk += 4;

  if (!inputs.nightMode && inputs.screenHours >= 5) risk += 8;

  risk = Math.round(clampNum(risk, 0, 100));

  const level: StrainResult["level"] =
    risk < 25 ? "Low" : risk < 50 ? "Moderate" : risk < 75 ? "High" : "Severe";

  return {
    score: risk,
    level,
    message: LEVELS[level],
    tips: buildTips(inputs, risk),
  };
}

function buildTips(
  inputs: StrainInputs,
  risk: number,
): { title: string; body: string }[] {
  const tips: { title: string; body: string }[] = [];
  if (inputs.breaksPerHour < 1) {
    tips.push({
      title: "Take a break every 20 minutes",
      body: "Look at something 20 feet away for 20 seconds. GazeKeeper reminds you.",
    });
  }
  if (inputs.distanceCm < 50) {
    tips.push({
      title: "Sit back from the display",
      body: "Arm's length, about 50–70 cm, is a common recommendation for desktop screens.",
    });
  }
  if (inputs.dryEyes || inputs.blinkRate === "rarely") {
    tips.push({
      title: "Blink on purpose",
      body: "People blink less while looking at a screen. A few full, slow blinks during each break are an easy habit.",
    });
  }
  if (!inputs.nightMode && inputs.screenHours >= 5) {
    tips.push({
      title: "Dim and warm at night",
      body: "Night Shift or a similar setting warms and softens the display after sunset. Many people find it more comfortable.",
    });
  }
  if (inputs.blueLightGlasses) {
    tips.push({
      title: "Blue-light glasses may not help",
      body: "Reviews have found little evidence that blue-light glasses ease digital eye strain. This score does not count them.",
    });
  }
  if (risk < 20 && tips.length === 0) {
    tips.push({
      title: "Stay consistent",
      body: "Your habits score low here. The hard part is keeping them on busy days.",
    });
  }
  return tips.slice(0, 3);
}

function clampNum(n: number, min: number, max: number): number {
  return Math.min(Math.max(n, min), max);
}
