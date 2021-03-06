/*
 This source file is part of the Swift.org open source project
 
 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception
 
 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basic
import PackageModel

/// Create an initial template package.
public final class InitPackage {
    /// Represents a package type for the purposes of initialization.
    public enum PackageType: String, CustomStringConvertible {
        case empty = "empty"
        case library = "library"
        case executable = "executable"
        case systemModule = "system-module"

        public var description: String {
            return rawValue
        }
    }

    /// A block that will be called to report progress during package creation
    public var progressReporter: ((String) -> Void)?

    /// Where to crerate the new package
    let destinationPath: AbsolutePath

    /// The type of package to create.
    let packageType: PackageType

    /// The name of the package to create.
    let pkgname: String

    /// The name of the target to create.
    var moduleName: String

    /// The name of the type to create (within the package).
    var typeName: String {
        return moduleName
    }

    /// Create an instance that can create a package of the given packageType at the given destinationPath
    public init(destinationPath: AbsolutePath, packageType: PackageType) throws {
        self.packageType = packageType
        self.destinationPath = destinationPath
        let dirname = destinationPath.basename
        assert(!dirname.isEmpty)  // a base name is never empty
        self.pkgname = dirname
        self.moduleName = dirname.mangledToC99ExtendedIdentifier()
    }

    /// Actually creates the new package at the destinationPath
    public func writePackageStructure() throws {
        progressReporter?("Creating \(packageType) package: \(pkgname)")

        // FIXME: We should form everything we want to write, then validate that
        // none of it exists, and then act.
        try writeManifestFile()
        try writeREADMEFile()
        try writeGitIgnore()
        try writeSources()
        try writeModuleMap()
        try writeTests()
    }

    private func writePackageFile(_ path: AbsolutePath, body: (OutputByteStream) -> Void) throws {
        progressReporter?("Creating \(path.relative(to: destinationPath).asString)")
        try localFileSystem.writeFileContents(path, body: body)
    }

    private func writeManifestFile() throws {
        let manifest = destinationPath.appending(component: Manifest.filename)
        guard exists(manifest) == false else {
            throw InitError.manifestAlreadyExists
        }

        try writePackageFile(manifest) { stream in
            stream <<< "\nimport PackageDescription\n"
            stream <<< "\n"
            stream <<< "let package = Package(\n"
            stream <<< "    name: \"\(pkgname)\"\n"
            stream <<< ")\n"
        }

        // Create a tools version with current version but with patch set to zero.
        // We do this to avoid adding unnecessary constraints to patch versions, if
        // the package really needs it, they should add it manually.
        // FIXME: <rdar://problem/31709046> Generate v4 manifests from `swift package init`
        let version = ToolsVersion.defaultToolsVersion.zeroedPatch

        // Write the current tools version.
        try writeToolsVersion(
            at: manifest.parentDirectory, version: version, fs: &localFileSystem)
    }

    private func writeREADMEFile() throws {
        let readme = destinationPath.appending(component: "README.md")
        guard exists(readme) == false else {
            return
        }

        try writePackageFile(readme) { stream in
            stream <<< "# \(pkgname)\n"
            stream <<< "\n"
            stream <<< "A description of this package.\n"
        }
    }

    private func writeGitIgnore() throws {
        let gitignore = destinationPath.appending(component: ".gitignore")
        guard exists(gitignore) == false else {
            return
        }

        try writePackageFile(gitignore) { stream in
            stream <<< ".DS_Store\n"
            stream <<< "/.build\n"
            stream <<< "/Packages\n"
            stream <<< "/*.xcodeproj\n"
        }
    }

    private func writeSources() throws {
        if packageType == .systemModule {
            return
        }
        let sources = destinationPath.appending(component: "Sources")
        guard exists(sources) == false else {
            return
        }
        progressReporter?("Creating \(sources.relative(to: destinationPath).asString)/")
        try makeDirectories(sources)

        if packageType == .empty {
            return
        }

        let sourceFileName = (packageType == .executable) ? "main.swift" : "\(typeName).swift"
        let sourceFile = sources.appending(RelativePath(sourceFileName))

        try writePackageFile(sourceFile) { stream in
            switch packageType {
            case .library:
                stream <<< "struct \(typeName) {\n\n"
                stream <<< "    var text = \"Hello, World!\"\n"
                stream <<< "}\n"
            case .executable:
                stream <<< "print(\"Hello, world!\")\n"
            case .systemModule, .empty:
                fatalError("invalid")
            }
        }
    }

    private func writeModuleMap() throws {
        if packageType != .systemModule {
            return
        }
        let modulemap = destinationPath.appending(component: "module.modulemap")
        guard exists(modulemap) == false else {
            return
        }

        try writePackageFile(modulemap) { stream in
            stream <<< "module \(moduleName) [system] {\n"
            stream <<< "  header \"/usr/include/\(moduleName).h\"\n"
            stream <<< "  link \"\(moduleName)\"\n"
            stream <<< "  export *\n"
            stream <<< "}\n"
        }
    }

    private func writeTests() throws {
        if packageType == .systemModule {
            return
        }
        let tests = destinationPath.appending(component: "Tests")
        guard exists(tests) == false else {
            return
        }
        progressReporter?("Creating \(tests.relative(to: destinationPath).asString)/")
        try makeDirectories(tests)

        // Only libraries are testable for now.
        if packageType == .library {
            try writeLinuxMain(testsPath: tests)
            try writeTestFileStubs(testsPath: tests)
        }
    }

    private func writeLinuxMain(testsPath: AbsolutePath) throws {
        try writePackageFile(testsPath.appending(component: "LinuxMain.swift")) { stream in
            stream <<< "import XCTest\n"
            stream <<< "@testable import \(moduleName)Tests\n\n"
            stream <<< "XCTMain([\n"
            stream <<< "    testCase(\(typeName)Tests.allTests),\n"
            stream <<< "])\n"
        }
    }

    private func writeTestFileStubs(testsPath: AbsolutePath) throws {
        let testModule = testsPath.appending(RelativePath(pkgname + Target.testModuleNameSuffix))
        progressReporter?("Creating \(testModule.relative(to: destinationPath).asString)/")
        try makeDirectories(testModule)

        try writePackageFile(testModule.appending(RelativePath("\(moduleName)Tests.swift"))) { stream in
            stream <<< "import XCTest\n"
            stream <<< "@testable import \(moduleName)\n"
            stream <<< "\n"
            stream <<< "class \(moduleName)Tests: XCTestCase {\n"
            stream <<< "    func testExample() {\n"
            stream <<< "        // This is an example of a functional test case.\n"
            stream <<< "        // Use XCTAssert and related functions to verify your tests produce the correct\n"
            stream <<< "        // results.\n"
            stream <<< "        XCTAssertEqual(\(typeName)().text, \"Hello, World!\")\n"
            stream <<< "    }\n"
            stream <<< "\n"
            stream <<< "\n"
            stream <<< "    static var allTests = [\n"
            stream <<< "        (\"testExample\", testExample),\n"
            stream <<< "    ]\n"
            stream <<< "}\n"
        }
    }

}

// Private helpers

private enum InitError: Swift.Error {
    case manifestAlreadyExists
}

extension InitError: CustomStringConvertible {
    var description: String {
        switch self {
        case .manifestAlreadyExists:
            return "a manifest file already exists in this directory"
        }
    }
}
