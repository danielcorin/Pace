import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Pace")
                .font(.largeTitle.bold())
            Text("A fresh macOS app, built and shipped without opening Xcode.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 360, minHeight: 240)
    }
}

#Preview {
    ContentView()
}
