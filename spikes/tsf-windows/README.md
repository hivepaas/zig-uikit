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

## NOT verified: composition

No `SetText`, `OnStartComposition` or `OnEndComposition` was ever observed,
because **the guest has no functional composing IME installed**. Two separate
reasons, and both are worth recording because they are not obvious:

**1. Windows' built-in Vietnamese is a keyboard layout, not an IME.** On Linux,
Vietnamese goes through `ibus-bamboo`, a real input method with preedit — which
is what made spike B testable. On Windows, the shipped Vietnamese support maps
keys directly and never composes. Telex on Windows needs third-party software
(UniKey, EVKey). So the test case that carried spikes B, C and D cannot test
composition here at all.

**2. The Japanese IME is registered but not installed.** 20 TSF TIP GUIDs are in
the registry, including MS-IME Japanese `{03B5835F-F03C-411B-9CE2-AA23E1171E36}`.
Adding `ja` to the user language list succeeds. But:

```
=== MS-IME Japanese files present? ===
Windows.Globalization.JapanesePhoneme.dll
```

One stub DLL. A working MS-IME has dictionaries and `imjp*` modules. The
capability needs an online download, so switching to Japanese silently falls
back to a direct layout and nothing composes.

Keystrokes injected with `VBoxManage controlvm keyboardputstring` reached the
guest and the window was brought to the foreground, but with no composing IME
there was nothing to compose. **Three attempts; the cause is environmental, not
a defect in the store.**

To actually close this, one of:

- install the Japanese language features in the guest (an online download), or
- install a third-party Vietnamese TSF IME such as UniKey, which would also
  restore Telex as the shared test case across all four spikes, or
- run it on a Windows machine that already has a composing IME.

Until then this spike proves TSF accepts and drives the text store, and does not
prove the composition path. Spike C is the reason to keep that distinction
sharp: running Orca found two gaps that reading the protocol had not.

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
