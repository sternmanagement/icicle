import AppKit
import ImageIO
import SwiftUI

// Settings panes for the extras: clipboard, windows and appearance.

struct ClipboardPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: ClipboardHistory

    var body: some View {
        Form {
            Section {
                Toggle("Keep clipboard history", isOn: $settings.clipboardEnabled)
                LabeledContent("Open history") {
                    KeyRecorder(combo: $settings.clipboardHotKey)
                }
                .disabled(!settings.clipboardEnabled)
                Toggle("Paste the chosen item right away", isOn: $settings.clipboardAutoPaste)
                    .disabled(!settings.clipboardEnabled)
            } footer: {
                Text("Press the shortcut in any app, pick an item with the arrow keys or ⌘1–9, and press Return. Without automatic pasting, the item is just copied back so you can press ⌘V yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.clipboardEnabled {
                Section {
                    LabeledContent("Items remembered") {
                        Text("\(history.items.count) of \(ClipboardHistory.capacity)").monospacedDigit()
                    }
                    Button("Clear History", role: .destructive) { history.clear() }
                        .disabled(history.items.isEmpty)
                } footer: {
                    Text("History stays in memory and is forgotten when Icicle quits. Copies that password managers mark as private are never saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if settings.clipboardAutoPaste {
                Section {
                    AccessibilityRow(reason: "Needed to paste into other apps for you.")
                }
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.clipboardEnabled)
    }
}

struct WindowsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var workspaces = WorkspaceStore.shared
    @State private var newName = ""
    @State private var savedMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Window switcher", isOn: $settings.windowSwitcherEnabled)
                LabeledContent("Shortcut") {
                    KeyRecorder(combo: $settings.windowSwitcherHotKey)
                }
                .disabled(!settings.windowSwitcherEnabled)
            } header: {
                Text("Switcher")
            } footer: {
                Text("Hold the modifier and tap the key to step through every window, minimized ones included. Add ⇧ to go backwards, use the arrow keys, or click a window. Let go to switch; Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Saved workspaces", isOn: $settings.workspacesEnabled)
                if settings.workspacesEnabled {
                    HStack {
                        TextField("Name", text: $newName, prompt: Text("e.g. Coding"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveLayout)
                        Button("Save Current Layout", action: saveLayout)
                    }
                    if let savedMessage {
                        Text(savedMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(workspaces.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        HStack(spacing: 10) {
                            Image(systemName: "square.grid.3x1.below.line.grid.1x2").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(workspace.name)
                                Text("\(workspace.windows.count) windows · \(Set(workspace.windows.map(\.appName)).count) apps")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if index < 9, settings.workspaceHotKeysEnabled {
                                Text("⌃⌥\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Button("Restore") { workspaces.restore(workspace) }
                            Button(role: .destructive) { workspaces.delete(workspace) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Toggle("Restore with ⌃⌥1 – ⌃⌥9", isOn: $settings.workspaceHotKeysEnabled)
                }
            } header: {
                Text("Workspaces")
            } footer: {
                Text("A workspace remembers where every app's windows are. Restoring opens apps that aren't running and puts their windows back. Also in the ❄ menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Outline the focused window", isOn: $settings.focusBorderEnabled)
                if settings.focusBorderEnabled {
                    ColorPicker("Colour", selection: $settings.focusBorderColor.color, supportsOpacity: true)
                    LabeledContent("Thickness") {
                        HStack {
                            Slider(value: $settings.focusBorderWidth, in: 2...10, step: 1)
                                .frame(maxWidth: 220)
                            Text("\(Int(settings.focusBorderWidth)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Focus border")
            } footer: {
                Text("Draws a coloured outline around whichever window you're typing in, so it's easy to spot. Hidden for full-screen windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                AccessibilityRow(reason: "Needed to list, move and bring forward other apps' windows.")
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.workspacesEnabled)
        .animation(.default, value: settings.focusBorderEnabled)
    }

    private func saveLayout() {
        guard AccessibilityAccess.isTrusted else { AccessibilityAccess.request(); return }
        let count = workspaces.saveCurrentLayout(named: newName)
        savedMessage = "Saved \(count) windows."
        newName = ""
    }
}

struct AppearancePane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                MenuBarPreview(settings: settings)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                Picker("Shape", selection: $settings.menuBarShape) {
                    ForEach(MenuBarShape.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Border", isOn: $settings.menuBarBorder)
                Toggle("Shadow", isOn: $settings.menuBarShadow)
            } header: {
                Text("Menu bar")
            } footer: {
                Text("Floating draws the menu bar as a rounded pill; Split gives the app menus and the status icons a pill each, resizing as you switch apps. Without a tint, the pills are frosted glass. Split needs Accessibility access to see where the menus end.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Tint the menu bar", isOn: $settings.menuBarTintEnabled)
                if settings.menuBarTintEnabled {
                    Picker("Style", selection: $settings.menuBarTintStyle) {
                        ForEach(TintStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if settings.menuBarTintStyle == .wallpaper {
                        Text("Colours are picked from the top of each display's wallpaper and follow it when it changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        tintRow("Light mode", start: $settings.tintLightStart, end: $settings.tintLightEnd, scheme: .light)
                        tintRow("Dark mode", start: $settings.tintDarkStart, end: $settings.tintDarkEnd, scheme: .dark)
                    }
                }
            } header: {
                Text("Tint")
            } footer: {
                Text("Pick separate colours for light and dark mode; lower the opacity in the colour picker for a subtler wash. macOS picks the menu bar's text colour from your wallpaper, so very dark or very light tints can make it harder to read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Hide the notch", isOn: $settings.hideNotch)
                    .disabled(!NSScreen.screens.contains(where: MenuBarAppearance.hasNotch))
            } header: {
                Text("Notch")
            } footer: {
                Text(NSScreen.screens.contains(where: MenuBarAppearance.hasNotch)
                     ? "Paints the menu bar black on displays with a camera notch so the notch blends in. Takes priority over the shape and tint there. Reads best in Dark Mode, where the menu bar text is white."
                     : "None of your displays has a camera notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Round the screen corners", isOn: $settings.roundedCornersEnabled)
                if settings.roundedCornersEnabled {
                    sliderRow("Radius", value: $settings.roundedCornerRadius, in: 6...28, step: 1) { "\(Int($0)) pt" }
                }
                Toggle("Dim windows behind the one you're using", isOn: $settings.dimEnabled)
                if settings.dimEnabled {
                    sliderRow("Amount", value: $settings.dimAmount, in: 0.1...0.7, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
                }
            } header: {
                Text("Desktop")
            } footer: {
                Text("Rounded corners give every display soft corners like an iPhone's, over everything including full-screen apps. Dimming fades out everything but the window you're using so it stands out; click anywhere to switch as usual. Dimming needs Accessibility access to follow the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.menuBarTintEnabled)
        .animation(.default, value: settings.menuBarTintStyle)
        .animation(.default, value: settings.roundedCornersEnabled)
        .animation(.default, value: settings.dimEnabled)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                           label: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                    .frame(maxWidth: 220)
                Text(label(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func tintRow(_ title: String, start: Binding<String>, end: Binding<String>, scheme: ColorScheme) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                TintPreview(colors: settings.menuBarTintStyle == .gradient ? [start.wrappedValue, end.wrappedValue] : [start.wrappedValue],
                            scheme: scheme)
                ColorPicker("Start", selection: start.color, supportsOpacity: true).labelsHidden()
                if settings.menuBarTintStyle == .gradient {
                    ColorPicker("End", selection: end.color, supportsOpacity: true).labelsHidden()
                }
            }
        }
    }
}

/// The top of a desktop, drawn with the current shape, tint, border and shadow over your own wallpaper.
private struct MenuBarPreview: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var wallpaper: NSImage?
    @State private var wallpaperColors: [String]?

    private static let barHeight: CGFloat = 24

    var body: some View {
        ZStack(alignment: .top) {
            MenuBarDecoration(fill: fill, shape: settings.menuBarShape, islands: Islands(left: 196, right: 172),
                              border: settings.menuBarBorder, shadow: settings.menuBarShadow, barHeight: Self.barHeight) { outline, _ in
                AnyView(Rectangle().fill(.regularMaterial).mask(outline))
            }
            .animation(.smooth(duration: 0.3), value: settings.menuBarShape)
            HStack(spacing: 14) {
                Image(systemName: "apple.logo")
                Text("Finder").fontWeight(.bold)
                Text("File")
                Text("Edit")
                Text("View")
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "snowflake")
                Text("Mon 9:41")
            }
            .font(.system(size: 12))
            .foregroundStyle(colorScheme == .dark ? .white : .black)
            .padding(.horizontal, 20)
            .frame(height: Self.barHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 70)
        .background(alignment: .top) { backdrop }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear(perform: loadWallpaper)
    }

    @ViewBuilder private var backdrop: some View {
        if let wallpaper {
            Image(nsImage: wallpaper).resizable().scaledToFill()
        } else {
            LinearGradient(colors: colorScheme == .dark ? [Color(hex: "#1F2A44"), Color(hex: "#3B2A55")]
                                                        : [Color(hex: "#BFD9F5"), Color(hex: "#E2CFF3")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var fill: [Color]? {
        guard settings.menuBarTintEnabled else { return nil }
        if settings.menuBarTintStyle == .wallpaper, let wallpaperColors { return wallpaperColors.map { Color(hex: $0) } }
        let colors = colorScheme == .dark ? [settings.tintDarkStart, settings.tintDarkEnd] : [settings.tintLightStart, settings.tintLightEnd]
        return (settings.menuBarTintStyle == .solid ? [colors[0]] : colors).map { Color(hex: $0) }
    }

    private func loadWallpaper() {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 1200,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            let image = CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
                .map { NSImage(cgImage: $0, size: .zero) }
            let colors = MenuBarAppearance.topColors(of: url)
            DispatchQueue.main.async {
                wallpaper = image
                wallpaperColors = colors
            }
        }
    }
}

/// A sliver of menu bar showing the tint over a wallpaper-ish backdrop.
private struct TintPreview: View {
    let colors: [String]
    let scheme: ColorScheme

    var body: some View {
        ZStack {
            LinearGradient(colors: scheme == .dark ? [Color(white: 0.15), Color(white: 0.3)] : [Color(white: 0.85), Color(white: 0.97)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing)
            HStack(spacing: 6) {
                Image(systemName: "apple.logo")
                Text("Finder").fontWeight(.semibold)
                Spacer()
                Image(systemName: "wifi")
                Text("9:41")
            }
            .font(.system(size: 9))
            .foregroundStyle(scheme == .dark ? .white : .black)
            .padding(.horizontal, 8)
        }
        .frame(width: 170, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
    }
}
