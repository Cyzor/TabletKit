// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

// Former names of types that describe more than Wacom hardware. Removed in
// the next major release.

@available(*, deprecated, renamed: "TabletSpec")
public typealias WacomDeviceSpec = TabletSpec

@available(*, deprecated, renamed: "ReportFormat")
public typealias ReportParser = ReportFormat

@available(*, deprecated, renamed: "ToolCatalog")
public typealias WacomToolCatalog = ToolCatalog

@available(*, deprecated, renamed: "ToolSpec")
public typealias WacomToolSpec = ToolSpec

@available(*, deprecated, renamed: "ToolKind")
public typealias WacomToolType = ToolKind
