export interface CompareRow {
  feature: string;
  gazekeeper: string;
  others: string;
}

export interface CompareApp {
  slug: string;
  name: string;
  verdict: string;
  rows: CompareRow[];
}

export const COMPARISON_APPS: CompareApp[] = [
  {
    slug: "stretchly",
    name: "Stretchly",
    verdict:
      "Stretchly is free, open source and runs on macOS, Windows and Linux. GazeKeeper runs only on the Mac. If you want one reminder across a Mac, a PC and a Linux box, Stretchly is the better fit.",
    rows: [
      {
        feature: "Price",
        gazekeeper: "Free, no account",
        others: "Free and open source",
      },
      {
        feature: "Platforms",
        gazekeeper: "macOS 14 or later",
        others: "macOS, Windows and Linux",
      },
      {
        feature: "Built with",
        gazekeeper: "Swift, SwiftUI and AppKit",
        others: "Electron",
      },
      {
        feature: "Break types",
        gazekeeper:
          "Short breaks (20 seconds by default), optional long breaks",
        others: "Mini breaks and long breaks",
      },
    ],
  },
  {
    slug: "time-out",
    name: "Time Out",
    verdict:
      "A long-running Mac break app from Dejal, with normal and micro breaks you can adjust or turn off. GazeKeeper is newer. It focuses on timing a break around what you are doing.",
    rows: [
      {
        feature: "Platforms",
        gazekeeper: "macOS 14 or later",
        others: "macOS",
      },
      {
        feature: "Price",
        gazekeeper: "Free, no account",
        others: "Free, with optional paid supporter plans",
      },
      {
        feature: "Break types",
        gazekeeper:
          "Short breaks (20 seconds by default), optional long breaks",
        others: "Normal breaks and micro breaks",
      },
      {
        feature: "Where you get it",
        gazekeeper: "Direct download",
        others: "Mac App Store",
      },
    ],
  },
  {
    slug: "lookaway",
    name: "LookAway",
    verdict:
      "LookAway also holds breaks for calls and fullscreen, and it syncs to an iPhone or iPad, which GazeKeeper does not. GazeKeeper is free, needs macOS 14 instead of 13, and can move a break ahead of a calendar meeting.",
    rows: [
      {
        feature: "Price",
        gazekeeper: "Free, no account",
        others: "Paid license",
      },
      { feature: "Minimum macOS", gazekeeper: "14", others: "13" },
      {
        feature: "Holds a break for",
        gazekeeper:
          "Camera, microphone, screen sharing, fullscreen, apps you choose",
        others: "Calls, screen recording, video playback, fullscreen games",
      },
      { feature: "Focus filter", gazekeeper: "Yes", others: "Yes" },
      {
        feature: "Shortcuts",
        gazekeeper:
          "Actions to start, pause, resume and snooze breaks, and to read the countdown and today's stats",
        others: "Runs a Shortcut or AppleScript when a break starts or ends",
      },
      {
        feature: "Other devices",
        gazekeeper: "Mac only",
        others: "Syncs breaks to iPhone and iPad",
      },
    ],
  },
];
