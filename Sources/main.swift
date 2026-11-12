import AppKit

// Before anything reads a setting: bring over a standalone Glass Lock's designs and choices.
GlassLockMigration.run()

let appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
