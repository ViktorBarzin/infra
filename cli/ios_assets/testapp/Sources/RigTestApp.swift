import SwiftUI

// Deliberately loud on screen: a screenshot taken by the rig has to be
// readable enough to tell this build apart from the last one.
@main
struct RigTestApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    private let builtAt = Date()

    var body: some View {
        VStack(spacing: 24) {
            Text("ios-rig")
                .font(.system(size: 56, weight: .bold, design: .rounded))
            Text("sideload works")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(builtAt.formatted(date: .abbreviated, time: .standard))
                .font(.system(.title3, design: .monospaced))
                .padding(.top, 8)
            Text("me.viktorbarzin.rigtest")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.35, blue: 0.55))
        .foregroundStyle(.white)
        .ignoresSafeArea()
    }
}
