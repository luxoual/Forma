//
//  Colors.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 3/5/26.
//

import SwiftUI

extension DesignSystem{
    enum Colors {
        /// Primary color - #191919 (Dark gray, almost black)
        static let primary = Color(red: 25/255, green: 25/255, blue: 25/255)
        
        /// Secondary color - #535353 (Medium gray)
        static let secondary = Color(red: 83/255, green: 83/255, blue: 83/255)
        
        /// Tertiary color - #86B8FE (Light blue)
        static let tertiary = Color(red: 134/255, green: 184/255, blue: 254/255)
        
        /// Text color - #FFFFFF (White)
        static let text = Color.white

        /// Destructive color - #FE8686 (matches tertiary's saturation/lightness
        /// with a red hue). Used for delete actions and other destructive UI.
        static let destructive = Color(red: 254/255, green: 134/255, blue: 134/255)
    }
}
