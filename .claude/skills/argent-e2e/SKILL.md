# Argent — SwiftUI simulator E2E testing

Argent (@swmansion/argent) is wired into your session as the `argent` MCP server
(`mcp__argent__*` tools). It drives the iOS Simulator for end-to-end verification of
SwiftUI apps: build/install/launch the app, interact with the UI, and capture screenshots.

## When to use
- After implementing a UI change in a SwiftUI project, when a simulator runtime is
  available on this machine: launch the app and verify the change visually.
- Persist proof screenshots to `.orchestrator/artefacts/screenshots/` in your worktree —
  they surface in the dashboard's ARTEFACTS pane for the operator.

## The interaction loop (this is the part that trips agents up — follow it exactly)
1. `mcp__argent__list-devices` — pick the booted iOS simulator's `udid`. If none is
   booted, `mcp__argent__boot-device` first.
2. `mcp__argent__launch-app` with the bundle id to open (or confirm running).
3. `mcp__argent__describe` (pass the `udid`) — returns the on-screen accessibility tree.
   Every element's frame is already normalized to **0.0–1.0 fractions of screen width/
   height, NOT pixels**.
4. To tap an element, compute the centre of its frame and call
   `mcp__argent__gesture-tap` with `--udid`, `--x = frame.x + frame.width/2`,
   `--y = frame.y + frame.height/2` (still 0.0–1.0, not pixels). There is no plain
   `tap` tool — `gesture-tap` is the only tap tool, and it fails if you pass pixel
   coordinates or omit `--udid`.
5. For swipes/drags use `gesture-swipe` / `gesture-drag` (same normalized-coordinate,
   `--udid`-required contract). For typing, use `keyboard`. For hardware buttons
   (home, lock, etc.), use `button`.
6. After each interaction, re-`describe` (or `screenshot`) to confirm the UI actually
   changed before moving to the next step — don't chain blind taps.

## Other tools
- `screenshot` — capture proof for `.orchestrator/artefacts/screenshots/`.
- `native-describe-screen` — richer UIKit-level inspection (accessibilityIdentifier,
  viewClassName) when `describe`'s AX tree isn't enough; needs an explicit `bundleId`.
- Full list: run `argent tools` in the shell, or `argent tools describe <name>` for a
  specific tool's flags — every tool is self-documenting and versioned, so re-check
  this if a call's flags don't match what's written here.

## Caveats
- Simulator availability depends on the host having an Xcode/simulator runtime. If boot
  or build tools are missing, note it in the scratchpad and fall back to the project's
  syntax gate + code-level reasoning — do NOT spin retrying.
- If a tap/swipe call fails, the most common cause is passing pixel coordinates instead
  of normalized 0.0–1.0 fractions, or missing `--udid` — not a broken simulator. Re-run
  `describe` and recompute before assuming the environment is broken.
