// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// Interfaces that arrived before the driver that will take them, held by
/// product ID until it does.
///
/// Arrival order is luck: a tablet's interfaces, or a touch sensor and its
/// pen display, enumerate in any order. Handles compare by identity.
package struct HeldInterfaces<Handle: AnyObject> {
    private var held: [Int: [Handle]] = [:]

    package init() {}

    package mutating func hold(_ handle: Handle, under productID: Int) {
        held[productID, default: []].append(handle)
    }

    /// Everything held under `productID`, in arrival order, no longer held.
    package mutating func release(_ productID: Int) -> [Handle] {
        held.removeValue(forKey: productID) ?? []
    }

    /// Takes one handle back if it's still held under `productID`, as when
    /// its wait runs out. False if something already released it.
    package mutating func take(_ handle: Handle, under productID: Int) -> Bool {
        guard let index = held[productID]?.firstIndex(where: { $0 === handle }) else { return false }
        held[productID]?.remove(at: index)
        if held[productID]?.isEmpty == true { held[productID] = nil }
        return true
    }

    /// Forgets a handle wherever it's held, as when it disconnects.
    package mutating func drop(_ handle: Handle) {
        for key in Array(held.keys) {
            held[key]?.removeAll { $0 === handle }
            if held[key]?.isEmpty == true { held[key] = nil }
        }
    }

    package var isEmpty: Bool { held.isEmpty }
}

extension HeldInterfaces: Sendable where Handle: Sendable {}
