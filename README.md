# XDRLift

Keeps an Apple XDR display (built for the 2026 Studio Display XDR) above Apple's indoor SDR
brightness cap with a fixed multiplier, while the native brightness slider in Control Center and
the keyboard keeps controlling it.

macOS only opens the Studio Display XDR's 1000-nit SDR range when the ambient light sensor sees a
bright room. XDRLift instead:

1. shows a 1×1 near-transparent EDR window, which makes macOS switch the panel into EDR mode
   (SDR white is rendered at 1.0 inside a larger range, headroom `H` — 3.33× at full brightness here);
2. scales the display's gamma (transfer) table above 1.0, by `k^(1/2.2)`, so SDR white is pushed
   into that headroom, to about `k ×` the native brightness.

The applied multiplier is `min(k, 0.95·H)`, and 1 whenever EDR is off, the display sleeps, the
screen is locked or the screen saver runs. Lowering the native slider raises `H`, so the output
follows the slider. The table is applied after window compositing, so the boost holds through
Space switches and Mission Control, covers the mouse pointer and stays out of screenshots.
WindowServer restores the table when the process exits, even on `kill -9`.

## Use

```sh
make            # build/XDRLift.app
make selftest   # pulses 1.0× ↔ 1.4× every 2 s for 12 s, logs headroom / table, exits
make install    # copies to /Applications and starts it
/Applications/XDRLift.app/Contents/MacOS/XDRLift --login on   # start at login (or use the menu)
```

Menu bar (sun icon): on/off (⌃⌥⌘B from anywhere), the multiplier (1.00–1.60×, remembered per
display), start at login. It warns when Vivid, BetterDisplay, Lunar, BrightIntosh or f.lux is
running, or when something else keeps rewriting the gamma table.

Logs go to the unified log:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.justaboringname.xdrlift"'
defaults write com.justaboringname.xdrlift trace -bool true   # 50 ms state trace after relaunch
```

## Caveats

- HDR video is boosted too and clips earlier; toggle off with ⌃⌥⌘B for HDR content.
- The table holds gamma-encoded values: alternating an EDR 1.4× white field with SDR white under
  table factors 1.10–1.46, the low end (≈ 1.4^(1/2.2) = 1.165) flickered least. Judged by eye, not
  measured; pick `k` by eye.
- If another app writes the gamma table (Vivid, f.lux, Lunar, …), XDRLift stands aside at 1× and
  resumes after the table has been left alone for 30 s; a plain table that replaces its own (a
  profile change, wake) becomes the new base and the boost fades back up on top of it.
- The nit figure is an estimate (`2000 / H` for SDR white); nothing here measures luminance.
- A first version used a full-screen `multiply` overlay instead. WindowServer does not composite
  overlays during the Space-switch animation, so the screen dipped for about a second on every
  Ctrl+←/→; it also left the pointer unboosted and leaked into screenshots.
