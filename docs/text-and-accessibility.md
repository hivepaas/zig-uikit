# Text and accessibility: constraints from four working spikes

**Status:** accepted · **Date:** 2026-11-24

[docs/native-vs-drawn.md](native-vs-drawn.md) committed this project to drawing
its own widgets while speaking the platform's input and accessibility
protocols, and called that work "tier A" and load-bearing. Four spikes then
implemented it twice over, on Linux and Windows, far enough that a screen reader
reads the tree and an input method composes text:

| spike | what runs | evidence |
| --- | --- | --- |
| [B](../spikes/ime-wayland/) | `zwp_text_input_v3` | Telex composes; 28 preedit events; 21/21 self test |
| [C](../spikes/a11y-atspi/) | AT-SPI over DBus | Orca lists the app and decodes its text events |
| [D](../spikes/uia-windows/) | UI Automation provider | Narrator makes 93 calls, ending in `get_Value` |
| [E](../spikes/tsf-windows/) | TSF `ITextStoreACP` | Telex composes; 23 `SetText`; 17/17 self test |

This note is the specification those four produced. Every requirement below is
something a spike measured, not something the protocols' documentation states.

## 1. Three offset units, four protocols

```
zwp_text_input_v3   UTF-8 bytes
AT-SPI              codepoints
Windows BSTR (UIA)  UTF-16 code units
TSF "ACP"           UTF-16 code units
```

`tiếng việt 🇻🇳` is **23 bytes, 13 codepoints, 15 UTF-16 code units**. ASCII
collapses all three to one number, Vietnamese separates bytes from codepoints,
and only a non-BMP character separates codepoints from UTF-16 units.

**Windows is internally consistent** — its accessibility and its input method
agree, so one unit serves both. **Linux is not**: `text-input-v3` counts bytes
while AT-SPI counts codepoints, so a Linux text field must convert between its
own two platform protocols. Neither platform's documentation points this out.

### Requirement

The document stores **UTF-8 bytes** and indexes in bytes, because that is what
the IME protocol with no conversion available needs. Every offset leaving the
document converts at the boundary, and **conversion lives in exactly two
functions per unit**, nowhere else:

```zig
fn byteToChar(s: []const u8, b: usize) usize
fn charToByte(s: []const u8, c: usize) usize
fn byteToUtf16(s: []const u8, b: usize) usize
fn utf16ToByte(s: []const u8, u: usize) usize
```

Spike C enforced this rule and spike E's `SetText` shows why: the input
processor replaced range `0..1` to turn `a` into `ă`, which is correct in UTF-16
units and wrong in bytes. Getting a unit wrong does not crash. It silently
reads or edits the wrong characters, on exactly one platform.

An edit must be able to report its extent in whichever unit the caller wants:
AT-SPI wants `(start, length)` in characters, TSF wants
`(acpStart, acpOldEnd, acpNewEnd)` in UTF-16 units.

## 2. Composition is a provisional range, not a side string

```
Wayland:  preedit is a SEPARATE STRING. It never enters the document.
Windows:  the input processor WRITES INTO THE DOCUMENT and marks it provisional.
```

The same three keystrokes, `a` `w` `s`:

```
spike B    preedit_string("a")      doc=""          <- document untouched
           preedit_string("ă")      doc=""
           commit_string("ă")       doc="ă"

spike E    OnStartComposition
           SetText(0..0 <- "a")     doc="a"   COMPOSING
           SetText(0..1 <- "ă")     doc="ă"   COMPOSING
           OnEndComposition                   <- committed
```

### Requirement

The document carries an **optional provisional range** in bytes, plus a flag for
whether a composition is active. Wayland then never sets the range and keeps its
preedit beside the document; Windows sets it and the text lives inside.

This direction is forced. The Windows shape can represent Wayland — leave the
range unused — while the Wayland shape cannot represent Windows at all.
**Designing Wayland-first produces a model that cannot express what TSF does**,
which is what spike B did and spike E caught.

Rendering follows: the composing range is drawn differently (underlined) but is
part of the laid-out text, so text layout must accept a style override on a byte
range rather than a separate string appended at the caret.

## 3. The two accessibility backends want opposite things

| | AT-SPI (Linux) | UIA (Windows) |
| --- | --- | --- |
| direction | **push**, out of process | **pull**, in process |
| transport | DBus, a separate bus | COM vtables, direct calls |
| registration | registry + `Socket.Embed` | none |
| reading the tree | one `Cache.GetItems`, serialised | per-accessor, on demand |
| **cost for a 2-node tree** | **1 call** | **93 calls** |

Spike D measured that 93. `Navigate(Parent)` from the root was called 18 times,
each returning null, and `get_HostRawElementProvider` 26 times — the second
most-called method, which no reading of the protocol would predict.

### Requirement

One internal accessibility tree feeds both. The spikes deliberately used the
same `Node` shape on each side and it held: role, name, screen bounds, state
set, text content, parent, children, index in parent, stable id. Roles differ
(UIA control types against AT-SPI roles) and nothing else does.

But the adapters share nothing beyond that data, and they need opposite
optimisations:

- **AT-SPI** needs a cheap **whole-tree serialisation**. Implementing
  `Cache.GetItems` is not optional: without it Orca lists the application by
  name and then cannot read it, which is what spike C's first Orca run showed.
- **UIA** needs every **individual accessor** to be cheap, because they are
  called constantly and without caching.

So the internal tree must support both a bulk snapshot and cheap single-node
queries. A design that only does one will be slow or broken on one platform.

## 4. "Is anyone listening" is only answerable on Linux

- **AT-SPI** — `GetRegisteredEvents` returned a genuinely **empty array** with no
  screen reader running, and 39 entries with Orca running. A precise gate.
- **UIA** — `UiaClientsAreListening()` returned **true on an idle Windows 11
  desktop with no screen reader at all**, because Windows itself has UIA
  clients.

### Requirement

Gate accessibility work on the query where it is trustworthy, and do not rely on
it where it is not. This matters: emitting unconditionally floods the
accessibility bus for the large majority of users who run no assistive
technology, and the Windows equivalent wastes `BSTR` and `VARIANT` construction
on every event.

Call `UiaClientsAreListening()` anyway — it is one cheap call and it is correct
when it returns false.

## 5. Lifetimes differ in kind, not degree

Out of process, a reference to a destroyed object is a DBus error. In process,
it is a use-after-free.

### Requirement

A UIA provider object must outlive the element it describes until every client
reference is released, and `UiaDisconnectProvider` must be called when the
element goes away. The spikes allocate providers statically and therefore defer
this question entirely; a real toolkit cannot.

This is the single largest piece of tier A that the spikes did **not** solve.

## 6. The lock protocol has no Wayland equivalent

Wayland's events are double-buffered and applied on `done` in a fixed order:
drop the old preedit, delete surrounding text, insert the commit string,
recompute surrounding text, install the new preedit. That is the whole protocol.

TSF adds read/write locks on the text store, and three rules the spikes had to
discover:

- A lock request arriving **while a lock is held** must be queued and granted
  after the current one unwinds, returning `TS_S_ASYNC`. Granting it immediately
  re-enters the input processor. A synchronous request in that situation gets
  `TS_E_SYNCHRONOUS`. The drain must be a **loop**, because a request can be
  queued from inside the deferred grant.
- Writes during a read-only lock must fail with `TS_E_NOLOCK`.
- **The application must not edit the document while the processor holds a lock,
  nor while a composition is active.** Doing so changes the document underneath
  a reader that believes it has exclusive access.

### Requirement

The document exposes a `canEditNow()` guard, and application-initiated edits —
a plain keystroke, Backspace, a caret move — are refused or deferred when it
returns false. Only application-initiated edits notify the accessibility and
input-method sinks; notifying a processor about its own edit is how notification
storms start.

## 7. Caret geometry is required, in screen coordinates

Three protocols ask the same question in three ways: `set_cursor_rectangle`
(Wayland), `GetTextExt` (TSF), `get_BoundingRectangle` (UIA). All three want
**screen** coordinates, not client coordinates, and UIA's is wrong in a way that
only shows up as a screen reader highlighting the wrong part of the desktop.

### Requirement

Text layout answers "screen rectangle of this byte range", and the a11y and IME
adapters convert their own units into bytes before asking. Until layout exists,
return `TS_E_NOLAYOUT` rather than `E_NOTIMPL` — some input processors abandon a
text store that answers `E_NOTIMPL`.

All four spikes report a fixed rectangle here, so candidate windows appear in the
wrong place. It is the most visible unfinished thing in them.

## 8. Focus is not what it looks like

`SetFocus` assigns keyboard focus within a thread; it does not make a window
foreground. Launched from a console, the console keeps the foreground, an input
method sees no focused text store, and nothing composes — **indistinguishable
from a broken `ITextStoreACP`**. Spike E lost three attempts to this.

On the accessibility side, modern Orca registers **no** bare `focus:` listener;
only `object:state-changed:focused`. Emitting the deprecated event is traffic to
nobody.

### Requirement

Window activation uses `BringWindowToTop` + `SetForegroundWindow` +
`SetActiveWindow` + `SetFocus` on Windows. Focus changes are announced as
`object:state-changed:focused` on Linux and `UIA_AutomationFocusChangedEventId`
on Windows.

## What this does not settle

- **macOS.** Both protocols are implemented in the toolkit rather than as
  spikes, and the README's macOS section has the measurements.
  `NSTextInputClient` (`src/input_client.zig`) confirmed §2's choice — macOS
  has the TSF shape — and then showed a third shape none of B–E met: Apple's
  Simple Telex **never marks text**, rewriting each syllable in place with an
  explicit UTF-16 replacement range. `NSAccessibility`
  (`src/access.zig`, `src/platform/macos_access.zig`) is pull and in process,
  like UIA, and adds two things to §3–§5: a pull client's queries are served
  on the main run loop, so a frame loop that blocks until vsync answers **one
  query per frame** (3.9 s to walk 76 nodes, 20-24 ms after the fix); and §5's
  lifetime problem does not arise, because a client holds a token that
  AppKit's server invalidates, and AppKit announces the destruction itself.
  "Is anyone listening" (§4) is answered precisely by whether any client has
  called in: none does, with none attached.
- **X11.** XIM or ibus over DBus, a separate problem of similar size to spike B.
- **Provider lifetimes** (§5), the largest gap.
- **Text layout** (§7), which everything in §1 and §7 ultimately depends on.
- **`ITextProvider`/`ITextRangeProvider`.** Spike D exposes `IValueProvider`,
  which gives a screen reader the whole string but no caret, no selection and no
  per-character navigation. UIA ranges are **opaque objects moved by `TextUnit`**
  rather than integer offsets — a fourth model, different again from §1's three.

## A note on how these were established

Two of the four spikes have self tests covering paths no real client drives:
spike B's `delete_surrounding_text` (ibus-bamboo mode 1 never sends it) and
spike E's queued lock (Telex never re-enters `RequestLock`). Both tests pass,
and both say in their own output that they prove the model and not that anything
drives it.

That distinction earned its keep. Running Orca found two gaps that reading the
AT-SPI protocol had not — `Cache.GetItems` and `GetApplicationBusAddress` — and
falsified a claim this project had written down about `focus:` events. Running
Narrator produced the 93 calls in §3. Neither was predictable from the
specifications.

The session logs are kept in each spike's `logs/` directory for that reason.
