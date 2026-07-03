# Adding Support for a New Tablet

This guide describes how to turn MockTab discovery diagnostics into a working registry entry for a specific tablet model. It assumes MockTab already supports the tablet’s protocol family but does not yet recognize this exact product ID.

The guide address how to identify a tablet, interpret its captured data, update the registry and decoder configuration, and verify the result on real hardware.

## How MockTab works

MockTab operates as a stack of steps:

1. **The tablet itself sends raw HID messages.** Move the pen, and it emits a stream of bytes over USB or Bluetooth. Those bytes mean nothing on their own; the tablet doesn't tell you which byte is X, which is pressure, or which bit is a button.
2. **MockTab looks up the tablet's USB product ID in a device registry** (`WacomDeviceRegistry.swift`) the moment it connects, before it decodes a single byte. That lookup answers one question: *which decoder should read this device's messages, and what are its physical limits* (coordinate range, pressure range, button count, whether it has touch)? If the PID isn't in the registry, MockTab falls back to a generic driver that guesses these numbers from the HID descriptor instead, which is why a lot works badly rather than not at all.
3. **The decoder** (in `Decoders/`) reads each raw message and, using the limits from step 2, turns it into a structured event: a pen position, a pressure value, a button press, a touch contact. This is the layer a registry entry alone can't fix; it has to already know your tablet's report format.
4. **The app applies your own settings to those events**: the pressure curve, which screen area the tablet maps to, which key each button and express key triggers. This is what the Buttons, Tablet Area, and Pen Feel panes let you adjust, and it's independent of the registry. A wrong registry entry can make step 4's settings look broken even though they're not; fixing step 2 usually fixes what looked like a settings problem.

Registry revisions only affect step 2. The work tells MockTab what kind of messages to expect and how big the numbers in them can get. By itself, it doesn't decide what a button press does; that's already covered once decoding works, through the panes everyone else uses.

## Step 1: Identify your tablet

Find the exact model name and, if you can, the USB product ID (PID). On macOS, open **System Information** (or `System Report`), go to **USB**, and find your tablet. Note the **Product ID** (a 4-digit hex number, like `0x033E`) and **Vendor ID** (Wacom's is always `0x056A`).

Search for that PID against three sources, in this order of usefulness:

1. **The Linux kernel's Wacom driver**, `wacom_wac.c`, in the `linuxwacom` or `torvalds/linux` GitHub mirror. Search the file for your PID (e.g. `0x33E`). If it's there, you'll find a line like:

   ```c
   static const struct wacom_features wacom_features_0x33E =
       { "Wacom Intuos PT M 2", 21600, 13500, 2047, 63, INTUOSHT2, ... };
   ```

   That gives you the maximum X coordinate, maximum Y coordinate, maximum pressure, button count, and a family name (`INTUOSHT2` here) almost for free. Linux has already reverse-engineered most Wacom hardware; you're borrowing that work, not redoing it.
2. **libwacom's device database** (`github.com/linuxwacom/libwacom`, under `data/`). Confirms model name, touch support, and button layout, usually in a plain `.tablet` config file you can read without any code experience.
3. **Your own tablet's box, manual, or a product page.** Confirms the marketing name, physical size, and pen model, useful for sanity-checking numbers you find elsewhere.

Write down what you find. You'll need it in Step 4.

## Step 2: Capture your tablet's data

In MockTab, open the **Info** pane. An unfamiliar tablet model may result in an orange **"Unrecognised tablet"** banner. Press **Collect Device Data…** and follow the prompts: touch the pen tip, lift it, press each button, press each express key, touch the surface with a finger if it has touch. Skip anything that doesn't apply to your tablet.

When it finishes, a JSON file lands on your Desktop. Open it in any text editor.

## Step 3: Read the capture

The file has one entry per **report ID**, a number that tags each kind of message your tablet sends. A pen tablet usually sends pen movement on one report ID and button/key presses on another. Inside each report ID's entry you'll find:

- **`length`**: how many bytes long that report is. This matters as much as the report ID itself. Two different report types can share the same ID number but differ in length.
- **`varyingBytes`**: which byte positions changed at some point during your capture. A byte that never appears here either does nothing observable, or you didn't trigger the action that changes it.
- **`constantBytes`**: byte positions that never changed. Often padding, or a fixed marker, or a feature you didn't test during capture.
- **`byteSampleValues`**: for each varying byte, up to 20 values actually observed. If a byte only ever showed `0x00` through `0x0F`, it's probably a 4-bit field, not the whole byte.
- **`firstSample`**: the first raw report of that ID, as hex, useful as a quick reference.

None of this tells you what a byte means on its own. It just indicates where things move. Meaning arises by comparing what you did (pressed key 2, touched the tip) against which bytes changed at that moment, and by matching the report's ID and length against a report type MockTab's decoders already understand.

## Step 4: Find the matching source files

Everything that decides how your tablet behaves lives in two places:

- **`TabletKit/Sources/TabletKit/WacomDeviceRegistry.swift`**: one entry per known tablet model. This is where a PID gets attached to a coordinate range, a button count, a touch flag, and which decoder handles its reports.
- **`TabletKit/Sources/TabletKit/Decoders/`**: the actual code that reads raw bytes and turns them into pen positions, button presses, and touch points. Files are named by family, like `IntuosV1Decoder.swift` or `CintiqV1Decoder.swift`. Most tablets share a decoder with several other models; very few need one written from scratch.

Open `WacomDeviceRegistry.swift` and search for a model close to yours, ideally one from the same generation or family name you found in Step 1 (`INTUOSHT2`, `INTUOS4`, whatever the kernel called it). Each entry looks like this:

```swift
.init(
    productID: 0x033E, name: "Wacom CTH-690",
    parser: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 2047,
    buttonCount: 4, hasTouchRing: false, hasEraser: false,
    hasFingerTouch: true, maxTouchContacts: 16,
    touchMaxX: 4095, touchMaxY: 4095,
    seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
    confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
```

That neighboring entry is your template. Copy it and change the values to match your tablet.

## Step 5: Fill in your entry

Work through each field:

- **`productID`**: your PID from Step 1.
- **`maxX`, `maxY`, `maxPressure`**: take these from the kernel struct if you found one. That number should already be correct; you don't need to derive it from the capture. If you didn't find a kernel entry, estimate from `byteSampleValues` on the coordinate bytes in your pen report, then treat the result as a guess until confirmed.
- **`buttonCount`**: how many express keys the tablet actually has. Check the tablet itself, not just the capture, since a capture only proves the keys you pressed exist.
- **`hasFingerTouch`, `maxTouchContacts`, `touchMaxX`, `touchMaxY`**: set these if your tablet has a touch surface and your capture showed a distinct report ID for touch. Leave `hasFingerTouch: false` if you didn't capture any touch data, rather than guessing at numbers you have no evidence for.
- **`parser`**: this is the important one. It has to match a decoder that already understands your pen report's ID and length. Go back to `Decoders/` and check: does an existing decoder handle a report with the same ID and length as your pen report? If yes, use its parser value. If none match, say so plainly in your write-up rather than picking the closest one and hoping.
- **`confidence`**: use `.experimental` if everything here is derived only from your own capture. Use `.crossReferenced` if you confirmed the numbers against the kernel or libwacom. Don't mark anything `.verified`; that's reserved for someone who has confirmed a change against real hardware after it's merged, and you're about to do that testing yourself in Step 7.

Leave a short comment above your entry noting its source (the kernel struct, libwacom, or your own capture) for reference.

## Step 6: Check for gaps

Compare your list of broken behaviors against what you just wrote:

- If express keys are still wrong after this, the bit-to-key mapping in the decoder might not match your tablet's physical layout. Check the decoder file for a comment describing which bit maps to which key, and compare it against which express key you actually pressed for each captured byte change.
- If touch isn't in your capture at all, either your tablet doesn't expose it over this interface, or the capture session didn't include a touch step. Look for a second report ID you haven't accounted for yet; touch and pen usually arrive on separate report IDs.
- If nothing in `Decoders/` handles your pen report's ID and length, you've hit a genuinely new format. That's real decoder work, not a registry edit, and is a good point to open an issue with your capture attached rather than guessing at packet layout on your own.

## Step 7: Build and test

From a terminal, in the `TabletKit` folder:

```sh
swift test
```

This runs the existing test suite and confirms your registry edit didn't break anything else. It won't catch a wrong coordinate value; it only catches things like a decoder crashing on your new report length.

Then build the app itself: open `MockTab.xcodeproj` in Xcode, and run it (the Play button, or Cmd-R). Plug in your tablet.

Check each behavior in order:

1. Open the Info pane. The orange banner should be gone, replaced by your tablet's name.
2. Move the pen. The cursor should track smoothly and stay inside the drawing area.
3. Press each button and express key. Check the Buttons pane to see whether MockTab detects each press correctly.
4. If your tablet has touch, try a finger drag and check the Touch pane.
5. Check screen mapping in the Tablet Area pane. A wrong `maxX`/`maxY` usually shows up here as the usable area being smaller or larger than the physical tablet.

Fix any mismatch by adjusting the corresponding field and rebuilding. This loop, edit the registry entry, rebuild, test on the actual tablet, is the whole process. There's no shortcut around having the physical hardware in hand for this last part.

## Step 8: Write it up

When you open a pull request or an issue, state what you tested and what you did not. A note like “Pen tracking and buttons confirmed on real hardware, touch untested, express key order guessed from capture order” gives enough context for future changes.

## What this process can't do

A capture and a registry edit only fix devices that already match a protocol family MockTab understands. This process cannot:

- Add features the OS does not expose in userspace. Most behavior (LED colors, on-device labels, mode-switch commands) doesn't appear in a userspace capture at all.
- Turn a guess into a confirmed value without testing on real hardware.
- Provide a decoder when no existing entry in `Decoders/` matches your report format.

If the tablet still does not work after these steps, your capture and notes still help. Open an issue with both; they provide the tier-3 evidence described in `Contributing.md` and often give someone with kernel-source access enough detail to complete the work.

Would you like an even more compressed version that fits into a release note or contribution checklist?