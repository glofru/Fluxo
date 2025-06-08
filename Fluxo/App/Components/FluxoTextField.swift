//
//  FluxoTextField.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-05.
//

import SwiftUI

struct FluxoTextField: View {
    @EnvironmentObject private var themeManager: ThemeManager

    @Binding private var text: String

    let name: String
    let placeholder: String?
    let error: String?

    init(_ name: String, text: Binding<String>, placeholder: String? = nil, error: String? = nil) {
        self.name = name
        self._text = text
        self.placeholder = placeholder
        self.error = error
    }

    var body: some View {
        VStack(alignment: .center) {
            HStack {
                Text(name)
                    .bold()
                    .padding(.trailing, 4)
                    .frame(width: 55)

                ZStack(alignment: .leading) {
                    if text.isEmpty, let placeholder {
                        Text(placeholder)
                            .foregroundColor(themeManager.selectedTheme.placeholderTextColor)
                    }

                    TextField("", text: $text)
                        .background(.clear)
                        .foregroundStyle(themeManager.selectedTheme.textColor.opacity(0.9))
                        .textFieldStyle(.plain)
                }.padding(.leading, 4)
            }

            if let error {
                Text(error)
                    .foregroundStyle(themeManager.selectedTheme.errorTextColor)
            }
        }
        .padding()
        .overlay {
            RoundedRectangle(cornerRadius: themeManager.selectedTheme.cornerRadius)
                .stroke(themeManager.selectedTheme.textColor, lineWidth: 0.2)
        }
    }
}

#Preview {
    FluxoTextField("Preview", text: .constant("Preview")).environmentObject(ThemeManager())
}
