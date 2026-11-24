# zig-uikit

A declarative GPU UI toolkit for Zig.

> **Status: pre-alpha.** The layout core, the scene layer, a Vulkan renderer
> with a Wayland window, a Metal renderer with a macOS window, and a shaped-text
> stack exist and are tested. Both backends draw text.
> There are no widgets. Expect the API to change without notice.

```sh
zig build test                           # 79 tests, no platform dependencies
zig build demo                           # renders docs/demo.png in software
zig build bench -Doptimize=ReleaseFast   # what it costs
zig build test-text                      # 14 tests, needs a font installed
zig build test-gpu                       # Vulkan: 7 tests; Metal: 10 tests
zig build gpu-demo                       # renders on the GPU, diffs against the reference
zig build window                         # opens a window and renders into it
```

The last two follow the target: Vulkan and Wayland on Linux, Metal and AppKit
on macOS. `zig build test` needs nothing. Everything else links fontconfig,
FreeType and HarfBuzz, because the demos share one source file and that file
can set text — on macOS that means Homebrew:
`brew install harfbuzz freetype fontconfig pkgconf`.

![a window's worth of interface, rendered by the software rasteriser](docs/demo.png)

Everything above is drawn by this repository: layout, clipping, culling, the
popover escaping the panel that owns it, the text, and the pixels themselves.
There is no window and no GPU involved — that image is the software reference
rasteriser. The text is shaped by HarfBuzz and rasterised by FreeType, and it is
in Vietnamese because `tiếng Việt` stacks a tone mark over a vowel that already
carries a diacritic, which is the shortest string that tells you whether a text
stack actually shapes or merely maps codepoints to glyphs.

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
_ = try scene.build(&t);  // a flat list of 60-byte quads, ready to upload
```

Text is installed on an element, not drawn by a call:

```zig
var lib = try text.Library.init();
var font = try lib.open(gpa, "sans", 13);     // fontconfig matches the family
var atlas = try text.Atlas.init(gpa, 512, 512);

try text.setText(&t, label, &font, &atlas, "Xin chào");
t.setPaint(label, .{ .text_color = ui.Color.white });
```

`setText` shapes and dirties layout, because text is a size input. `setPaint`
does not, because colour is not. That split is the whole design in one line.

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
| `Scene.build`, full rebuild | 8.4 us | 0.36% of GPUI's unchanged frame |
| `Scene.build`, full rebuild **with text** | 24 us | 8 985 quads, 7 344 of them glyphs |

This is the first time the shipped library has been measured rather than the
prototype in the benchmark repository, and the point of running it was that it
could have failed. It did not.

The scene is **rebuilt whole, never patched**. A full rebuild is 8.4 us against
the 2.32 ms it is competing with, so a second dirty-tracking system would be
maintaining bugs in exchange for microseconds. What keeps the headline claim
true end to end is instead a revision counter: `Scene.build` returns after one
integer comparison when nothing has changed.

There is one primitive, a 60-byte clipped rectangle, and it carries its own
absolute clip rectangle rather than relying on push/pop state — so the list
survives being bucketed by painting layer, the GPU gets one draw call, and a
subtree outside its clip is skipped in a single test.

**A glyph is that same primitive**, with its coverage read from an atlas instead
of from a distance field. The alternative — a second list and a second pipeline
for text — would mean interleaving draw calls to keep a label painting over its
own background, which is to say reconstructing by hand the ordering that one
sorted list gives for free. The cost of not doing that is twelve bytes on every
box quad in the scene: 48 became 60, and a full rebuild of the 1 641-element
grid went from 8.1 us to 8.4 us. The struct is deliberately *not* padded out to
a 64-byte cache line, because 6% more bandwidth to buy an aligned instance fetch
is not something any measurement here asks for.

`src/raster.zig` is a software rasteriser. It is **not** the renderer: it exists
because paint is the one part of a toolkit that cannot be checked by asserting
on numbers, and `coverage` in it is the signed distance field the GPU shader
was written from, so the two cannot quietly disagree.

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

## Text

`zig build test-text` — 14 tests, and they need a font installed, which is why
they are not in `zig build test`.

**HarfBuzz is in the first slice of text, not a later one.** The tempting
shortcut is one glyph per codepoint through `FT_Get_Char_Index`: about thirty
lines, and it renders English correctly. It renders `tiếng Việt` wrongly.
Vietnamese stacks a tone mark over a vowel that may already carry a diacritic,
and whether that is one precomposed glyph or two glyphs positioned by the
font's `GPOS` table is a property of the font, not of the text. Only the shaper
knows. A toolkit written in Vietnam that cannot set Vietnamese is not a toolkit
with a missing feature; it is one built on a model that has to be thrown away.

A test asserts the consequence directly: `tiếng việt` written with precomposed
characters and written with combining marks must shape to the same width and
the same glyph count. A per-codepoint renderer fails that.

Running it on a Mac, where fontconfig matches Verdana rather than DejaVu, found
two faults in the test itself. The combining spelling of `việt` was `e` + dot
below, which is `ẹ` — a different letter that happens to be as wide as `ệ` — so
the test compared two different words and passed. And it checked that the
marks on `ế` rise above the dot of the `i` in `ting`, which is a property of
the font: Verdana at 15 px sets them exactly level. It now checks that `ế`
starts higher than a bare `e`, which holds for any font with marks at all.

### The core does not link a font engine

`zig build test` still runs on a machine with no fonts, no GPU and no
compositor, and that property was worth keeping. So the split is:

- `src/text/` is a separate module. It links fontconfig, FreeType and
  HarfBuzz, and it is the only thing that knows what a font is.
- `src/glyph.zig` is in the core and is plain numbers: where each glyph sits,
  which atlas texels it reads, the run's width and the font's ascent and
  descent. The core lays out around that and emits primitives for it without
  being able to produce any of it.

The direction matters. Had `Tree.setText` taken a string and a font, the layout
core would link three C libraries. Taking an already-shaped run instead also
puts shaping where it belongs: it happens when the text changes, not once per
frame — and the measurement says why.

### Shaping costs 2.1 us, which is the argument for not doing it per frame

| | cost |
| --- | --- |
| shape a 40-character Vietnamese line, warm glyph cache | **2.1 us** |
| shape it *and* install it on an element | 2.1 us (+40 ns for the copy) |
| rebuild a scene of 8 985 quads, 7 344 of them glyphs | 24 us |
| recolour text and flush | **1.4 ns** |

Shaping one line costs a quarter of what rebuilding the entire 1 641-element
scene costs. A window with 1 224 labels in it, re-shaped every frame, would be
**2.6 ms** — which is, to within rounding, the 2.32 ms that this project exists
to argue against. Element-level reactivity is not an optimisation here; it is
the only thing that makes a text-heavy window affordable at all.

Which is also why the text colour lives in `Paint` and not in the run. A theme
switch recolours every label in the window. If colour were part of the shaped
run, recolouring would mean re-shaping, and the table above says what that
costs.

### One destination pixel, one atlas texel

A glyph quad is snapped to the pixel grid by the scene builder, and its
coverage is read with `texelFetch` — integer addressing, no filtering, on the
GPU and in the software reference alike. Both sides compute the same integer
offset from the quad's origin, so they agree on coverage *exactly*; what they
still round independently is the eight-bit blend into the framebuffer, worth
one unit. So `zig build gpu-demo` reports text separately from everything else:

```
of which 40760 pixels are covered by a glyph:
  largest channel difference   1
  glyph pixels differing by > 1 0
```

A glyph pixel differing by more than one would mean the two sides are
addressing different texels, which is a bug and not a rounding difference. A
test in `zig build test-gpu` makes the bound exact where it can be: an opaque
glyph over a known background must come back **bit-identical**, and it is drawn
from a 4×4 atlas with coverage only on the diagonal — because a uniform atlas
would pass with the coordinates transposed, off by one, or ignored.

The atlas itself is shelf-packed, single channel, and has **no gutter between
glyphs**. A gutter exists to stop a filtered sampler reading a neighbour's
texels; nothing here filters, so there is nothing for it to prevent. Exact
texel addressing pays for itself twice: crisp text, and a denser atlas.

Running out of atlas is `error.AtlasFull` and not a growth. Growing moves every
glyph, so every texel coordinate cached on every element becomes wrong, which
means growth needs a re-shape pass over the whole tree — a decision that
belongs to whatever owns the tree, and failing loudly is what stops it being
made by accident.

### A font's line height is not its ascent plus its descent

Noto Sans at 15 pixels reports ascent 17, descent 5, and a preferred line
spacing of **20** — two pixels *less* than the extent it claims for its own
glyphs. They answer different questions: ascent and descent are maxima over
every glyph in the font, including accents almost no line contains, while line
height is what the designer wants lines set at.

So a single label's box is ascent plus descent, the bound that cannot clip ink,
which matters most for exactly the text this project has to set correctly. A
line breaker, when there is one, will stack lines at `line_height` instead.

### The caret, and the three units four protocols count in

A shaped run now carries, per glyph, the **byte offset it came from** and the
**pen position before it**. The first version of this file carried neither,
and that was a bug rather than a missing feature: shaping is not a one-to-one
map — a ligature is one glyph for several bytes, a decomposed `ế` is two glyphs
for one character — so the shaper is the only thing that knows which bytes
produced which glyph, and throwing the answer away means it cannot be recovered
afterwards. The same version dropped glyphs with no ink from the run, which
left a hole in the cluster sequence exactly where a caret has to be able to
sit: after a space.

The pen position is separate from the bitmap position for a reason that is
visible the moment you draw it. `dx` is the left edge of the *ink*, which sits
wherever the outline does and is often to the left of the pen; a caret drawn
there lands inside the letter.

From those two numbers the run answers the three questions a text field asks:

```zig
run.caretX(byte)                 // where a caret before this byte goes
run.byteAt(x, text.len)          // what a click at x selects
run.rangeRect(start, end)        // the selection highlight, or the caret
```

`docs/text-and-accessibility.md` §7 is why: `set_cursor_rectangle` on Wayland,
`GetTextExt` in TSF and `get_BoundingRectangle` in UIA are the same question
three times, and all four spikes answer it with a fixed rectangle — which is
why their candidate windows appear in the wrong part of the screen. These are
the functions that answer it properly.

They are **left to right only**, and the run says so rather than pretending
otherwise. A mixed-direction line needs the glyphs grouped into runs of one
direction each and the arithmetic done per run. A toolkit that got Vietnamese
right by shaping properly should not then get Arabic wrong by assuming.

`src/offsets.zig` is the other half, and it is §1 of the spec made executable:

```
zwp_text_input_v3   UTF-8 bytes
AT-SPI              codepoints
Windows BSTR (UIA)  UTF-16 code units
TSF "ACP"           UTF-16 code units
```

`tiếng việt 🇻🇳` is **23 bytes, 13 codepoints, 15 UTF-16 code units**, and that
string is in the tests because it is the shortest one that separates all three.
ASCII collapses them to one number, Vietnamese separates bytes from codepoints,
and only a non-BMP character separates codepoints from UTF-16 units — so a
toolkit tested in English passes everything it has and then edits the wrong
characters on one platform. Windows is internally consistent; **Linux is not**,
because `text-input-v3` counts bytes while AT-SPI counts codepoints.

Writing those four functions took two tries, and the tests are why that is
knowable. `utf16ToByte` stopped once the running count had *passed* the
requested offset, which steps over the character an offset inside a surrogate
pair belongs to and answers with the byte after it. `alignToChar` asked whether
the *previous* byte was a continuation, which is a different question and true
at a boundary that follows a multi-byte character. Both are the kind of bug
that does not crash: it silently reads or edits the wrong characters, on one
platform, in one language.

The demo draws a selection and a caret from those functions, and the first
render of it was wrong in a way worth keeping here. The highlight has to be a
preceding sibling of the label — the scene builder paints a box, then its
glyphs, then its children, so there is no way to put a rectangle behind an
element's *own* text — and the anchor holding it was given zero height. Under
`align_items: .center` a zero-height element is centred as a point, so its
children hung down from the middle of the row instead of sitting behind the
text. Giving the anchor the run's height fixed it. That the demo is a picture
is the only reason it was noticed.

### The document, and the trap in designing it Wayland-first

`src/document.zig` is §2 and §6 of the spec made executable: a byte buffer, a
selection, a provisional composition range, and a `canEditNow()` guard. It
links nothing and needs no window.

The shape is **Windows-first on purpose**, and the spec is blunt about why.
The same three keystrokes, `a` `w` `s` producing `ă`, arrive two ways:

```
Wayland:  preedit is a SEPARATE STRING. It never enters the document.
Windows:  the processor WRITES INTO THE DOCUMENT and marks it provisional.
```

The Windows shape can represent Wayland — leave the range unused — and the
Wayland shape cannot represent Windows at all. Spike B designed Wayland-first
and produced a model spike E could not use. So the document carries the
provisional range, the preedit sits beside it, and one function returns what
both paths need:

```zig
const shown = try doc.displayText(&scratch);
// shown.text      the string to lay out
// shown.composing the byte range that is provisional, or null
```

On Windows that is the document unchanged with the range it was given; on
Wayland the preedit is spliced in at the caret and the range says where it
landed. Nothing downstream learns which protocol it is talking to. Both spikes'
logged event sequences are transcribed into tests, and they are the test this
file exists to pass.

An edit reports its extent in **all three units at once**, computed where both
the old text and the new one exist:

```zig
pub const Edit = struct { bytes: Extent, chars: Extent, utf16: Extent };
```

That is not belt and braces. `old_end` can only be converted against the text
as it was, so a caller that kept bytes and converted later would convert it
against the wrong string — a bug that does not crash and surfaces as a screen
reader reading the wrong span. TSF's `(acpStart, acpOldEnd, acpNewEnd)` is
`utf16`; AT-SPI's `(start, length)` is `chars`.

The edits refuse what §6 says they must: the application cannot edit while a
processor holds a lock or a composition is active, and a processor cannot write
under a read-only lock. The lock *queue* — a request arriving while a lock is
held has to be deferred, and the drain has to be a loop because a request can
be queued from inside a deferred grant — belongs to the TSF adapter, which is
the only thing with a `RequestLock` to answer.

Two things are in bytes and aligned anyway rather than trusted:
`delete_surrounding_text`'s counts, because a compositor is another process and
a count that splits a character leaves the buffer holding invalid UTF-8; and
backspace, which deletes a character rather than a byte for the same reason.

![a Telex composition in progress: tiếng Vi committed, ệt provisional and underlined](docs/demo-composition.png)

The second field in the demo is that document, with a Telex composition caught
mid-word: `tiếng Vi` committed, `ệt` provisional and underlined, the caret after
it. All four spikes could compose text and none could draw it; this is the
first picture of it. The image is a 3× nearest-neighbour crop written by
`zig build demo` from the same framebuffer as the screenshot above, because a
one-pixel underline in a 900×560 image is a claim nobody can check.

### Text on Metal

The Metal backend has the glyph atlas now: an `R8Unorm` texture, `setAtlas`,
and the textured branch transcribed into `quad.metal` against
`texture2d<float>::read`, Metal's `texelFetch`. `gpu-demo` therefore draws the
same interface on both backends, and on an Apple M1 Pro:

```
631 quads, 37860 bytes uploaded with no repacking
589 of those quads are glyphs, from a 512x512 atlas

GPU vs software reference, 504000 pixels:
  largest channel difference   1
of which 37803 pixels are covered by a glyph:
  largest channel difference   1
  glyph pixels differing by > 1 0
```

`test-gpu` carries the same bit-exactness test as Vulkan's — a diagonal atlas,
so transposed or off-by-one texel addressing cannot pass — and it passes.

The macOS *window* still draws the grey bars, for the reason below: it is a
Retina window, and a glyph cannot be scaled.

Getting the text stack to build on a Mac at all found a fault in `build.zig`.
It asks `pkg-config` where FreeType and HarfBuzz keep their headers, but
`runAllowFail` does not search `PATH` for the program it runs, so the question
had never once been asked: the Linux fallback paths answered it everywhere,
correctly on Debian by coincidence. The program is now resolved first.

One thing the Retina path already settles, though. `Quad.scaled` now asserts
that the quad is not textured, because **a glyph cannot be scaled**: its atlas
rectangle is a fixed number of texels and one destination pixel reads one
texel, so doubling the destination would leave half the glyph outside its own
range. The answer on a 2× display is to shape at the device pixel size — a
13-point label is a 26-pixel font, not a 13-pixel one drawn twice as large.

### What text does not do yet

Line breaking, bidirectional text, and font fallback for a glyph the matched
family lacks. One shaped line is the unit here, and each of those is a separate
piece of work on top of it rather than something to half-do inside it.

Of the eight requirements in
[docs/text-and-accessibility.md](docs/text-and-accessibility.md), §1 (unit
conversion), §2 (the provisional range) and §6 (the edit guard) now exist, and
§7 exists in run coordinates. What does not: converting a caret rectangle from
run coordinates to *screen* coordinates, which needs the window to say where it
is; the adapters themselves, which is where §3, §4, §5 and §8 live; and any
keyboard input at all, so nothing yet drives the document except its tests and
the demo.

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
  mean channel difference      0.0034
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

The glyph atlas is a single-channel sampled image, and the renderer always has
one: a one-texel transparent atlas exists from `Renderer.init` so the fragment
shader's descriptor is valid before any text does. The alternative — two
pipelines, one with a sampler and one without — would mean switching pipeline
mid-frame to save a descriptor write that happens when glyphs are added, not
per frame. `setAtlas` uploads the whole atlas rather than a dirty rectangle, for
the same reason: 256 KB when the shaper finds a character nobody has typed
before is not on the frame path, and a second incremental system guarding it
would be maintaining bugs for nothing.

The compiled SPIR-V is committed and embedded in the binary, so building the
toolkit needs no shader compiler; only changing a shader does.
[src/gpu/shaders/README.md](src/gpu/shaders/README.md) records why they are
GLSL and not Zig — Zig 0.17's SPIR-V backend decorates builtins correctly but
emits no `Location` decoration for user-declared interface variables, so the
module it produces cannot be used in a graphics pipeline at all. Worth
establishing rather than assuming, because sharing one source with
`src/raster.zig` would have removed the duplication described above.

## The window

`zig build window` opens a Wayland window and renders the same interface into
it through a swapchain, at the display's refresh rate with no sleep anywhere in
the loop — FIFO present is the pacing. Move the pointer and the row under it
highlights; resize and the layout recomputes.

The highlight is the thesis made visible: hovering changes `Paint`, so it
cannot do layout work, and the program counts how often it does. One run of
`./zig-out/bin/window_demo --sweep`, which drives a synthetic pointer down the
list for 180 frames so that the counters are a measurement rather than a
person moving a mouse:

```
180 frames
  frames that did any layout work   0 (0.0%)
  frames that rebuilt the scene     25 (13.9%)
  mean CPU per frame                9.9 us
  mean CPU on the 155 frames that changed nothing   920 ns
```

The pointer moves on every one of those frames. Layout work happens on none of
them, and the scene is rebuilt only when the highlighted row actually changes.

Two notes on those numbers, because both are easy to misread. This binary is a
**debug build** — `zig build window` does not force `ReleaseFast`, and the
release figures are in `zig build bench`. And the mean per frame is dominated
by the 14% of frames that rebuild a 726-quad scene with 685 glyphs in it, not
by anything the other 86% do.

> **A correction.** An earlier version of this file quoted 787 ns and 256 ns
> here. Those do not reproduce. Re-running the same commit on the same machine
> today gives 965–1 246 ns for the unchanged-frame figure, and the current code
> gives 815–1 168 ns over seven runs — the same range, so adding text cost
> nothing on an idle frame. The 256 ns was one lucky sample reported as if it
> were the number. A single run of a sub-microsecond figure under a compositor
> is not a measurement; the range above is.

### The bottleneck moved, and measuring it properly changed the answer

Once layout and scene build cost nanoseconds, the most expensive thing on an
idle frame was *hit testing*: 73 ns against 1.3 ns for the layout flush. The
obvious reading was that 73 ns does not matter. The obvious reading was wrong,
because 73 ns was measured on the wrong shape.

`hitTest` scanned every child of each element on the path, so its cost is the
**widest sibling list**, not the element count — and a long list is one parent
with ten thousand children. On a tree of the same size shaped that way:

| | before | after |
| --- | --- | --- |
| 8 columns of 51 rows | 73.2 ns | **12.7 ns** |
| 10 000 rows under one parent | 16 910 ns | **10.7 ns** |

The fix is a binary search, and what makes it correct is an invariant the
layout engine already guarantees: a non-wrapping container places its children
by prefix scan along its main axis, so their ranges increase and never overlap
and at most one can contain the point. A wrapping container breaks that — its
lines share a main range — and is scanned.

That invariant is a property of `positionChildren`, not of the type system, so
a randomised test compares the binary search against the scan it replaced over
16 000 points on trees containing wrapping containers, overflowing lines,
zero-sized children and every alignment. The test also asserts that the search
path was actually taken, since containers under eight children are scanned and
the comparison would otherwise pass by proving nothing.

The 10 000-row case is now *faster* than the grid, because it is one binary
search at depth one instead of four levels of descent.

`--capture` copies the frame the compositor was actually handed out of the
swapchain and compares it to the software reference. **Largest channel
difference: 1**, the same as the offscreen path. That check is not redundant
with the offscreen one: a swapchain brings its own format, extent and channel
order, and none of those exist offscreen.

It also caught a bug this README used to describe as a feature. This machine's
surface offers `R8G8B8A8_UNORM`; where only `B8G8R8A8_UNORM` was available,
the vertex shader swapped red and blue "so the channels would not be crossed".
That swap *was* the crossing: a format names channels, it does not reorder what
the shader writes. The branch never ran here, and it took the Mac, where every
layer is BGRA, to make it suspect. Run under lavapipe with a headless weston,
which offers only `B8G8R8A8_UNORM`, `--capture` reported **208**; with the swap
removed, **1**. The byte order now matters only to the capture, which reorders
when it copies the frame out.

![the frame the compositor was handed](docs/demo-window.png)

## macOS

Metal and AppKit, both reached through the Objective-C runtime: Zig cannot read
Objective-C headers, so every call is `objc_msgSend` cast to the method's C
signature, in [src/platform/objc.zig](src/platform/objc.zig). The window
delegate is a class **defined at run time** with Zig functions as its methods,
which is the mechanism `NSTextInputClient` and `NSAccessibility` will need; it
is done first where it is two methods long.

Metal rather than MoltenVK: MoltenVK would have reused the Vulkan backend
unchanged, at the price of a dependency not on a stock Mac and a translation
layer in front of the only GPU API Apple supports. The `CAMetalLayer` Metal
presents into is also the layer tier C composes native views beside, so it had
to be understood directly either way.

The Metal backend exposes the same offscreen surface as the Vulkan one, so
`tools/gpu_demo.zig` is one program for both. On an Apple M1 Pro:

```
GPU vs software reference, 504000 pixels:
  largest channel difference   1
  mean channel difference      0.0008
  pixels differing by > 1      0 (0.000%)
```

The same figures as RADV, to four decimal places. The shader is a third
transcription of the distance field, in Metal Shading Language, and **fast math
is turned off** for it: Metal enables it by default, and it licenses the
compiler to disagree with IEEE 754 in exactly the way a reference comparison
exists to catch.

The window is Retina, which Wayland's was not: the tree is laid out in
**points**, the drawables are two pixels per point, and the vertex shader scales
every length in the quad so the distance field is evaluated in pixels.
`--capture` compares the presented 1800x1120 frame against the reference drawn
at the same scale: **largest channel difference 1**, and still 1 after the
window is resized.

![the frame the window server was handed, at two pixels per point](docs/demo-window-macos.png)

`./zig-out/bin/window_demo --sweep` built with `-Doptimize=ReleaseFast`:

```
180 frames in 1.51 s (119.4 per second; pacing is the display's, there is no sleep)
  frames that did any layout work   0 (0.0%)
  frames that rebuilt the scene     25 (13.9%)
  mean CPU on the 155 frames that changed nothing   1306 ns
```

Pacing is the 120 Hz display's: `nextDrawable` blocks when every drawable is
queued, which is FIFO present by another name. The layout counter is the same
zero as on Linux.

### Three things the Mac measured that were not expected

**The idle frame is cold cache, not work.** 1.3 us is five times the Linux
figure, so it was taken apart. Not the clock: macOS's `clock_gettime(MONOTONIC)`
turned out to have microsecond resolution, which is why the demos use
`CLOCK_UPTIME_RAW`. Not the scheduler: the thread is already at
user-interactive QoS. Running the same hit test, flush and scene build a
*second* time inside the same frame costs **130-153 ns**, against 1 500-2 000 ns
for the first pass. About 90% of the idle frame is the caches and branch
predictors the event pump and the Metal calls left behind. The toolkit's own
work is the 130 ns.

**Channel order is a name, not a reordering.** A `CAMetalLayer` offers
`BGRA8Unorm` and no eight-bit RGBA format, so every Mac meets the case the
Vulkan backend used to handle by swapping red and blue in the shader. Doing the
same here made the presented frame differ from the reference by **208 of 255 on
98.5% of its pixels**: a format names channels, and the shader's red lands in
the red channel wherever the format stores it. Only the copy out to RGBA swaps.
The Vulkan swap was the same bug, confirmed and removed; see the window section
above.

**Not needing a shader compiler moves the cost to start-up.** The Metal source
is compiled by `newLibraryWithSource:` at run time, because the build should
need nothing beyond the SDK, and in Xcode 26 the Metal compiler is a separate
download. A cold compile is **43-47 ms** (238 ms the first time the compiler
service itself starts); once the system's shader cache has it, **0.6 ms**.
Shipping a precompiled `.metallib` is the fix when it matters, and is not done
yet.

### Not done on macOS

- Text in the window. The renderer draws glyphs exactly; what is missing is
  shaping at the device pixel size, so that a Retina window gets glyphs
  rasterised for two pixels per point rather than none.
- Live resize. While the user drags a window edge AppKit runs its own event
  loop inside `sendEvent:`, and this loop does not draw until it returns.
  Untested; rendering from the resize callback or a display link is the fix.
- `NSTextInputClient` and `NSAccessibility` — the spikes Linux and Windows have.
- Intel Macs. The `objc_msgSend_stret` path for large struct returns compiles
  and has never run.
- `tools/window_demo_macos.zig` duplicates the loop in `window_demo.zig`. They
  should become one program over a platform interface once there is a third
  platform to tell what that interface is.

## What it is meant to be

A retained element tree with **element-level** reactivity, a real text stack
(shaping, bidi, font fallback, IME), and accessibility treated as a first-class
concern rather than an afterthought. Shaping and glyph rendering exist; bidi,
fallback, line breaking, IME and accessibility do not yet, though four spikes
have established what they require.

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
