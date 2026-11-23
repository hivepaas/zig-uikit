# Spike D — Windows UI Automation for a self-drawn widget tree

The Windows half of tier A from [docs/native-vs-drawn.md](../../docs/native-vs-drawn.md).
[Spike C](../a11y-atspi/) proved the Linux half — AT-SPI implemented directly
over DBus, with Orca reading the tree and decoding the text events. This asks
the same question on Windows, and the answer has a very different shape.

## It cross-compiles from Linux

Zig bundles mingw-w64's `uiautomation.h` and the `uiautomationcore.def` exports,
so this builds to a real PE32+ binary on the Linux host:

```
$ zig build && file zig-out/bin/uia-spike.exe
PE32+ executable for MS Windows 6.00 (console), x86-64

$ objdump -p zig-out/bin/uia-spike.exe | grep -oE 'Uia[A-Za-z]+' | sort -u
UiaClientsAreListening
UiaHostProviderFromHwnd
UiaRaiseAutomationEvent
UiaRaiseAutomationPropertyChangedEvent
UiaReturnRawElementProvider
```

**No MSVC, no Windows SDK, no Visual Studio.** The edit-build loop stays on the
fast machine; only the run happens on Windows. For a project that has to support
three platforms with one maintainer, that is worth more than it sounds.

## The architectural contrast

```
AT-SPI is PUSH, out of process.     UIA is PULL, in process.
```

On Linux the application exports objects on a *separate bus*, registers with a
registry, and hands over a serialised snapshot of the whole tree when asked
(`Cache.GetItems`). The screen reader lives in another process and speaks DBus.

On Windows there is no bus and no registration. A client sends `WM_GETOBJECT` to
the window, the application returns a COM object, and the client then calls
straight into the application's vtables, **in process, on demand**. Nothing is
serialised and nothing is snapshotted.

The whole handshake is one message:

```zig
c.WM_GETOBJECT => if (lp == UiaRootObjectId)
    return c.UiaReturnRawElementProvider(h, wp, lp, @ptrCast(&providers[0].simple)),
```

For a cross-platform toolkit this is not a detail. An AT-SPI backend wants a
tree it can snapshot and serialise; a UIA backend wants stable COM objects with
correct reference counting and lifetimes. One internal accessibility tree can
feed both — the `Node` struct here is deliberately the same shape as spike C's —
but the adapters share almost nothing beyond the node data.

## Three offset units, one text field

This is the finding that carries across all three spikes:

| protocol | unit | spike |
| --- | --- | --- |
| `zwp_text_input_v3` | UTF-8 **bytes** | [B](../ime-wayland/) |
| AT-SPI | **codepoints** | [C](../a11y-atspi/) |
| Windows `BSTR` | UTF-16 **code units** | this one |

The sample text is chosen so that all three numbers differ:

| text | bytes | codepoints | utf-16 units |
| --- | --- | --- | --- |
| `tieng viet` | 10 | 10 | 10 |
| `tiếng việt` | 14 | 10 | 10 |
| `tiếng việt 🇻🇳` | **23** | **13** | **15** |

ASCII hides all three mismatches. Vietnamese separates bytes from codepoints.
Only a non-BMP character — the flag is two codepoints, each needing a surrogate
pair — separates codepoints from UTF-16 units.

A text field that gets any one of these wrong is silently incorrect on exactly
one platform, with nothing crashing.

## UIA-specific hazards handled here

None of these are hard; all are invisible until someone actually uses a screen
reader.

- **Runtime ids must be stable** for an element's lifetime. Clients use them to
  tell "same element" from "new element", so returning a fresh id each call makes
  a screen reader announce everything as new. The convention is to prefix with
  `UiaAppendRuntimeId` so the host window's id is prepended.
- **`BoundingRectangle` is in screen coordinates**, not client coordinates. Get
  it wrong and the screen reader's highlight lands somewhere else on the desktop.
- **`VT_EMPTY` means "I do not supply this property"**, and UIA then falls back.
  Returning an error instead makes clients treat the element as broken.
- **Only the fragment root returns a host provider.** If children return one too,
  the tree appears twice.
- **`UiaDisconnectProvider` is required when an element goes away.** A client can
  hold a provider reference across the element's destruction. This is the main
  lifetime hazard UIA has and AT-SPI does not — out of process, a dead object is
  just a DBus error; in process it is a use-after-free. This spike allocates its
  providers statically so the question is deferred, which a real toolkit cannot
  do.
- **`UiaClientsAreListening()`** is the exact Windows analogue of AT-SPI's
  `GetRegisteredEvents`, and it is used here to skip event work when nothing is
  listening. Spike C found that unconditional emission floods the a11y bus; the
  equivalent waste on Windows is building `BSTR`s and `VARIANT`s nobody reads.

## Build and run

Build anywhere Zig runs:

```sh
zig build                     # defaults to x86_64-windows-gnu
```

Then run `uia-spike.exe` on Windows, start Narrator with `Ctrl+Win+Enter`, and
tab into the window. Every UIA call into the process is logged to the console.

For the VirtualBox setup used here, the build output is exposed to the guest as a
transient shared folder, so a rebuild on the host is immediately visible in the
VM:

```sh
VBoxManage sharedfolder add windows-11 --name zigui \
    --hostpath .../uia-windows/zig-out/bin --transient --automount
```

## Verified

- Cross-compiles on Linux to a PE32+ binary importing `UIAutomationCore.DLL`.
- The COM machinery compiles: four interfaces on one object, vtables built by
  hand, `QueryInterface` handing out the correct interface pointer per IID.
- VirtualBox guest reachable, Guest Additions 7.2.6 present, shared folder
  mounted.

**Not yet verified: Narrator reading it.** That needs the binary run inside
Windows with Narrator on, which is the equivalent of what spike C did with Orca.
Until that happens this spike proves the code builds and links, not that it
works — and spike C is the reason to insist on the difference: running Orca
found two gaps (`Cache.GetItems`, `GetApplicationBusAddress`) that reading the
protocol had not, and falsified a claim about `focus:` events.

## Zig friction worth recording

Two things `translate-c` could not deliver, both needing hand-maintained
declarations that no compiler checks against the real headers:

- **`VARIANT`** comes through as a chain of anonymous unions that is impractical
  to navigate, and the `VT_*` constants are not emitted at all. Redeclared here
  as an `extern struct` with a `comptime` assertion that its size matches the
  translated `c.VARIANT` and is 24 bytes.
- **The interface IIDs.** mingw declares them as `extern const GUID` but ships no
  import library that defines them, so the GUID values are transcribed from the
  `DEFINE_GUID` macros in the bundled headers.

This is the same class of problem as spike C's `DBusError`, which had bitfields
Zig cannot express. Three spikes in, the pattern is consistent: Zig reaches C
APIs easily until the API's *data layout* uses something Zig has no syntax for,
and then it needs a hand-written mirror.

No new standard-library breaking changes in this spike. Running total from
[zig-uikit-bench](https://github.com/hivepaas/zig-uikit-bench) plus spikes B
and C stands at **11 across roughly 4 000 lines**.
