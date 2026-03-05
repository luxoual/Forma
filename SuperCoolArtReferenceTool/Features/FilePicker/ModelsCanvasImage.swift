//
//  CanvasImage.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI

struct CanvasImage: Identifiable {
    let id = UUID()
    var image: Image
    var position: CGPoint = .zero
    var scale: CGFloat = 1.0
}
