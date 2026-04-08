//
//  MenuBarView.swift
//  Mac native speech to text
//
//  Created by Kartik Khorwal on 4/8/26.
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch appState.phase {
            case .listening:
                Text("Listening...")
                    .font(.headline)
            case .processing:
                Text("Processing...")
                    .font(.headline)
            case .hidden:
                Text("Hold ⌃⌥ (Ctrl+Option) to dictate")
                    .font(.body)
            }
        }
        .padding(8)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
