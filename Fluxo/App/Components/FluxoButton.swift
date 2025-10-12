//
//  FluxoButton.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-07.
//

import SwiftUI

struct FluxoButton: View {
    let label: String
    var loading: Bool = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Text(label)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
    }
}

#Preview {
    FluxoButton(label: "Tap me") {
        print("Tapped!")
    }
}
