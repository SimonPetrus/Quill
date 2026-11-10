//
//  ArchivePathValidator.swift
//  Quill
//
//  Tweak .deb files (ar + tar) are untrusted like IPAs (see ZipEntryValidator):
//  entry names are joined to an extraction folder, so "..", absolute paths or a
//  path through a symbolic link must not lead outside that folder.
//

import Foundation

enum ArchivePathValidator {
	enum Failure: Error, LocalizedError {
		case unsafePath(String)

		var errorDescription: String? {
			switch self {
			case .unsafePath(let name): "Unsafe path in archive: \(name)"
			}
		}
	}

	/// URL inside `root` for an archive entry `name`, or nil for an entry that names the root
	/// itself (e.g. "./"). Like tar, a leading "/" is dropped; "\" counts as a separator.
	/// Throws when the name has a ".." component or the result (with symbolic links resolved)
	/// would lie outside `root`.
	static func destination(for name: String, in root: URL) throws -> URL? {
		let truncated = name.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
		let components = truncated
			.split(omittingEmptySubsequences: true) { $0 == "/" || $0 == "\\" }
			.map(String.init)
			.filter { $0 != "." }

		guard !components.contains("..") else {
			throw Failure.unsafePath(name)
		}
		guard !components.isEmpty else {
			return nil
		}

		let url = components.reduce(root) { $0.appendingPathComponent($1) }

		// the parent folders may already exist; none of them may be a link out of root
		let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
		let parentPath = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
		guard parentPath == rootPath || parentPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
			throw Failure.unsafePath(name)
		}
		// never write through an existing symbolic link
		if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
			throw Failure.unsafePath(name)
		}

		return url
	}

	/// A single file name (ar member names): no separators, not "." or "..".
	/// A trailing "/" (GNU ar) is ignored.
	static func fileName(_ name: String) throws -> String {
		var trimmed = name
		if trimmed.hasSuffix("/") {
			trimmed.removeLast()
		}
		guard
			!trimmed.isEmpty, trimmed != ".", trimmed != "..",
			!trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("\0")
		else {
			throw Failure.unsafePath(name)
		}
		return trimmed
	}
}
