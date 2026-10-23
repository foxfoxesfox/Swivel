import AppKit

// Headless test mode:
//   Swivel --targets <file>...           list the wheel options for these files
//   Swivel --convert <file>... <target>  convert and print the output paths
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--targets" || args.first == "--convert" {
    _ = NSApplication.shared // documents → PDF lay text out with AppKit
    let isConvert = args[0] == "--convert"
    var files = args.dropFirst().map { URL(fileURLWithPath: $0) }
    let target = isConvert ? files.popLast()?.lastPathComponent.lowercased() : nil
    guard !files.isEmpty else {
        FileHandle.standardError.write("usage: Swivel --targets <file>... | --convert <file>... <target>\n".data(using: .utf8)!)
        exit(2)
    }
    guard let target else {
        print(Converter.targets(for: files).joined(separator: " "))
        exit(0)
    }
    let result = Converter.convertAll(files, to: target)
    result.outputs.forEach { print($0.path) }
    result.errors.forEach { FileHandle.standardError.write("error: \($0)\n".data(using: .utf8)!) }
    exit(result.errors.isEmpty ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
