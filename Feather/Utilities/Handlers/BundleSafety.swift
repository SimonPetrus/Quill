//
//  BundleSafety.swift
//  Quill
//
//  IPAs are untrusted. While signing, paths derived from their contents
//  (CFBundleExecutable, symbolic links) are written to in place, so they must
//  stay inside the app bundle.
//

import Foundation

enum BundleSafety {
	/// A CFBundleExecutable value must be a plain file name.
	static func isValidExecutableName(_ name: String) -> Bool {
		!name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
	}

	/// Returns a description of the first problem found under `root`, or nil when it is safe:
	/// a symbolic link that resolves outside `root` (or to nothing), or a bundle whose
	/// CFBundleExecutable is not a plain file name or is a symbolic link.
	static func firstViolation(in root: URL) -> String? {
		guard let realRoot = _realPath(root.path) else {
			return root.lastPathComponent
		}

		if let problem = _executableViolation(of: root) {
			return problem
		}

		// does not descend into symbolic links to folders; they are checked as links
		guard let enumerator = FileManager.default.enumerator(
			at: root,
			includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
			options: []
		) else {
			return nil
		}

		for case let url as URL in enumerator {
			let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
			let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

			if values?.isSymbolicLink == true {
				guard let target = _realPath(url.path), _isInside(target, realRoot) else {
					return relative
				}
				continue
			}

			if values?.isDirectory == true, ["app", "appex", "framework"].contains(url.pathExtension.lowercased()) {
				if let problem = _executableViolation(of: url) {
					return problem
				}
			}
		}

		return nil
	}

	private static func _executableViolation(of bundle: URL) -> String? {
		guard
			let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist")),
			let executable = info["CFBundleExecutable"] as? String
		else {
			return nil
		}

		guard isValidExecutableName(executable) else {
			return "\(bundle.lastPathComponent): CFBundleExecutable \"\(executable)\""
		}

		let url = bundle.appendingPathComponent(executable)
		if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
			return "\(bundle.lastPathComponent)/\(executable)"
		}

		return nil
	}

	private static func _realPath(_ path: String) -> String? {
		guard let resolved = realpath(path, nil) else {
			return nil
		}
		defer { free(resolved) }
		return String(cString: resolved)
	}

	private static func _isInside(_ path: String, _ root: String) -> Bool {
		path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
	}
}
