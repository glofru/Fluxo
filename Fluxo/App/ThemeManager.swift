//
//  ThemeManager.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-04.
//

import SwiftUI

protocol BaseTheme {
    var primary: Color { get }
    var secondary: Color { get }

    var accentPrimary: Color { get }

    var textColor: Color { get }
    var placeholderTextColor: Color { get }
    var errorTextColor: Color { get }

    var cornerRadius: CGFloat { get }
}

struct MainTheme: BaseTheme {
    var primary: Color = .init(red: 11 / 255, green: 15 / 255, blue: 26 / 255)
    var secondary: Color = .init(red: 18 / 255, green: 24 / 255, blue: 38 / 255)

    var accentPrimary: Color = .init(red: 0, green: 207 / 255, blue: 255 / 255)

    var textColor: Color = .white
    var placeholderTextColor: Color = .gray
    var errorTextColor: Color = .red

    var cornerRadius: CGFloat = 16
}

class ThemeManager: ObservableObject {
    @Published private(set) var selectedTheme: BaseTheme = MainTheme()
}
