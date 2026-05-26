# kcaliflow

> **Less pressure. More freedom.**

kcaliflow is a health and fitness tracking app for iPhone, Apple Watch, and widgets. Instead of demanding a fixed daily goal, it uses a **weighted rolling average** — so rest days are fine, and one great day makes up for a slow one.

---

## Features

- **Weighted average tracking** — past days fade out using exponential decay, so recent effort matters most
- **Today's minimum** — calculates the minimum activity needed today to stay on track with your goal
- **Dual tracking modes** — switch between active calories or step count
- **Interactive chart** — tap any data point to see its value; color-coded bands show your goal zone
- **Apple Watch complications** — circular and rectangular complications for your watch face
- **Home Screen widgets** — small widget with stand-hour ring indicators
- **HealthKit integration** — reads active energy, steps, Activity summaries, and stand hours
- **Guided onboarding** — 3-step setup that explains the app philosophy and walks you through goal configuration
- **Localized** — English, German, and Spanish

---

## How It Works

kcaliflow replaces rigid daily targets with a flexible weighted average:

1. Each past day is weighted using exponential decay — older days contribute less
2. The app calculates the **minimum you need to do today** to keep your rolling average at or above your goal
3. If you had a great week, today's minimum drops. If you've been resting, it rises — but never punishes you

**Example:** set a 500 kcal/day average goal over 14 days. Miss a day? No problem. The app adjusts tomorrow's minimum automatically.

---

## Platforms

| Target | Minimum OS |
|--------|-----------|
| iPhone / iPad | iOS 26.0 |
| Apple Watch | watchOS 26.4 |
| Widget Extension | iOS 26.0 / watchOS 26.0 |

---

## Tech Stack

| Framework | Used for |
|-----------|---------|
| SwiftUI | All UI across all targets |
| HealthKit | Reading calories, steps, stand hours, activity rings |
| WidgetKit | Home Screen widgets and watch complications |
| WatchConnectivity | Syncing data from iPhone to Watch |
| Swift Charts | Interactive line and area charts |
| App Groups | Shared data between app, widget, and watch |

---

## Project Structure

```
kcaliflow/
├── kcaliflow/              # Main iPhone app
│   ├── kcaliflowApp.swift  # App entry, onboarding gate
│   ├── ContentView.swift   # Main dashboard with chart
│   ├── pfHealth.swift      # iPhone state container backed by shared HealthKit reader
│   ├── OnboardingView.swift
│   └── InfoView.swift
│
├── kcaliWatch Watch App/   # watchOS companion app
│
├── kcaliWidget/            # iOS widget target and iPhone-specific widget views
│
├── kcaliWatchWidget/       # watchOS widget target and complication views
│
├── Shared/                 # Code shared across all targets
│   ├── AppleHealthDataService.swift  # Shared HealthKit collection + tracking math
│   ├── SharedStore.swift             # App Group storage + ring math
│   └── WidgetSupport.swift           # Shared timeline entry/provider for both widget targets
│
└── kcaliflow.xcodeproj
```

---

## Data Flow

```
HealthKit
    ├─▶ AppleHealthDataService (shared collector)
    │       ├─▶ PFHealth (iPhone)
    │       ├─▶ WatchHealthBridge (Watch app)
    │       └─▶ Widget timeline provider
    ├─▶ PFHealth (iPhone)
    │       ├─▶ ContentView (live UI)
    │       ├─▶ SharedStore (App Group UserDefaults)
    │       │       ├─▶ iOS Widget
    │       │       └─▶ Watch Widget / Complications
    │       └─▶ WatchConnectivity
    │               └─▶ Watch App (shared fallback)
```

---

## Privacy & Permissions

kcaliflow reads health data and never writes or shares it.

**HealthKit permissions requested (read-only):**
- Active Energy Burned
- Step Count
- Apple Activity Summaries
- Apple Stand Hours

**Entitlements:**
- HealthKit + background delivery
- App Groups (`group.ch.enjor.health`)

---

## Building

1. Open `kcaliflow.xcodeproj` in Xcode
2. Select the `kcaliflow` scheme
3. Choose your device or simulator
4. Build & run (`⌘R`)

> HealthKit is not available on the Simulator — use a real device to test health data features.

---

## License

GNU Affero General Public License v3.0
