# Adding Support for a New Tablet

This guide turns a tablet MockTab doesn't recognize into a working registry entry. It works when MockTab already understands the tablet's report format but doesn't know its exact product ID, which is the common case: most tablets share a format with several other models.

## How to Decode a Tablet

Four steps stand between a pen's actions and a user application:

1. **The tablet sends reports.** Move the pen and the tablet sends a stream of bytes over USB or Bluetooth, called HID reports. Nothing in the bytes says which one is the X-axis, which is pressure, or which bit is a button.
2. **MockTab looks the tablet up in the registry.** When a tablet connects, MockTab finds its product ID in `WacomDeviceRegistry`. The entry says which decoder reads its reports and how big its numbers get: coordinate range, pressure levels, button count, and whether it has touch. A tablet missing from the registry falls back to a generic driver that guesses these from the tablet's own description of its reports. That's why an unknown tablet often half works rather than not working at all.
3. **A decoder reads each report.** Using the limits from the registry, a decoder in `Decoders/` turns each report into a pen position, a pressure value, a button press, or a touch.
4. **The app applies your settings.** Pressure curve, screen mapping, and what each button does all happen here, after decoding.

A registry entry changes only step 2. It can't teach a decoder a new report format, and it doesn't decide what a button does. But a wrong entry can make step 4 look broken: if the coordinate range is off, screen mapping is off too. Fixing the entry often fixes what looked like a settings problem.

## Step 1: Identify Your Tablet

Find the model name and the product ID. In System Information, choose USB and select the tablet. Note its **Product ID**, a four-digit hex number like `0x033E`, and its **Vendor ID**. Wacom's is usually `0x056A`.

Then look the product ID up in other projects that support it. In order of usefulness:

1. **The Linux kernel's Wacom driver.** Search `wacom_wac.c`, in the [input-wacom](https://github.com/linuxwacom/input-wacom) repository, for the ID without leading zeros, like `0x33E`. If it's there, you'll find a line like this:

   ```c
   static const struct wacom_features wacom_features_0x33E =
       { "Wacom Intuos PT M 2", 21600, 13500, 2047, 63, INTUOSHT2, ... };
   ```

   That's the maximum X, maximum Y, maximum pressure, and a family name, `INTUOSHT2`. Linux has already worked out most Wacom hardware, so you're borrowing that work rather than repeating it.
2. **libwacom's device files**, under `data/` in the [libwacom](https://github.com/linuxwacom/libwacom) repository. They confirm the model name, touch support, and button layout.
3. **The tablet's box, manual, or product page.** Useful for the model name, the active area, and which pen it came with.

Keep what you find for Step 5.

## Step 2: Record Your Tablet

In MockTab, open the **Info** pane and click **Collect Device Data…**. A tablet MockTab doesn't recognize also shows an **Unrecognized tablet** banner with the same button. The same command is in the Help menu.

The app asks you to do whatever your tablet supports: tap and lift the pen, hold each pen button, touch with the eraser, press each tablet button, slide a finger around any ring or strip, and drag and pinch with your fingers. Skip anything your tablet doesn't have, then click **Done**.

MockTab saves a zip file to your Desktop, named like `mocktab-diagnostics-0x033E-….zip`. It holds three files:

- **`summary.json`**: what the tablet reported, with statistics about every byte. Most of this guide reads from it.
- **`full-log.txt`**: every report received, one per line, as plain text.
- **`README.txt`**: what's in the files and what isn't. There are no keystrokes, personal files, or screen contents.

From the last screen, you can open a GitHub issue, show the file in Finder, or send it by email.

## Step 3: Read the Summary

Open `summary.json` in a text editor. Most of what you need is in two places: `reports`, which describes what the tablet sent, and `hidReportDescriptor`, which describes what the tablet says it sends.

### Reports

Tablets tag each kind of report with a number called the report ID. Pen movement usually arrives on one ID and button presses on another. `reports` has an entry for each ID that arrived:

- **`length`**: how many bytes long the report is. Check it as carefully as the ID: two kinds of report can share an ID and differ only in length. If `lengthVaried` is true, the report came in more than one length, and `maxLength` gives the longest.
- **`varyingBytes`**: byte positions that changed during the recording. A byte that never changed either does nothing, or you didn't do whatever changes it.
- **`constantBytes`**: byte positions that never changed, with their values in `constantValues`. These are often padding, fixed markers, or a feature you didn't try.
- **`byteStats`**: for each changing byte, its lowest and highest value, how many different values it took (`distinctCount`), and a list of the values seen. A byte that only ever held `0x00` through `0x0F` is probably a 4-bit field. For a byte that holds a signed number, like tilt, read `signedMagnitudeMax` rather than the highest value.
- **`firstSample`**: the first report with that ID, in hex.
- **`repeatingStructure`**, when present: the report holds several copies of the same layout, such as four touch frames in a row.

None of this says what a byte means. Meaning comes from matching what you did, like pressing the second button, against which bytes changed, and from matching the report's ID and length against a format a decoder already reads.

A few other entries are worth a look. `interfaces` lists each part of the tablet macOS sees, such as pen, buttons, and touch. `initReports` shows whether the tablet accepted the setup command that switches it to full reporting; a rejected one means pen details will be missing. `findings` lists anything MockTab noticed on its own, such as an expected report that never arrived.

### The Tablet's Own Description

`hidReportDescriptor` is the tablet's description of its reports, called the HID report descriptor. When it's readable, it's the quickest way to a registry entry. It has two parts:

- **`rawHex`**: the whole descriptor as bytes. Two tablets with the same `rawHex` speak the same format, whatever their product IDs.
- **`reports`**: each report's fields, decoded. A field has a **usage page** and **usage**, which say what it means; `logicalMin` and `logicalMax`, the range of values the tablet sends; and `physicalMin`, `physicalMax`, and `unitExponent`, the real-world size that range covers.

Three fields give you most of an entry:

- **X and Y**: usage page `1` (Generic Desktop), usages `48` (`0x30`) and `49` (`0x31`). Their `logicalMax` values are `maxX` and `maxY`.
- **Pressure**: usage page `13` (`0x0D`, Digitizer), usage `48` (`0x30`, Tip Pressure). Its `logicalMax` is `maxPressure`.

The physical range of X and Y gives the active area. HID measures length in centimeters, scaled by a power of ten in `unitExponent`. Convert the result to millimeters for `activeWidthMM` and `activeHeightMM`.

Two cautions:

- **Many tablets, especially older Wacom models, describe their reports in private terms.** Every field sits on a vendor page (`usagePage` 65280, `0xFF00`, or higher) or uses codes nobody has documented, so nothing readable comes out. That's normal. Use the byte statistics above and the sources from Step 1 instead.
- **A tablet's description can disagree with what it sends.** Many also offer a simple low-resolution pen mode with its own small ranges, and its `logicalMax` values look nothing like the real ones. Read the fields of the report the pen actually uses. When the descriptor and the Linux kernel disagree, trust the kernel.

`tools/triage_discovery.py` does much of this for you. Unzip the file and run it on `summary.json`. It prints the tablet's details, its reports, how it compares with the kernel and OpenTabletDriver, and a draft registry entry to start from:

```
python3 tools/triage_discovery.py summary.json
```

## Step 4: Find a Neighbor in the Registry

Two places decide how a tablet behaves:

- **`Sources/TabletKit/Registry/WacomDeviceRegistry.swift`** has one entry per Wacom model. An entry ties a product ID to its ranges, buttons, touch support, and decoder. Other brands live in `VendorDeviceRegistry.swift`.
- **`Sources/TabletKit/Decoders/`** holds the code that reads reports. Each file covers one report format, like `IntuosV1Decoder.swift`. Most tablets share a decoder with several others.

Search the registry for a model close to yours, ideally from the family you found in Step 1. An entry looks like this:

```swift
.init(
    productID: 0x033E, name: "Wacom CTH-690",
    parser: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 2047,
    buttonCount: 4, hasTouchRing: false, hasEraser: false, tiltMaxDegrees: 64.0,
    hasFingerTouch: true, maxTouchContacts: 16,
    touchMaxX: 2160, touchMaxY: 1350,
    seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
    confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
```

Copy the neighbor, then change its values to match your tablet.

## Step 5: Fill In Your Entry

Go through the fields one at a time:

- **`productID`**: from Step 1.
- **`maxX`, `maxY`, `maxPressure`**: from the kernel line if you found one, or from the descriptor. Without either, estimate them from the byte statistics of the coordinate bytes, and say in a comment that they're estimates.
- **`buttonCount`**: the buttons on the tablet itself. Count them on the hardware: a recording only proves the buttons you pressed exist.
- **`hasFingerTouch`, `maxTouchContacts`, `touchMaxX`, `touchMaxY`**: only if the tablet has touch and the recording shows a separate touch report. With no touch data, leave `hasFingerTouch` false rather than guessing.
- **`parser`**: the most important field. It must name a decoder that already reads your pen report's ID and length. Check `Decoders/` for one that does. If none does, say so in your pull request rather than picking the closest.
- **`confidence`**: `.experimental` if your numbers come from one source, `.crossReferenced` if two independent sources agree, such as the kernel and libwacom. `.verified` means someone tested the entry on the tablet itself.

Add a short comment above the entry saying where its numbers came from.

## Step 6: Look for Gaps

Compare what still doesn't work with what you've written:

- **Buttons still wrong:** the decoder's mapping of bits to buttons may not match your tablet's layout. The decoder file usually has a comment saying which bit is which button. Compare that with the order you pressed them in.
- **No touch in the recording:** the tablet may not send touch on this connection, or the recording skipped the touch step. Look for a report ID you haven't accounted for. Touch usually has its own.
- **No decoder reads your pen report:** you've found a new format. That's decoder work, not a registry edit. Open an issue with your zip file attached.

## Step 7: Build and Test

In the `TabletKit` folder, run the tests:

```
swift test
```

The tests confirm your entry didn't break anything else. They can't tell you whether a coordinate range is right.

For a second opinion, `tools/verify_registry.py` and `tools/audit_registry.py` compare every registry entry with the Linux kernel and OpenTabletDriver and list where they disagree. They're plain Python and run by hand.

Then try it in MockTab. TabletKit is the `TabletKit/` folder inside a [MockTab](https://github.com/Cyzor/tablet-driver) checkout. Open `MockTab.xcodeproj` there, run the app, and plug in your tablet. Then check each of these:

1. **Info:** the banner is gone and your tablet's name appears.
2. **Scratchpad:** the cursor follows the pen smoothly, and the pressure meter rises as you press harder.
3. **Buttons:** each pen button and tablet button registers when pressed.
4. **Touch,** if your tablet has it: a finger drag moves the cursor.
5. **Tablet Area:** the mapped area matches the tablet. A wrong `maxX` or `maxY` usually shows up here as an area that's too small or too big.

Fix any mismatch, rebuild, and test again. There's no shortcut: an entry is only right once it works on the tablet.

## Step 8: Say What You Tested

In your pull request or issue, say what you tested and what you didn't. A note like "Pen and buttons tested on the tablet; touch untested; button order guessed from the recording" tells the next person what they can rely on.

## What This Can't Do

A recording and a registry entry only help tablets whose report format MockTab already reads. They can't:

- Add a decoder for a new format.
- Reveal commands the app sends to the tablet, like setting LEDs, button labels, or modes. A recording shows only what the tablet sends.
- Turn an estimate into a confirmed value without testing on the tablet.

If your tablet still doesn't work, your zip file still helps. Attach it to an issue: it's exactly the evidence someone needs to finish the job.
