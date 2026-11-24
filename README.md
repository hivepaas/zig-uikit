# zig-uikit

A declarative GPU UI toolkit for Zig.

> **Status: pre-alpha.** The layout core exists and is tested; there is no
> renderer, no text and no widgets. Expect the API to change without notice.

```sh
zig build test    # 18 tests, no platform dependencies
```

```zig
var t = try ui.Tree.init(gpa);
defer t.deinit();

try t.setStyle(t.root(), .{ .axis = .col, .padding = 8, .gap = 4 });
const row = try t.appendChild(t.root(), .{ .axis = .row, .height = .{ .fixed = 32 } });
const label = try t.appendChild(row, .{ .width = .{ .grow = 1 } });

t.layout(.{ .w = 1280, .h = 720 });

// Later. Only what changed is recomputed; an unchanged frame does nothing.
try t.setStyle(label, .{ .width = .{ .grow = 2 } });
const cost = t.flush();   // .intrinsic, .position, .fast_path, .slow_path
```

The tree is **retained and mutated**, not rebuilt per frame. That is the whole
point: a frame arena reset wholesale cannot reuse last frame's subtrees, which
is where the saving comes from. A declarative layer belongs on top of this, and
`setStyle` compares before marking dirty so that re-setting an unchanged style
every frame costs nothing.

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

- [Text and accessibility: constraints from four working spikes](docs/text-and-accessibility.md)
  — the specification the spikes produced. Eight numbered requirements, each one
  measured rather than read out of a protocol document, plus what they do not
  settle.

Tier A of that note is load-bearing, so it was tested before any widget code
exists. Four spikes implement it twice over, on Linux and Windows, far enough
that a screen reader reads the tree and an input method composes text:

- [spikes/ime-wayland](spikes/ime-wayland/) — `zwp_text_input_v3`. Vietnamese
  Telex composes correctly and byte-exactly; `delete_surrounding_text` is still
  untested.
- [spikes/a11y-atspi](spikes/a11y-atspi/) — AT-SPI implemented directly over
  DBus. **Orca reads it**: it lists the application, pulls the tree through
  `Cache.GetItems`, and decodes the text events correctly, including the
  character offsets on multi-byte Vietnamese.

- [spikes/uia-windows](spikes/uia-windows/) — Windows UI Automation, a provider
  implemented directly in COM and **cross-compiled from Linux** with no MSVC or
  Windows SDK. **Narrator reads it**: 93 calls into the process, ending in
  `get_Value`.
- [spikes/tsf-windows](spikes/tsf-windows/) — Windows IME via `ITextStoreACP`,
  29 methods plus a lock protocol. **Telex composes correctly** through
  Windows 11's own Vietnamese TSF IME: 173 calls, 23 `SetText`, 5 compositions.

Together they surfaced the constraint that shapes the text field. **The same
widget has to speak three different offset units:**

| protocol | unit |
| --- | --- |
| `zwp_text_input_v3` | UTF-8 bytes |
| AT-SPI | codepoints |
| Windows `BSTR` | UTF-16 code units |
| TSF "ACP" | UTF-16 code units |

`tiếng việt 🇻🇳` is 23 bytes, 13 codepoints and 15 UTF-16 units. ASCII hides all
three mismatches, which is why none of this is testable in English.

Windows turns out to be internally **consistent** — its accessibility and its
input method both count UTF-16 code units. Linux is not: `text-input-v3` counts
bytes while AT-SPI counts codepoints, so a Linux text field must convert between
its own two platform protocols.

And composition itself differs in kind, not just in units: on Wayland the
preedit is a separate string that never enters the document, while under TSF the
input processor writes the composing text *into* the buffer and marks it
provisional. The document model has to support the Windows shape, because the
Wayland shape cannot represent it.

They also showed that the two accessibility backends have almost nothing in
common, and the gap is measurable. Reading the same two-node tree costs:

```
AT-SPI:   1 call   -- Cache.GetItems, whole tree, serialised
UIA:     93 calls  -- no snapshot exists; the client re-walks what it needs
```

AT-SPI is push, out of process, over a bus. UIA is pull, in process, straight
into COM vtables. One internal tree can feed both, but the adapters want
opposite things: a cheap tree *serialisation* on Linux, a cheap *individual
accessor* on Windows.

Decisions and the measurements behind them will be published here as they are
made, including the ones that went against the original plan — a frame arena
wins jitter and memory but not mean frame time; persistently-mapped quad
buffers are a micro-optimisation (0.05% of a frame), not a requirement; and
text was never the blocker it was assumed to be.

## Licence

[MIT](LICENSE). Deliberately permissive: a UI toolkit is only useful if it can
be linked into anything, including closed-source applications.
