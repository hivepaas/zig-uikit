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
- **The registry assigns us an application id**, and we now accept it:
  `registry assigned Application.Id = 37`. Zero unhandled methods.

That last point was a real hole, and logging found it rather than the spec did.
The first session logged one `(unhandled)` line — `org.freedesktop.DBus.Properties.Set`
on the root — which is the registry handing the application its id immediately
after `Embed`. We were accepting the registration and then refusing the id that
follows it, leaving us registered but anonymous. `Properties.Set` is now handled
(and replies with an empty method return, not a value). Printing every unhandled
method instead of silently returning `NOT_YET_HANDLED` is what surfaced it.

Note that `org.gnome.desktop.interface toolkit-accessibility` is **`false`** on
this machine. That gates the GTK bridge; the AT-SPI bus and registry run anyway
and accepted us regardless. A direct implementation does not depend on that
setting.

## Events

`./zig-out/bin/a11y-atspi --emit` replays [spike B](../ime-wayland/)'s actual
Telex session as accessibility events: the two commits ibus-bamboo really
produced, then a backspace.

Signal signature is `siiv(so)` — detail string, detail1, detail2, any_data
variant, then a reference to the emitting application. Confirmed from
`libatspi.so.0` rather than from memory, and the interface names
(`Event.Object`, `Event.Focus`, `Event.Window`) from `libatk-bridge-2.0.so.0`,
which is what a real ATK application emits through.

**The same character-offset rule applies to events, and this is where it bites.**
Captured with `dbus-monitor` on the a11y bus:

| edit | bytes / chars | emitted | note |
| --- | --- | --- | --- |
| insert `tiếng ` at 0 | 8 / 6 | `insert d1=0 d2=6` | length is 6 **characters**, not 8 bytes |
| insert `việt` at char 6 | 6 / 4 | `insert d1=6 d2=4` | offset is **6**, while its byte offset is 8 |
| backspace `t` | 1 / 1 | `delete d1=9 d2=1` | caret then moves to char 9 |

Byte offsets here would put a screen reader's caret two characters off, silently.

11 events emitted, all 11 decoded correctly by `dbus-monitor`:

```
path=/org/a11y/atspi/accessible/2; interface=org.a11y.atspi.Event.Object; member=TextChanged
   string "insert"
   int32 0
   int32 6
   variant       string "tiếng "
   struct { string ":1.22"; object path "/org/a11y/atspi/accessible/root" }
```

`focus:` is emitted alongside `object:state-changed:focused`. It is deprecated,
Orca still listens for it, and real toolkits send both.

### The registry announces us, unprompted

The capture caught something not emitted by this program at all. On `Embed`, the
registry itself broadcast our arrival to the desktop tree, and on exit withdrew
it:

```
sender=:1.1  path=.../accessible/root  member=ChildrenChanged
   string "add"     int32 11
   ...
   string "remove"
```

That is third-party confirmation that registration is real — the registry put us
at index 11 of the desktop and told every listening client.

### One wire-format question left open

The registry's own `ChildrenChanged` uses a **different** signature from the one
this spike emits: `siiva{sv}`, with the object reference inside the variant and a
trailing properties dictionary, instead of `siiv(so)`. Both strings are present
in `libatspi.so.0`.

`siiv(so)` is the documented application form, the bus accepted it, and
`dbus-monitor` decoded it. Whether a current Orca *requires* the extended form
from applications is **unverified**. Resolving it needs either Orca running or a
bridged GTK application to compare against — and on this machine
`toolkit-accessibility` is `false`, so no GTK app is currently emitting anything
to compare with.

## Not verified, and the gap is still real

**A screen reader has not read this aloud.** Events are now on the bus in a form
the bus accepts, but nothing has consumed them. Orca was not running during any
of these sessions, and `GetRegisteredEvents` returned an empty array throughout —
so these events went out to zero listeners.

That last point is itself a design finding: a toolkit that emits
unconditionally floods the accessibility bus for every user who has no assistive
technology running, which is nearly all of them. This spike queries
`GetRegisteredEvents` and reports the count, but does not yet gate emission on
it. Real implementations do.

Also absent:

- `org.a11y.atspi.Cache`, which real toolkits implement so clients can fetch the
  tree in bulk instead of walking it one call at a time.
- `EditableText`, so the screen reader cannot modify the field.
- Any connection to a live document — `--emit` replays a scripted sequence, and
  the tree is otherwise static.
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
