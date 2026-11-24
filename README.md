# zig-uikit

A declarative GPU UI toolkit for Zig.

> **Status: pre-alpha.** The layout core, the scene layer and a Vulkan renderer
> exist and are tested. There is no window yet, no text and no widgets. Expect
> the API to change without notice.

```sh
zig build test                           # 46 tests, no platform dependencies
zig build demo                           # renders docs/demo.png in software
zig build bench -Doptimize=ReleaseFast   # what it costs
zig build test-gpu                       # 4 tests, needs a Vulkan device
zig build gpu-demo                       # renders on the GPU, diffs against the reference
```

![a window's worth of interface, rendered by the software rasteriser](docs/demo.png)

Everything above is drawn by this repository: layout, clipping, culling, the
popover escaping the panel that owns it, and the pixels themselves. There is no
window and no GPU involved, and no text — labels are the bars a design tool uses
where text will go, which is honest about what exists.

```zig
var t = try ui.Tree.init(gpa);
defer t.deinit();

try t.setStyle(t.root(), .{ .axis = .col, .padding = 8, .gap = 4 });
const row = try t.appendChild(t.root(), .{ .axis = .row, .height = .{ .fixed = 32 } });
const label = try t.appendChild(row, .{ .width = .{ .grow = 1 } });

t.setPaint(row, .{ .background = ui.Color.hex(0x2F3135), .corner_radius = 6 });

t.layout(.{ .w = 1280, .h = 720 });

// Later. Only what changed is recomputed; an unchanged frame does nothing.
try t.setStyle(label, .{ .width = .{ .grow = 2 } });
const cost = t.flush();   // .intrinsic, .position, .fast_path, .slow_path

var scene = ui.Scene.init(gpa);
_ = try scene.build(&t);  // a flat list of 48-byte quads, ready to upload
```

The tree is **retained and mutated**, not rebuilt per frame. That is the whole
point: a frame arena reset wholesale cannot reuse last frame's subtrees, which
is where the saving comes from. A declarative layer belongs on top of this, and
`setStyle` compares before marking dirty so that re-setting an unchanged style
every frame costs nothing.

## The scene layer

`Paint` is a separate struct from `Style`, reached by a separate setter, and
that separation is the point rather than tidiness. `Style.eql` is what decides
whether an element is dirty for layout, so a background colour living in `Style`
would mean that recolouring a button runs the flexbox engine over its container.
Measured on this library, 1 641 elements:

| | cost | for comparison |
| --- | --- | --- |
| `flush()`, nothing changed | **1.3 ns** | GPUI unchanged frame: 2.32 ms of CPU |
| `setPaint` a leaf + `flush()` | **1.9 ns** | GPUI leaf style: 3.9 ms |
| `setStyle` a leaf's *size* + `flush()` | 142 ns | propagates; no GPUI equivalent |
| full `layout()` | 24 us | GPUI full refresh: 3.50 ms |
| `Scene.build`, nothing changed | 3.8 ns | one integer comparison |
| `Scene.build`, full rebuild | 8.4 us | 0.35% of GPUI's unchanged frame |

This is the first time the shipped library has been measured rather than the
prototype in the benchmark repository, and the point of running it was that it
could have failed. It did not.

The scene is **rebuilt whole, never patched**. A full rebuild is 8.4 us against
the 2.32 ms it is competing with, so a second dirty-tracking system would be
maintaining bugs in exchange for microseconds. What keeps the headline claim
true end to end is instead a revision counter: `Scene.build` returns after one
integer comparison when nothing has changed.

There is one primitive, a 48-byte rounded bordered rectangle, and it carries its
own absolute clip rectangle rather than relying on push/pop state — so the list
survives being bucketed by painting layer, the GPU gets one draw call, and a
subtree outside its clip is skipped in a single test.

`src/raster.zig` is a software rasteriser. It is **not** the renderer: it exists
because paint is the one part of a toolkit that cannot be checked by asserting
on numbers, and `coverage` in it is the signed distance field the GPU shader
will be written from, so the two cannot quietly disagree.

### Two bugs the picture found that the tests did not

Rendering the demo immediately falsified something the test suite had been happy
with for 46 tests. A single non-wrapping flex line was taking its cross size as
the *largest child*, where CSS 9.4 step 8 says it is the *container's inner
cross size*. An invisible 116-pixel popover anchor inside a 28-pixel toolbar row
was therefore pushing that row's icon and label 51 pixels down. Fixing it also
deleted a per-element cache: the correct rule needs no maximum over siblings, so
the fast path got smaller as well as right.

The second: `clip_children` was clipping at the element's outer edge, so the
first overflowing child painted straight over the border meant to contain it.
CSS clips to the padding box. Both now have regression tests, but neither was
going to be found by writing more assertions.

### A known divergence from CSS

`align_items` defaults to `start` here, where CSS defaults it to `stretch`. Every
container that should fill its parent across its axis has to say so. Whether
that is the right default is still open; it is written down rather than
discovered later.

## The Vulkan backend

Separate module, separate test step. The library above links nothing and runs
its tests anywhere; a toolkit whose unit tests need a GPU is a toolkit nobody
runs the tests of.

The scene's `Quad` is uploaded **with no repacking at all** — it is the
per-instance vertex attribute layout, and the pipeline's attribute offsets are
`@offsetOf` on the struct's own fields, asserted at compile time. That is what
the 48-byte `extern struct` was for.

Verified by `zig build test-gpu` on an AMD RADV device: device and queue
selection, offscreen `R8G8B8A8_UNORM` target, dynamic rendering, both image
layout transitions, image-to-buffer copy and host readback, and the quad
pipeline itself.

**The renderer agrees with the software reference to within one unit of 255.**
`zig build gpu-demo` renders the demo above through both paths and diffs every
pixel:

```
GPU vs software reference, 504000 pixels:
  largest channel difference   1
  mean channel difference      0.0008
  pixels differing by > 1      0 (0.000%)
```

That matters because the signed distance field exists twice — once as
`coverage` and `roundedBoxSdf` in `src/raster.zig`, once in GLSL — and two
implementations of one formula are exactly the thing that drifts. They are not
expected to be bit-identical: the reference blends fill and border as two
eight-bit steps where the shader folds them into one premultiplied source. So
the comparison bounds the disagreement rather than forbidding it, and
`docs/demo-diff.png` (amplified 64x) shows where it lives — antialiased edges
and rounded corners, nothing on flat fills.

`UNORM` and not `SRGB` deliberately: the software reference blends eight-bit
sRGB values directly, which is what every shipping UI toolkit does, and an sRGB
format would make the GPU blend in linear space so the two disagreed by
construction. Gamma-correct compositing is one decision to make for both, not a
difference to discover.

The compiled SPIR-V is committed and embedded in the binary, so building the
toolkit needs no shader compiler; only changing a shader does.
[src/gpu/shaders/README.md](src/gpu/shaders/README.md) records why they are
GLSL and not Zig — Zig 0.17's SPIR-V backend decorates builtins correctly but
emits no `Location` decoration for user-declared interface variables, so the
module it produces cannot be used in a graphics pipeline at all. Worth
establishing rather than assuming, because sharing one source with
`src/raster.zig` would have removed the duplication described above.

**Not there yet: a window.** Everything renders offscreen and is read back.
A Wayland surface and a swapchain are the next piece.

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
