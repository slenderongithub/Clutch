# Swift & SwiftUI Coding Guidelines

You are an expert Apple Developer. When writing frontend code for this project, you must strictly adhere to the Apple Human Interface Guidelines (HIG) for macOS. You are building a desktop app, NOT an iOS app.

## 1. UI & Layout Architecture
- **Never use `NavigationView`.** Always use `NavigationSplitView` for the main architecture (sidebar on the left, detail view on the right).
- **Native Materials:** Do not use solid colors for the app background. Use macOS system materials to achieve the "Liquid Glass" / Vibrancy effect. 
  - Sidebar background: `.background(.regularMaterial)` or `.background(.ultraThinMaterial)`.
- **Spacing & Padding:** Do NOT hardcode padding values (e.g., `padding(15)`). Use the default `.padding()` so macOS scales it perfectly based on the user's display.

## 2. Typography & Colors
- **Never hardcode font sizes or custom fonts.** Use ONLY semantic typography: `.font(.largeTitle)`, `.font(.title)`, `.font(.headline)`, `.font(.body)`, `.font(.caption)`.
- **Never use custom hex colors** unless specifically requested for a logo. Rely on semantic colors:
  - Primary text: `.primary`
  - Secondary/helper text: `.secondary` (so it automatically adjusts in Dark Mode).
  - Use `.accentColor` for interactive elements.

## 3. Controls, Icons, and Animations
- **Icons:** NEVER use text emojis or third-party SVGs. You MUST use Apple's **SF Symbols** exclusively (e.g., `Image(systemName: "doc.text.magnifyingglass")`).
- **Buttons:** Use native macOS button styles. 
  - Main actions (e.g., Generate PDF): `.buttonStyle(.borderedProminent)`.
  - Secondary actions: `.buttonStyle(.bordered)`.
- **Toggles:** For the Cloud vs. Local mode switch, use a `Picker` with `.pickerStyle(.segmented)` to create the native pill-shaped toggle.
- **Lists:** Use `.listStyle(.sidebar)` for navigation lists to get native hover and selection behaviors.
- **Animations:** Wrap state changes in `withAnimation(.spring(response: 0.4, dampingFraction: 0.8))` to ensure fluid, non-linear Apple-style motion.

## 4. Code Structure
- **No Massive Views:** Break down views into smaller, reusable components (e.g., `SidebarView`, `JobDescriptionInputView`, `GraphVisualizerView`).
- **State Management:** Use `@State` for local view changes and `@EnvironmentObject` or `@Observable` (Swift 17+) for global app state (like tracking if the 5GB model is currently downloading). 

Whenever you are asked to generate UI code, you must read this file first to ensure compliance with macOS native standards.
