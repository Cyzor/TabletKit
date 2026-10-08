# Contributing to TabletKit

Perhaps your tablet doesn't work with MockTab, or only partly works, and you'd like to help fix that. This page explains how to add support for a tablet, as well as the ways you can help.  Contributions range from sending a recording, which needs no programming at all, to writing the code yourself.

## What TabletKit Is

[MockTab](https://github.com/Cyzor/tablet-driver) is a Mac app that drives drawing tablets Wacom no longer supports. TabletKit is the part of MockTab that knows about tablets. It has two jobs:

- **The registry** is a list of known tablets. For each one, it records the coordinate range, pressure levels, buttons, touch support, and which decoder reads its reports.
- **Decoders** read what a tablet sends. A tablet doesn't send "the pen is here, pressed this hard". It sends a stream of bytes called reports, and a decoder knows which bytes mean position, which mean pressure, and which bits are buttons.

Most tablets share a report format with several others, so most new tablets need only a registry entry. A tablet with a format nobody has worked out yet needs a new decoder.

## Adding Support

Tablets don't come with documentation of their reports, so adding one is mostly patient observation:

1. **Plug the tablet in and record everything it sends.** Move the pen, press it lightly and firmly, tilt it, press every button, touch the surface.
2. **Compare the recording with what you did.** If one byte climbs while you press harder, that's probably pressure. If a bit turns on only while you hold the second button, that's the button.
3. **Look at what others have found.** The Linux kernel, libwacom, and OpenTabletDriver already describe many tablets. A match there can save hours.
4. **Change the registry entry or decoder, then try the tablet again.** Repeat until everything works.

Each round teaches you a little more. Nothing replaces having the tablet in hand.

## Choose How to Help

### Send a Recording

**Anyone can do this, and it takes about five minutes.** It's also the most useful thing a person with an unsupported tablet can do. A recording often has everything someone else needs to add the tablet.

1. In MockTab, choose **Help › Collect Device Data…**, or click **Collect Device Data…** in the Info pane.
2. Do what the app asks: tap the pen, press its buttons, press the tablet's buttons, and so on. Skip anything your tablet doesn't have, then click **Done**.
3. On the last screen, click **Open GitHub Issue…**. A device support form opens on GitHub with your tablet's details filled in. Drag the zip file MockTab saved to your Desktop into the form, and say what does and doesn't work.

The zip holds only what your tablet sent and some details about your setup, like display models. It's plain text, so you can open it and look before you send it.

### Add Your Tablet to the Registry

**For people comfortable editing a file and building an app in Xcode.** If MockTab says your tablet is unrecognized, it probably shares a format with a tablet MockTab already supports and just needs an entry of its own.

[Adding Support for a New Tablet](Extending-Support.md) describes the process: reading your recording, finding similar tablets, writing the entry, and testing it.

### Work Out a New Format

**For developers who don't mind experimenting.** If no decoder reads your tablet's reports, the job is to work out what each byte means and write a decoder for it, conforming to `TabletReportDecoder`. Look at an existing decoder for a similar tablet first. Many formats are variations on another.

Beyond MockTab's own recording, a few command-line tools in the [MockTab repository](https://github.com/Cyzor/tablet-driver/tree/main/tools/capture) help.

- **`hid_input_capture.c`** logs every report from any USB device. It runs alongside the tablet maker's own driver, so you can see what a tablet sends when its own software is in charge. Build it with `clang`, as its comments describe.
- **`hid_traffic_capture.d`** logs the commands a driver sends to a tablet, including the setup commands that switch it on, and the replies to its requests. It uses dtrace, which only works with System Integrity Protection turned off. Turn it back on when you're done.
- **`triage_discovery.py`**, in TabletKit's `tools/` folder, reads a recording's `summary.json`, compares the tablet with the kernel and OpenTabletDriver, and drafts a registry entry.
- **`hid-trace-sweep`**, one of TabletKit's samples, replays hid-recorder files, like those in public recording collections, through every decoder. It shows which one fits and whether the pen reached the registry's limits. Run `swift run hid-trace-sweep --summary *.hid` for one line per tablet.

If you get stuck, open an issue with what you've found so far. Every little bit helps.

## Submitting a Change

### How Sure Is the Entry?

Every registry entry carries a confidence level, so users and other contributors know how much to trust it:

- **`.experimental`**: the values come from one source, like your recording or a single other project.
- **`.crossReferenced`**: two independent sources agree, like the Linux kernel and libwacom.
- **`.verified`**: someone tested the entry on the tablet itself.

Mention your sources in a comment above the entry, including the project and commit for any values you took from elsewhere.

### Add a Test

Tests keep a fix from quietly breaking later. Add yours to `Tests/TabletKitTests/`, next to the decoder's existing `…DecoderTests.swift` file.

The easiest test uses reports from your recording. Paste them into the test as text, and `CaptureLogParser` turns them back into bytes. It reads [hid-recorder](https://github.com/hidutils/hid-recorder) dumps as they are. From `full-log.txt`, copy lines that show one report each, and delete the decoded summary after the `→` at the end of a line. Lines marked `×` stand for many reports and can't be used.

A good first test checks that the decoder produces a result for each report. You don't need to work out every expected value by hand.

Run the tests from the `TabletKit` folder:

```
swift test
```

### Open a Pull Request

In the description, include:

- What the change does, in a sentence.
- The tablet model and how it connects: USB, Bluetooth, or a wireless receiver.
- What you tested and what you didn't. "Pen and buttons tested over USB; touch untested" is perfect.
- Anything surprising you noticed, like reports you didn't expect.

Problems with the MockTab app itself, like its settings window or installing it, belong in the [MockTab repository](https://github.com/Cyzor/tablet-driver). See its [contributing guide](https://github.com/Cyzor/tablet-driver/blob/main/Contributing.md).

## Reference for Code Changes

### What's Where

- `Sources/TabletKit/Registry/` holds the registry of tablets and pens.
- `Sources/TabletKit/Decoders/` has one decoder per report format.
- `Sources/TabletKit/Core/` holds the types decoders share, like `TabletPoint`, `HIDReport`, and `DecodeResult`.
- `Sources/TabletKit/HID/` is the only code that talks to macOS about tablets: reading their descriptions of their reports, switching them on, and setting lights and screens.
- `Sources/TabletKit/Output/` builds the reports sent to tablets, such as LED colors and button labels.
- `Sources/TabletKit/Smoothing/` holds the cursor and pressure filters.
- `registry.json` copies the registry for scripts and other platforms. After you edit the registry, run `python3 tools/export_registry_json.py` and commit the updated file.

### If CI Reports an API Break

Apps other than MockTab can use TabletKit, so a check runs on every change to catch edits that would stop their code from compiling. It compares TabletKit's public interface with the latest release.

The most common surprise: adding a property to a public type usually counts as a break. Most types here rely on the initializer Swift writes for them, and a new property changes it. To avoid that, leave the existing initializer as it is and add a second initializer that includes the new property. Adding a parameter with a default value to the existing one looks like it should work, but it still breaks compiled code.

Some breaks are worth making, especially before 1.0. To keep one:

1. Copy the check's message exactly into `api-breakage-allowlist.txt`, with a comment saying why.
2. Describe the change in `CHANGELOG.md` under **Changed** or **Removed**, including what other apps need to do about it.

## Forking

You're welcome to fork TabletKit for your own project. It's licensed under MPL-2.0, which lets you change it and ship it with software under other licenses. Changes to TabletKit's own files stay under MPL-2.0.
