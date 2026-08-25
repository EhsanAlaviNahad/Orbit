// BACKUP: Original menu bar icon setup for Eclick.
// Saved 2026-08-25 before switching to the custom Apple-style drawn icon
// (see Sources/Eclick/MenuIcon.swift).
//
// To restore: replace the image assignments in EclickApp.swift
// (configureStatusItem and restoreStatusIcon) with the code below,
// then delete Sources/Eclick/MenuIcon.swift.

import AppKit

// In configureStatusItem():
//
//     if let button = statusItem.button {
//         button.image = NSImage(
//             systemSymbolName: "cursorarrow.click",
//             accessibilityDescription: "Eclick"
//         )
//         button.toolTip = "Eclick — keyboard hints for clickable controls"
//     }

// While scanning (in toggleHintMode()):
//
//     statusItem.button?.image = NSImage(
//         systemSymbolName: "viewfinder",
//         accessibilityDescription: "Eclick is scanning"
//     )

// In restoreStatusIcon():
//
//     private func restoreStatusIcon() {
//         statusItem.button?.image = NSImage(
//             systemSymbolName: "cursorarrow.click",
//             accessibilityDescription: "Eclick"
//         )
//     }

enum MenuIconBackup {
    static let idleSymbolName = "cursorarrow.click"
    static let scanningSymbolName = "viewfinder"
}
