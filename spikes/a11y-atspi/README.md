# Spike C — AT-SPI accessibility for a self-drawn widget tree

The other half of tier A from [docs/native-vs-drawn.md](../../docs/native-vs-drawn.md),
and the half nobody in the Zig ecosystem has touched: dvui has no accessibility,
and `ddalcu/zigui` has no accessibility files at all. The design note says that
if this work is merely adequate the self-drawn argument collapses — a widget that
looks native but is invisible to a screen reader is strictly worse than the
native widget it imitates.

**Result: feasible.** 829 lines of Zig implement enough of AT-SPI for a text
field, the running registry accepts the registration, and the exported tree
answers screen-reader queries correctly — including the one that matters.

## There is no shortcut

Three routes exist and two are closed:

- **ATK + at-spi2-atk bridge** — requires being a GTK application.
- **`libatspi`** — the *client* library, for screen readers and inspection tools.
  Not for applications exposing a tree.
- **The AT-SPI DBus interfaces, directly** — the only option for an app that
  draws its own widgets. This is what AccessKit's Linux backend does, and what
  this spike does.

## The finding that matters

```
AT-SPI text offsets are in CHARACTERS.
zwp_text_input_v3 offsets are in BYTES.
```

The same text field must speak bytes to the input method and characters to the
screen reader. [Spike B](../ime-wayland/)'s document model is byte-indexed
throughout, deliberately, because that is what the IME needs — so every offset
crossing into AT-SPI has to be converted.

Getting it backwards does not crash and is invisible in ASCII. The screen reader
simply reads the wrong characters.

The entry's text is Vietnamese so the two numbers cannot coincide by accident:
`tiếng việt` is **14 bytes and 10 characters**. Verified live over DBus:

| query | returned | why it is the right answer |
| --- | --- | --- |
| `Text.CharacterCount` | `10` | characters, not the 14 bytes |
| `Text.GetText(0, 10)` | `tiếng việt` | whole string |
| `Text.GetText(0, 5)` | `tiếng` | 5 **characters** = 7 bytes. Byte offsets would have cut `tiế` or split a codepoint |
| `Text.GetText(6, 10)` | `việt` | offsets 6–10 land correctly past two 3-byte characters |

In the file, exactly two functions change units (`charCount`, `charToByte`) and
no offset changes units anywhere else. That is the only discipline that makes
this survivable.

## Verified

Ubuntu 26.04, GNOME / Mutter, at-spi2-core 2.60.4, registry running.

```
Socket.Embed accepted by the registry
our bus name: :1.55
```

- **The desktop tree includes us.** `org.a11y.atspi.Registry` →
  `Accessible.GetChildren` on the desktop root lists our bus name alongside the
  14 other live applications. Registration is real, not just exported objects
  nobody looks at.
- Roles correct: `application` (75) → `frame` (23) → `entry` (79).
- `GetInterfaces` on the entry returns Accessible, Component, Text.
- `Component.GetExtents` returns `(108, 140, 300, 28)`.
- `GetState` returns `1191188864`, which is bit-exact for EDITABLE(7),
  ENABLED(8), FOCUSABLE(11), FOCUSED(12), SENSITIVE(24), SHOWING(25),
  SINGLE_LINE(26), VISIBLE(30) — checked arithmetically, not eyeballed.
- 27 DBus calls served in the first session with no unhandled methods.

Note that `org.gnome.desktop.interface toolkit-accessibility` is **`false`** on
this machine. That gates the GTK bridge; the AT-SPI bus and registry run anyway
and accepted us regardless. A direct implementation does not depend on that
setting.

## Not verified, and the gap is significant

**A screen reader has not read this aloud.** Registration and queries work, but
Orca needs *events* — `object:state-changed`, `object:text-caret-moved`,
`object:text-changed`, `focus:` — emitted as DBus signals on
`org.a11y.atspi.Event.*`. None are implemented. A static tree that answers
queries is necessary and not sufficient, and the remaining work is not trivial:
event emission is where the a11y bus traffic actually lives, and getting it
wrong means either a silent screen reader or a flooded one.

Also absent:

- `org.a11y.atspi.Cache`, which real toolkits implement so clients can fetch the
  tree in bulk instead of walking it one call at a time.
- `EditableText`, so the screen reader cannot modify the field.
- Focus tracking, selection, and any connection to a live document — the tree is
  static and hardcoded.
- Hit testing (`GetAccessibleAtPoint`).
- Windows (UI Automation) and macOS (NSAccessibility). Each is its own spike.

## Build and run

```sh
zig build
./zig-out/bin/a11y-atspi --seconds=120
```

It prints ready-to-paste `busctl` and `gdbus` commands with the live bus address
and name. Without `--seconds` it runs until killed.

## Zig friction worth recording

`DBusError` carries five one-bit bitfields, and Zig has no C bitfield support, so
`translate-c` renders the whole struct as `opaque`. It had to be redeclared in
Zig and the layout verified against the C compiler (`sizeof` 32, `align` 8,
`message` at offset 8), with `comptime` assertions to keep it honest.

This is the first thing in these spikes that `translate-c` could not handle at
all. It is not hard, but a toolkit binding C libraries will keep meeting it, and
each occurrence is a hand-maintained layout that no compiler will check against
the real header.

No new breaking changes in this spike; the running total from
[zig-uikit-bench](https://github.com/hivepaas/zig-uikit-bench) and spike B stands
at **11 across roughly 3 000 lines**.
