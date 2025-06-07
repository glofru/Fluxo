//
//  ThemeManager.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-04.
//

import SwiftUI

protocol BaseTheme {
    var backgroundColor: Color { get }
    var textColor: Color { get }
    var placeholderTextColor: Color { get }
    var errorTextColor: Color { get }
}

struct MainTheme: BaseTheme {
    var backgroundColor: Color = .init(red: 24/255, green: 31/255, blue: 45/255)
    var textColor: Color = .white
    var placeholderTextColor: Color = .gray
    var errorTextColor: Color = .red
}

class ThemeManager: ObservableObject {
    @Published private(set) var selectedTheme: BaseTheme = MainTheme()
}
