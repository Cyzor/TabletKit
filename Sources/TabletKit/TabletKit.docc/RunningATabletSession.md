# Running a Tablet Session

Let TabletKit find, switch on, and read your tablets, so your code only handles events.

## Overview

<doc:BuildingAMinimalDriver> does the device work by hand: match interfaces, look each one up in the registry, send the switch-on command, and decode every report. ``TabletSession`` does all of that for you, along with the parts that get fiddly:

- A tablet that shows up as several interfaces, for pen, buttons, and touch.
- The same tablet connected over USB and Bluetooth at once.
- A Wacom wireless receiver that says only later which tablet it relays.
- Tablets that need switching on again after the Mac sleeps.

You supply two objects: a delegate that hears about tablets coming and going, and a sink that receives each report's events.

## Start a Session

A session lives on the main actor and reports to its delegate there, so create it from main-actor code:

```swift
@MainActor
final class Driver: TabletSessionDelegate {
    private var session: TabletSession?

    func start() {
        let session = TabletSession(
            vendorIDs: Array(WacomDeviceRegistry.vendorIDs), anyPenDigitizer: false, delegate: self)
        if session.start() != kIOReturnSuccess {
            print("Grant Input Monitoring, then call retryOpen().")
        }
        self.session = session
    }
}
```

``WacomDeviceRegistry/vendorIDs`` covers both of Wacom's vendor IDs. Set `anyPenDigitizer` to also take other makers' standard pen digitizers.

`start()` fails until the app has Input Monitoring permission. Once the user grants it, call ``TabletSession/retryOpen()``.

The main run loop has to run. An app's already does; a command-line tool calls `RunLoop.main.run()`, not `dispatchMain()`.

## Meet the Tablets

The delegate has three methods to write. The rest have defaults.

```swift
func session(_ session: TabletSession, didAttach transport: TabletTransport, to tablet: ConnectedTablet) {
    print("\(transport.spec.name) connected over \(transport.transportName)")
}

func session(_ session: TabletSession, inputSinkFor transport: TabletTransport) -> any TabletInputSink {
    PenPrinter()
}

func session(_ session: TabletSession, didDetach transport: TabletTransport, from tablet: ConnectedTablet) {
    print("\(transport.spec.name) disconnected")
}
```

A ``ConnectedTablet`` is one physical tablet. Each way it's connected, whether USB, Bluetooth, or a wireless receiver, is a ``TabletTransport``. When a tablet arrives over a second connection, it gets a second transport, not a second tablet. ``ConnectedTablet/activeTransport`` says which one is driving.

A transport starts out connecting while its switch-on sequence runs. To hear when it's ready, or when it fails, add:

```swift
func session(_ session: TabletSession, transportDidChangeState transport: TabletTransport) {
    if case .faulted(let failure) = transport.state {
        print("\(transport.spec.name) stopped: \(failure)")
    }
}
```

## Read the Events

The sink gets each report already decoded, as the same ``TabletEvent`` values a ``DeviceDecoder`` returns:

```swift
final class PenPrinter: TabletInputSink {
    func didDecode(_ events: [TabletEvent], from report: HIDReport, on interface: any HIDInterface, at receivedNs: UInt64) {
        for event in events {
            if case .pen(let point) = event, point.inProximity {
                print(point.x, point.y, point.normalizedPressure)
            }
        }
    }
}
```

The sink runs on the input thread, not the main thread, and the next report waits until it returns. Keep it quick: post a cursor event, or hand the work to another queue. To see the raw bytes as well, for a capture tool say, implement ``TabletInputSink/didReceive(_:at:from:)``.

## Set the Hardware

Each transport's ``TabletTransport/controls`` holds what the tablet lets you set: ring lights, key labels, a pen display's panel, and more. A slot is `nil` when the tablet has no such hardware, so ask before you write:

```swift
transport.controls.labels?.setRingModeLabel("Zoom")
```

After the Mac wakes from sleep, call ``TabletSession/reawakenAll()``. Some tablets lose their switch-on, or their key displays, while asleep. Call ``TabletSession/stop()`` when you're done.

## Topics

### Session

- ``TabletSession``
- ``TabletSessionDelegate``
- ``TabletInputSink``

### Tablets

- ``ConnectedTablet``
- ``TabletTransport``
- ``TabletControls``
