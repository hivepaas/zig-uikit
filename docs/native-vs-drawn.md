# Native components vs. self-drawn components

**Status:** accepted · **Date:** 2026-11-22

## The question

A GPU UI toolkit draws its own pixels. But some things are supposed to *be*
native: a text field that respects the system IME, a file picker that looks
like the one in every other app, an embedded web view.

So: should the toolkit ship two kinds of component — real OS widgets alongside
self-drawn ones — and let the caller choose?

## Decision

**No.** There is one self-drawn widget set, plus one escape hatch.

Instead of two kinds of component, the problem splits into three tiers, and
only the third one is genuinely hard:

| Tier | Mechanism | Covers | Cost |
| --- | --- | --- | --- |
| **A** | Self-drawn pixels, **native protocol** | Text input and IME, accessibility, keyboard navigation, clipboard, drag & drop, text selection | Moderate — this is the bulk of the work |
| **B** | Call the OS; it owns the surface | File / colour / print dialogs, the macOS menu bar, context menus, tray icons, notifications | Nearly free |
| **C** | Embedded native child view | Web view, hardware video decode, native map, camera preview | Expensive and constrained |

Tier C gets exactly one primitive in core. Everything built on it lives outside
core.

## Why: "native" is mostly semantics, not drawing

The common framing — native widgets versus drawn widgets — conflates two
separate things. A text field does not need to *be* an `NSTextField` to behave
like one. It needs to speak the platform's input protocol:

- macOS / iOS — `NSTextInputClient`
- Windows — Text Services Framework, or IMM32
- Linux — an input-method module, reaching ibus or fcitx

Implement the protocol and draw the field yourself, and the pixels are yours
while the behaviour is real. Accessibility works the same way: an a11y adapter
draws nothing at all, it exposes a native accessibility tree (NSAccessibility,
UI Automation, AT-SPI) describing content you rendered. The screen reader sees
native semantics; the user sees your pixels.

This is not theoretical. It is what GPUI does for text input, and what
[AccessKit](https://github.com/AccessKit/accesskit) does for accessibility
across several Rust toolkits.

Recognising this removes roughly all of the pressure to embed real widgets.

## Why tier B is cheap

Tier B is routinely filed under "hard" and it is not. A save dialog, a colour
picker, the macOS menu bar, a context menu, a tray icon — each of these is a
**separate top-level surface owned by the OS**. None of them lives inside the
toolkit's scene, so none of them creates a compositing conflict. They are
function calls.

They also carry disproportionate weight in whether an application *feels*
native, because they are the parts a user has already seen in every other
application on the machine. Cheap to implement, highly visible: do them early.

## Tier C: hole punching

At a native element the scene splits into `[quads below] → [native hole] →
[quads above]`. Whether those layers interleave correctly is a per-platform
question:

| Platform | Mechanism | Interleaves correctly |
| --- | --- | --- |
| macOS | `CALayer` tree — `CAMetalLayer` plus sibling layers | Yes — the best case |
| Wayland | `wl_subsurface` | Yes — purpose-built for this |
| Windows | DirectComposition visual tree | Yes |
| Windows | `WS_CHILD` HWND | No — always on top |
| X11 | Child window | No |

The constraints that remain on tier C are real and should be stated plainly in
the API docs, not discovered by users: no rotation, no scale, no opacity on a
native child; rectangular clipping only; and the OS routes input to the child
directly, bypassing the toolkit's own hit testing and focus model.

### Scroll synchronisation is solvable, and that is the opportunity

Embedded native views in Flutter visibly lag the surrounding content while
scrolling. This is widely treated as inherent to the approach. It is not — it
follows from updating the native view's position on a different frame, and a
different thread, from the GPU frame it should match.

All three of the well-behaved mechanisms above support an atomic commit:

- macOS — `CATransaction`: move the layer in the same transaction as the frame
- Wayland — `wl_subsurface.set_sync`: the subsurface commits atomically with its parent
- Windows — commit the DirectComposition visual tree with the present

Design for atomic commit from the first commit and a native child never trails
by a frame. Retrofitting it later means changing the threading model, which is
why Flutter has not.

This is a narrow, concrete, verifiable claim — the kind worth making. It is not
a performance claim.

## Layout: native elements size themselves

A native child's intrinsic size is decided by the OS, retrieved at runtime
(`fittingSize`, theme metrics), and **changes when the user changes system
settings** — text size, display scale, or theme.

Under a frame arena that rebuilds the tree every frame, this is awkward. Under
a retained tree with per-element dirty tracking — the architecture this project
is already committed to, for unrelated reasons — it falls out cleanly: an
appearance change marks the affected elements dirty and relayout is local to
them.

## The empirical record

We could not find a toolkit that successfully maintained **two parallel widget
sets**. Every one picked a lane:

- **Native widgets only** — wxWidgets, SWT, React Native. The price is an API
  pinned to the lowest common denominator across platforms, and a long tail of
  platform-specific behavioural bugs.
- **Self-drawn** — Flutter, Avalonia, Qt Quick, egui, GPUI. Each keeps a narrow
  escape hatch for tier C.

Qt is the instructive case: Qt Widgets paints in platform styles, and Qt Quick
dropped native widgets entirely. The movement was *away* from native, by a team
with the resources to go either way.

The failure mode is not technical difficulty. It is **drift**. Two
implementations of one widget diverge in layout metrics, in event ordering, in
focus behaviour — and the resulting bugs reproduce on one platform only.

## What this means in practice

1. One self-drawn widget set, with tier A done properly — real IME, real
   accessibility. Not an approximation of either.
2. Tier B wired directly to the OS. Early, because it is cheap and users feel it.
3. One tier C primitive in core:

   ```zig
   pub const NativeSurface = struct {
       reserve: Rect,
       attach: *const fn (PlatformHandle, Rect) void,
       intrinsic: ?*const fn () Size,
   };
   ```

   Web views and video surfaces are separate packages built on it. They do not
   belong in core, and core does not depend on them.

Callers get both kinds of behaviour where they actually need them, without the
toolkit carrying two implementations of every widget.

## Consequences

- Widgets will not be pixel-identical to the host platform's own. This is
  accepted; Flutter, Avalonia and Qt Quick made the same trade.
- Tier A becomes load-bearing. If the IME and accessibility work is merely
  adequate, the central argument for this design collapses — which is why those
  are treated as core, not as plugins.
- Atomic commit must be designed into the frame pipeline now, before the
  pipeline exists.
