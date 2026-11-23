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

### Orca reads it

Tested with Orca running (`toolkit-accessibility` temporarily enabled, speech
disabled, both restored afterwards). This closes the wire-format question that
was previously open here.

**Orca lists the application**, alongside gnome-shell, Chrome, VS Code and
Nautilus:

```
Desktop has 12 app(s):
  pid: 115546   zig-uikit a11y spike   ./zig-out/bin/a11y-atspi
```

**Orca decoded every text event correctly**, from its own debug log:

```
CLIPBOARD PRESENTER: Possible change event object:text-changed:insert
  for [entry: 'Name'] in zig-uikit a11y spike (zig-uikit 0.0.0-spike) (0, 6, tiếng)
CLIPBOARD PRESENTER: Possible change event object:text-changed:insert
  for [entry: 'Name'] in zig-uikit a11y spike (zig-uikit 0.0.0-spike) (6, 4, việt)
CLIPBOARD PRESENTER: Possible change event object:text-changed:delete
  for [entry: 'Name'] in zig-uikit a11y spike (zig-uikit 0.0.0-spike) (9, 1, t)
```

`(6, 4, việt)` is the whole character-offset argument, confirmed by a real
screen reader: Orca placed the insertion at character 6, where the byte offset
is 8.

It also recognised the structure and reacted:

```
AXUtilities: [frame: 'Spike window'] from [application: 'zig-uikit a11y spike']
             can be active window
DEFAULT: Setting up commands for [application: 'zig-uikit a11y spike']
EVENT MANAGER: App for event source is [application: 'zig-uikit a11y spike']
```

And it queried back — 31 calls in one session (`GetAttributes` ×11,
`Properties.Get` ×11, `GetRole` ×3, `GetState`, `GetRelationSet`), with **zero
unhandled methods**.

**`siiv(so)` is the right signature for applications.** The registry's own
events use `siiva{sv}`, both strings exist in `libatspi.so.0`, and Orca consumed
`siiv(so)` without complaint. The question is settled.

### Two things Orca demanded that guesswork had missed

Running Orca found two gaps that reading the protocol had not:

**1. `org.a11y.atspi.Cache.GetItems`, at `/org/a11y/atspi/cache`.** This is
Orca's *first* move on a new application — it pulls the whole tree in one call
rather than walking `Accessible` node by node. The first Orca run failed with

```
AT-SPI: Error in GetItems, error=Method "GetItems" with signature ""
        on interface "org.a11y.atspi.Cache" doesn't exist
```

and the application was listed by name and then unreadable. Note the path is a
*sibling* of the accessible subtree, not inside it, so the DBus fallback had to
be registered one level higher at `/org/a11y/atspi` — otherwise the call never
even reaches the handler and libdbus answers the error itself.

The cache item signature is `((so)(so)(so)iiassusau)` — object, application,
parent, index in parent, child count, interfaces, name, role, description,
states — taken from the introspection XML embedded in
`libatk-bridge-2.0.so.0`, which is the reference implementation.

**2. `org.a11y.atspi.Application.GetApplicationBusAddress`.** Asked before Orca
reads anything. An empty string means "I am on the main accessibility bus". An
error here makes a client believe the app has a private bus it cannot reach.

### Correction: Orca does not listen for `focus:`

This spike previously emitted the deprecated `focus:` event, on the stated
belief that "Orca still listens for it, and real toolkits send both." **That is
false here.** With Orca running, `GetRegisteredEvents` returns 39 listeners and
`Focus:` is not among them — only `Object:StateChanged:Focused`. The emission
was removed; it was traffic to nobody.

The 39 listeners do include every other event this spike sends:
`Object:StateChanged:Focused`, `Object:TextChanged:Insert`,
`Object:TextChanged:Delete`, `Object:TextCaretMoved:`, `Window:Activate:`,
`Window:Deactivate:`, `Object:ChildrenChanged:Add`/`Remove`.

### Still absent

With Orca not running, `GetRegisteredEvents` returns an **empty array** — so
outside a test, every event this spike emits goes to zero listeners. A toolkit
that emits unconditionally floods the accessibility bus for the great majority
of users who run no assistive technology. This spike queries the count and
reports it; it does not yet gate emission on it. Real implementations do.

Also absent:

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
