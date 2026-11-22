# Spike B — Wayland IME for a self-drawn text field

[docs/native-vs-drawn.md](../../docs/native-vs-drawn.md) commits this project to
drawing its own widgets while speaking the platform's input protocols, and says
plainly that if that input work is merely adequate the whole argument collapses.
This spike tests the hardest part of it before any widget code exists.

**It does not draw text.** The window is a solid colour. Rendering a text field
is known-solvable — run 8 of
[zig-uikit-bench](https://github.com/hivepaas/zig-uikit-bench) measured HarfBuzz
shaping at 56 ns/char — and it is not the risk. The risk is the protocol state
machine, so the document state is dumped to the terminal where it can be checked
character by character.

## Build and run

Needs `wayland-scanner`, `wayland-protocols`, `libwayland-client`, `libxkbcommon`,
a Wayland session, and Zig 0.17.

```sh
zig build
./zig-out/bin/ime-wayland --probe   # check protocol availability, no window
./zig-out/bin/ime-wayland           # open the window and type into it
```

`--probe` is useful on its own: if `zwp_text_input_manager_v3` is absent, Wayland
IME is impossible for *any* client on that compositor, not just this one.

## Why Vietnamese is the test case

Not convenience. Telex composes diacritics by **retroactively rewriting letters
already typed**: `a` then `w` becomes `ă`, and `a` `w` `s` becomes `ắ`. That
exercises the two mistakes that matter:

1. **`delete_surrounding_text` lengths are in bytes**, not codepoints and not
   characters. `ă` is two bytes. An implementation that treats them as characters
   passes every ASCII test and corrupts text the moment a diacritic appears.
2. **Preedit is rendered at the cursor but is not part of the document**, and
   must not appear in `set_surrounding_text`. Confusing the two produces doubled
   characters that only show up mid-composition.

Neither bug is reachable from an English-only test. Chinese and Japanese add a
candidate window, which is a UI problem; Vietnamese isolates the protocol
problem, which is harder to get right and silently corrupts data when wrong.

Set up with `ibus-bamboo` and the Bamboo engine selected.

## What to watch for while typing

- `preedit_string` arrives and the `doc` line does **not** change.
- `delete_surrounding_text(before=N)` where N is a **byte** count, and the
  resulting `doc` still reads correctly.
- The `doc` line always matches what your eyes expect, at every keystroke.
- No `!!` lines. `!! ... snapped to ... at UTF-8 boundary` means a length would
  have split a codepoint.

On exit it prints a tally of each event type, the largest `delete_surrounding_text`
seen, and the final document in bytes and codepoints.

## Verified so far

On Ubuntu 26.04, GNOME 49 / Mutter, Wayland, ibus 1.5.34-rc2, ibus-bamboo 0.8.5:

- all five required globals bind, including `zwp_text_input_manager_v3`
- the window maps, takes keyboard focus, and `enable` + `commit` activates the
  input context
- the event loop is quiet at rest

**Still unverified: actual composition.** That needs a human typing Telex into
the window and reading the dump. Everything above is necessary and none of it is
sufficient.

## Two protocol traps this spike already hit

**An unconditional resync on `done` is an infinite loop.** The natural reading of
"the document changed, so re-send surrounding text" leads to calling
`set_surrounding_text` + `commit` from the `done` handler. Our own `commit` makes
the compositor emit another `done`, and the first version of this spike spun at
full speed on an empty document. Only a change to the **document** may trigger a
resync; a preedit change must not, because preedit is not part of surrounding
text and there is nothing new to tell the IME.

**Every request is double-buffered.** `enable` does nothing without `commit`, and
`preedit_string` / `commit_string` / `delete_surrounding_text` are pending state
applied only on `done`. Applying each event as it arrives is the bug that
produces flicker and doubled characters during composition. The application order
on `done` is fixed by the protocol: drop the old preedit, delete surrounding text,
insert the commit string, recompute surrounding text, install the new preedit.
Doing the delete after the insert is what makes Telex eat the wrong character,
because ibus-bamboo asks to delete what is already committed *before* committing
its replacement.

## Not covered

- **X11.** XIM, or ibus over DBus. A separate problem of similar size.
- **macOS / Windows.** `NSTextInputClient` and TSF. Each is its own spike.
- **Candidate window placement.** `set_cursor_rectangle` reports a fixed box
  because there is no text layout here, so a candidate window appears at the
  window origin instead of at the caret. Correct placement needs the glyph
  position, which needs the text stack.
- **Accessibility.** The other half of tier A. AT-SPI is available on this
  machine (`atspi-2` 2.60.4) and is not touched yet.
- **Selection.** `set_surrounding_text` takes a cursor *and* an anchor; this
  spike keeps them equal, so selection replacement is untested.
- **Stale serials.** A `done` whose serial does not match our commit count is
  logged and applied anyway. Whether that is right under rapid typing is
  unverified.

## Zig 0.17 churn, continued

Five more breaking changes, on top of the six the benchmark repo recorded:

| # | Change |
| --- | --- |
| 7 | `exe.addCSourceFile` gone — C sources attach to the module, not the Compile step |
| 8 | `b.args` removed from `std.Build` |
| 9 | `std.process.args()` **and** `std.os.argv` both removed; `main` now takes `std.process.Init.Minimal` |
| 10 | `std.posix.close` and `std.posix.ftruncate` removed |
| 11 | `std.posix.PROT` changed from integer flags to a packed struct of bools |

Running total: **11 breaking changes across roughly 2 200 lines** written against
0.17. Three of the five above were in argument and file-descriptor handling,
which is to say in the parts of the standard library a GUI toolkit cannot avoid.
