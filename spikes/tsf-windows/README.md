# Spike E — Windows IME via the Text Services Framework

The last quarter of tier A, and the hardest. [Spike B](../ime-wayland/) did
Wayland IME with `zwp_text_input_v3`: six client requests, six events, one state
machine, about 700 lines. TSF asks the application to implement
**`ITextStoreACP` — twenty-nine methods** — plus a lock protocol, and to host a
COM thread manager. This spike is 1 013 lines and does less.

Cross-compiled on Linux like [spike D](../uia-windows/): Zig bundles mingw-w64's
`msctf.h` and `textstor.h`, so no MSVC and no Windows SDK.

## The finding that changes the text field's data model

```
Wayland: preedit is a SEPARATE STRING. It never enters the document.
Windows: composition text is WRITTEN INTO THE DOCUMENT by the input processor.
```

On Wayland the compositor sends `preedit_string`, the application draws it at
the caret, and the document is untouched — spike B asserts exactly that and it
held across all 28 preedit events it logged.

Under TSF the input processor takes a **read/write lock** on the text store and
calls `SetText` to put the composing characters *into the buffer*, then marks
that range with display attributes so the application underlines it. There is no
separate preedit string to render. The text is in the document, and it is
provisional until `OnEndComposition`.

So a cross-platform text field cannot model composition as "a string beside the
document". It needs a document that can carry a provisional range, which Wayland
then never uses. Designing it the other way round — Wayland first, as spike B
did — produces a model that cannot represent what Windows does.

## Offset units: the loop closes

| protocol | unit | spike |
| --- | --- | --- |
| `zwp_text_input_v3` | UTF-8 bytes | B |
| AT-SPI | codepoints | C |
| Windows `BSTR` | UTF-16 code units | D |
| TSF "ACP" | UTF-16 code units | **E** |

Application Character Position is UTF-16 code units — the same unit as a BSTR.
That makes **Windows internally consistent**: its accessibility and its input
method agree, so one internal offset unit serves both.

**Linux is not.** `text-input-v3` counts bytes while AT-SPI counts codepoints,
so on Linux a text field must convert between its own two platform protocols.
One fewer conversion on Windows, and neither platform's documentation points
this out.

## Verified — TSF drives the store

Run in a Windows 11 VirtualBox guest over `VBoxManage guestcontrol`, with the
Linux build output exposed as a shared folder.

```
ITfThreadMgr created
activated, client id 32
  -> AdviseSink(mask=0x1f)
document manager associated with the window
  -> RequestLock(0x6) -> granting [read/write]
  -> GetSelection -> 0..0
  -> RequestLock(0x6) -> granting [read/write]
  -> GetText(0..-1) -> 0 utf16 units
  -> RequestLock(0x6) -> granting [read/write]
  -> GetTextExt -> screen (68,151)
  -> RequestLock(0x3) -> granting [read only]
  -> GetSelection -> 0..0
```

- The full bring-up succeeds: `CoCreateInstance` → `Activate` →
  `CreateDocumentMgr` → `CreateContext` → `Push` → `AssociateFocus`.
- **TSF advised our sink** (`mask=0x1f`) and then drove the store itself.
- **Both lock types are exercised by real TSF**: `0x6` is `TS_LF_READWRITE`,
  `0x3` is `TS_LF_READ`. The lock protocol works against the real framework, not
  a test harness.
- `CLSID_TF_ThreadMgr` is **not** in the mingw headers and had to be hardcoded.
  It is confirmed correct: a wrong value fails `CoCreateInstance` with
  `REGDB_E_CLASSNOTREG`, and `ITfThreadMgr created` is the proof that it did not.

## Verified — composition, with Telex

`Language.Basic~~~vi-VN~0.0.1.0` installed into the guest with DISM, and
Windows 11's own **Vietnamese Telex** TIP
(`{C2CB2CF0-AF47-413E-9780-8BC3A3C16068}` profile
`{5FB02EC5-0A77-4684-B4FA-DEF8A2195628}`) selected as the input method. Telex is
therefore the shared test case across all four tier-A spikes, which makes this
directly comparable with spike B.

Typing `a`, `w`, `s` — the same three keystrokes spike B used:

```
-> OnStartComposition at 0
-> SetText(flags=0x0 0..0 <- "a" 1 utf16 units)
   [doc] "a" | acp sel 1..1 | COMPOSING | 1 utf16 = 1 bytes = 1 codepoints
-> SetText(flags=0x0 0..1 <- "ă" 1 utf16 units)
   [doc] "ă" | acp sel 1..1 | COMPOSING | 1 utf16 = 2 bytes = 1 codepoints
-> OnEndComposition -- the text in the document is now committed
```

Set against spike B's log for the identical keystrokes:

```
<- preedit_string("a")    doc=""  preedit="a"     <- document UNTOUCHED
<- preedit_string("ă")    doc=""  preedit="ă"
<- commit_string("ă")     doc="ă"
```

**The prediction in this file's header is confirmed on both sides.** On Wayland
the document stays empty for the whole composition and the preedit is a separate
string. On Windows the provisional text is in the document from the first
keystroke, and the retroactive diacritic is applied by *replacing a range of our
buffer* — `SetText(0..1 <- "ă")` overwrites the `a` that was already there.
There is no preedit string anywhere in the Windows path.

And the unit divergence is visible in the same line: `ă` is **1 UTF-16 unit, 2
bytes, 1 codepoint**. The replace range `0..1` is correct in ACP and would have
been wrong in bytes.

Session totals: **173 ITextStoreACP calls, 23 `SetText`, 5 compositions, 27
read/write lock grants.**

### Correction: Windows does have a Vietnamese IME

An earlier version of this file said Windows' built-in Vietnamese "is a keyboard
layout, not an IME" and that Telex on Windows "needs third-party software". That
is **wrong**, and the distinction matters:

- Windows *does* ship a Vietnamese Telex **TSF TIP**, listed above. It is simply
  not installed by default — the registry carries the profile with `Enable = 0x0`
  and no COM server until the language capability is added.
- Third-party tools such as UniKey and EVKey are keyboard-hook based rather than
  TSF, so installing one would **not** have exercised this code path at all. The
  first plan for this spike would have proved nothing.

The earlier claim was made before the capability was installed and before the
registry was searched for a `0x0000042A` language profile. Both of those were
cheap, and neither was done.

### Still not exercised

- **Queued locks.** `RequestLock` while a lock is held, returning `TS_S_ASYNC`,
  never fired: 0 occurrences across 27 grants. The path is implemented and
  untested, and it is the part most likely to be wrong.
- **Read-only locks during composition.** All 27 grants in the Telex session were
  read/write; the read-only path (`0x3`) appeared only during start-up queries.
- **Longer phrases.** `keyboardputstring` delivers keys far faster than a human,
  and the Telex engine stopped transforming after the first syllable when fed a
  whole phrase that way — the buffer filled with literal `tieengs` rather than
  `tiếng`. That is the injection harness outrunning the IME's own state machine,
  not a text-store fault, but it means only short sequences are actually
  verified.

## A bug this found in itself

`SetFocus` alone does not make a window foreground. Launched from a console the
console keeps the foreground, so an input method sees no focused text store and
never starts composing — which looks exactly like a broken `ITextStoreACP`. The
fix is `BringWindowToTop` + `SetForegroundWindow` + `SetActiveWindow` before
`SetFocus`, and it is the kind of thing only a real run surfaces.

## What the lock protocol actually requires

This has no equivalent in `text-input-v3` and is the main structural cost of TSF:

- A lock request arriving **while a lock is held** must not recurse. It is queued
  and granted after the current one unwinds, with `TS_S_ASYNC` returned to the
  caller. Granting it immediately re-enters the input processor and corrupts its
  state. A synchronous request in that situation gets `TS_E_SYNCHRONOUS`.
- Writes during a read-only lock must fail with `TS_E_NOLOCK`. Allowing them
  silently produces text the processor does not know about.
- `InsertTextAtSelection` with `TS_IAS_QUERYONLY` asks where text *would* go.
  Treating it as a real insert duplicates every composed character.
- `GetText` with `acpEnd = -1` means "to the end". Easy to miss, and the failure
  is a silently empty read.
- `GetACPFromPoint` and `GetTextExt` must return `TS_E_NOLAYOUT` when layout is
  unavailable, not `E_NOTIMPL` — some processors give up on the store entirely
  on the latter.

## Not covered

- Display attributes for the composing range, so nothing is underlined.
- Candidate window placement: `GetTextExt` returns a fixed rectangle because
  there is no text layout here, the same limitation spike B has with
  `set_cursor_rectangle`.
- `ITfThreadMgrEx::ActivateEx`, keystroke filtering, and
  `ITextStoreACPServices`.
- Embedded objects: five methods return `E_NOTIMPL` deliberately.

## Zig friction worth recording

`translate-c` cannot expand `MAKE_HRESULT`, so every `TS_E_*` and `TS_S_*`
result code arrives as `@compileError` and had to be recomputed from the macro
(`(sev << 31) | (FACILITY_ITF << 16) | code`), with `comptime` assertions
pinning two known values.

That is the third distinct thing in three Windows/Linux spikes that `translate-c`
could not deliver — after spike C's `DBusError` bitfields and spike D's `VARIANT`
anonymous unions and missing IIDs. The pattern is consistent: Zig reaches C APIs
easily until the header uses a construct it has no syntax for, and then it needs
a hand-maintained mirror that no compiler checks against the original.

No new standard-library breaking changes. Running total stands at **11 across
roughly 5 000 lines**.
