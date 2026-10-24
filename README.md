# XDRLift

Keeps an Apple XDR display (built for the 2026 Studio Display XDR) above Apple's indoor SDR
brightness cap with a fixed multiplier, while the native brightness slider in Control Center and
the keyboard keeps controlling it.

macOS only opens the Studio Display XDR's 1000-nit SDR range when the ambient light sensor sees a
bright room. XDRLift instead:

1. shows a 1×1 near-transparent EDR window, which makes macOS switch the panel into EDR mode
   (SDR white is rendered at 1.0 inside a larger range, headroom `H` — 3.33× at full brightness here);
2. covers each EDR screen with a click-through window whose Metal layer uses the `multiply`
   compositing filter and clears to `k` every frame, so everything below is multiplied by `k`.

The applied multiplier is `min(k, 0.95·H)`, and 1 whenever EDR is off, the display sleeps, the
screen is locked or the screen saver runs. Lowering the native slider raises `H`, so the output is
always `k ×` the native brightness. Nothing persistent is changed: quitting or crashing removes
the overlay.

## Use

```sh
make            # build/XDRLift.app
make selftest   # pulses 1.0× ↔ 1.4× every 2 s for 12 s, logs headroom / frame health, exits
make install    # copies to /Applications and starts it
/Applications/XDRLift.app/Contents/MacOS/XDRLift --login on   # start at login (or use the menu)
```

Menu bar (sun icon): on/off (⌃⌥⌘B from anywhere), the multiplier (1.00–1.60×, remembered per
display), start at login. It warns when Vivid, BetterDisplay, Lunar, BrightIntosh or f.lux is
running, since their boosts would stack.

## Caveats

- HDR video is multiplied too and clips earlier; toggle off with ⌃⌥⌘B for HDR content.
- Screenshots, recordings and screen sharing probably capture the boosted image (brighter,
  highlights clipped; not yet checked here). Excluding the overlay from capture reportedly makes
  captures black instead, so press ⌃⌥⌘B first when it matters.
- The mouse pointer sits above the overlay and is not boosted, so its white parts look a little
  grey (1/k) against boosted white.
- A fullscreen game under the overlay is likely composited instead of scanned out directly
  (not measured); check with the Metal HUD if a game feels slower.
- The nit figure is an estimate (`2000 / H` for SDR white); nothing here measures luminance.
- Gamma-table boosting (`CGSetDisplayTransferByTable` above 1.0) is accepted and reads back on
  M5 Macs, but Apple DTS and BrightIntosh users report no visible change there, so it is not used.
