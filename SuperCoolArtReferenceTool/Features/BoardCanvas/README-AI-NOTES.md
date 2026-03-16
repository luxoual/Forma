//
//  GridScaleBarFinder.swift
//  ProjectUtilities
//
//  Created by Assistant on 2026-03-13.
//

import Foundation

/// This utility searches the project to find the grid or scale bar elements.
/// It helps users by locating these components within the project files.
struct GridScaleBarFinder {
    
    /// Searches the project directory for files containing grid or scale bar references.
    /// - Parameter projectPath: The root path of the project to search.
    /// - Returns: An array of file paths where grid or scale bar elements are found.
    static func findGridScaleBars(in projectPath: String) -> [String] {
        var foundFiles = [String]()
        
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(atPath: projectPath)
        
        while let element = enumerator?.nextObject() as? String {
            if element.contains("Grid") || element.contains("ScaleBar") {
                foundFiles.append((projectPath as NSString).appendingPathComponent(element))
            }
        }
        
        return foundFiles
    }
}
