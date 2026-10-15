import Foundation
import FoundationXML

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let path = root.appendingPathComponent("Pony.xcodeproj/project.pbxproj")
let data = try Data(contentsOf: path)
let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
guard let project = parsed as? [String: Any], let objects = project["objects"] as? [String: [String: Any]],
      let rootID = project["rootObject"] as? String, objects[rootID]?["isa"] as? String == "PBXProject" else {
    fatalError("Invalid PBX project structure")
}
let fileRefs = objects.values.filter { $0["lastKnownFileType"] as? String == "sourcecode.swift" }
for file in fileRefs {
    guard let name = file["path"] as? String,
          FileManager.default.fileExists(atPath: root.appendingPathComponent("Pony/\(name)").path) else {
        fatalError("Missing Swift source: \(file)")
    }
}
for object in objects.values where object["isa"] as? String == "PBXBuildFile" {
    guard let reference = (object["fileRef"] ?? object["productRef"]) as? String, objects[reference] != nil else {
        fatalError("Dangling build-file reference")
    }
}
let packageRefs = objects.values.filter { $0["isa"] as? String == "XCLocalSwiftPackageReference" }
for package in packageRefs {
    guard let relative = package["relativePath"] as? String,
          FileManager.default.fileExists(atPath: root.appendingPathComponent(relative + "/Package.swift").path) else {
        fatalError("Missing local Swift package")
    }
}
let scheme = root.appendingPathComponent("Pony.xcodeproj/xcshareddata/xcschemes/Pony.xcscheme")
let parser = XMLParser(data: try Data(contentsOf: scheme))
precondition(parser.parse(), "Invalid scheme XML")
print("PASS PBX property-list parse, \(fileRefs.count) source references, local package and scheme XML")
print("SwiftUI syntax parsed separately. iOS SDK type checking and native build still require Xcode.")
