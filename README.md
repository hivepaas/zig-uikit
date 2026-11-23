# zig-uikit

A declarative GPU UI toolkit for Zig.

> **Status: pre-alpha, nothing to use yet.** The design is being settled by
> measurement before code is written. Expect the API to change without notice.

## What it is meant to be

A retained element tree with **element-level** reactivity, a real text stack
(shaping, bidi, font fallback, IME), and accessibility treated as a first-class
concern rather than an afterthought.

## Why

The design targets specific, measured gaps rather than a hunch that a new
toolkit would be nicer.

The toolkit this is most informed by is [GPUI](https://github.com/zed-industries/zed),
which is excellent and well engineered. One thing is structural, though: its
reactive granularity is the **view**, not the element. A frame where *nothing
changed* under a notified view costs the same as a full refresh — benchmarked at
~2.3 ms of CPU, ~34 M instructions and ~8 400 heap allocations for a
1 649-element tree. The cost is flat in the amount changed.

A prototype with per-element dirty tracking takes that same unchanged frame to
tens of nanoseconds and zero allocations. That is the one architectural bet
behind this project. Everything else here is ordinary engineering.

The bet was re-tested against real flexbox — flex-shrink, the CSS 9.7 min/max
freeze loop, wrap, justify-content, baseline alignment — because the first
prototype's layout model was too simple to trust. It survives unchanged, for a
reason worth being precise about: it is not a claim about layout cost. A frame
that changes nothing does no layout work, however complicated the layout model
is. What does degrade is size-change propagation, by about 2.35x on pathological
trees, to 20 us — a quarter of one percent of a 120 fps budget.

To be clear about what that is *not*: GPUI misses **zero** frame budget
overruns at 120 fps on that tree. The 2.3 ms is lost headroom and battery, not
dropped frames.

Those numbers, the machine they came from, the method, and — importantly — the
runs that contradicted the original plan are all in
**[zig-uikit-bench](https://github.com/hivepaas/zig-uikit-bench)**. It also
states per run what may *not* be concluded from it. If you intend to disagree
with the premise of this project, that repo is where to start.

## Non-goals

- Beating GPUI, iced or egui on microbenchmarks. Architecture is worth 10–100x;
  language choice is worth roughly ±20%, and that is not the point.
- Immediate mode. [dvui](https://github.com/david-vanderson/dvui) already does
  that well and is actively maintained.
- Being a thin wrapper over a single platform. Multi-backend from the start.

## Design notes

- [Native components vs. self-drawn components](docs/native-vs-drawn.md) — why
  there is one widget set and not two, and the three tiers "native" actually
  decomposes into.

Tier A of that note is load-bearing, so it is being tested before any widget
code exists:

- [spikes/ime-wayland](spikes/ime-wayland/) — `zwp_text_input_v3`. Vietnamese
  Telex composes correctly and byte-exactly; `delete_surrounding_text` is still
  untested.
- [spikes/a11y-atspi](spikes/a11y-atspi/) — AT-SPI implemented directly over
  DBus. **Orca reads it**: it lists the application, pulls the tree through
  `Cache.GetItems`, and decodes the text events correctly, including the
  character offsets on multi-byte Vietnamese.

Together they surfaced the constraint that shapes the text field: **AT-SPI
counts characters, `text-input-v3` counts bytes.** One widget, two offset units,
and the mismatch is invisible in ASCII.

Decisions and the measurements behind them will be published here as they are
made, including the ones that went against the original plan — a frame arena
wins jitter and memory but not mean frame time; persistently-mapped quad
buffers are a micro-optimisation (0.05% of a frame), not a requirement; and
text was never the blocker it was assumed to be.

## Licence

[MIT](LICENSE). Deliberately permissive: a UI toolkit is only useful if it can
be linked into anything, including closed-source applications.
