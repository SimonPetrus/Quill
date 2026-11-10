//
//  ZipEntryValidator.swift
//  Quill
//
//  marmelroy/Zip 2.1.2 (used to extract IPAs) writes every entry to
//  `destination.appendingPathComponent(name)` without rejecting ".."
//  components ("zip slip"), so a crafted IPA could write anywhere in Quill's
//  container (other apps, certificates, the database). It does not create
//  symbolic links (link entries become small regular files).
//
//  This walks the central directory exactly like Zip's bundled minizip
//  (unzOpenInternal / unzGoToNextFile) and rejects unsafe entry names
//  before anything is extracted.
//

import Foundation

enum ZipEntryValidator {
	enum Failure: Error, LocalizedError {
		/// minizip would not open the archive either.
		case unreadable(String)
		/// An entry name that would be written outside the destination folder.
		case unsafePath(String)

		var errorDescription: String? {
			switch self {
			case .unreadable(let reason): "Invalid ZIP archive (\(reason))."
			case .unsafePath(let name): "Unsafe path in archive: \(name)"
			}
		}
	}

	/// Throws `.unsafePath` when an entry name has a ".." path component, after Zip's own
	/// treatment of the name (it ends at the first NUL, "\" is a separator).
	static func validate(_ url: URL) throws {
		let reader = try _Reader(url)
		defer { reader.close() }
		let fileSize = reader.size

		// minizip: last end-of-central-directory signature within the last 0xFFFF bytes
		let window = min(fileSize, 0xFFFF)
		let tailStart = fileSize - window
		guard
			let tail = reader.bytes(at: tailStart, count: Int(window)),
			let eocdIndex = _lastIndex(of: 0x06054b50, in: tail),
			tailStart + UInt64(eocdIndex) != 0
		else {
			throw Failure.unreadable("no end of central directory")
		}
		let eocdPosition = tailStart + UInt64(eocdIndex)

		guard
			let eocd = reader.bytes(at: eocdPosition, count: 22),
			let entriesOnDisk = _u16(eocd, 8),
			let entriesTotal = _u16(eocd, 10),
			let size32 = _u32(eocd, 12),
			let offset32 = _u32(eocd, 16),
			entriesOnDisk == entriesTotal
		else {
			throw Failure.unreadable("end of central directory")
		}

		var entryCount = UInt64(entriesOnDisk)
		var directorySize = UInt64(size32)
		var directoryOffset = UInt64(offset32)
		var centralPosition = eocdPosition

		// minizip switches to zip64 on these markers (sic: size compared with 0xFFFF), using the
		// locator right before the end of central directory record
		if entriesOnDisk == 0xFFFF || size32 == 0xFFFF || offset32 == 0xFFFFFFFF {
			guard
				eocdPosition >= 20,
				let locator = reader.bytes(at: eocdPosition - 20, count: 20),
				_u32(locator, 0) == 0x07064b50,
				let recordPosition = _u64(locator, 8),
				let record = reader.bytes(at: recordPosition, count: 56),
				_u32(record, 0) == 0x06064b50,
				let entries = _u64(record, 24),
				let entriesCD = _u64(record, 32),
				let size = _u64(record, 40),
				let offset = _u64(record, 48),
				entries == entriesCD
			else {
				throw Failure.unreadable("zip64 end of central directory")
			}
			entryCount = entries
			directorySize = size
			directoryOffset = offset
			centralPosition = recordPosition
		}

		guard
			directoryOffset <= UInt64.max - directorySize,
			centralPosition >= directoryOffset + directorySize
		else {
			throw Failure.unreadable("central directory offset")
		}
		// data may be prefixed; entries are read relative to where the archive starts
		let bytesBefore = centralPosition - (directoryOffset + directorySize)

		// unzGoToFirstFile / unzGoToNextFile: entries are read from the file one after another
		// (not limited to the directory size); 0xFFFF entries means "until a header is invalid";
		// Zip stops at the first invalid header without extracting it
		var position = directoryOffset
		var index: UInt64 = 0
		while entryCount == 0xFFFF || index < entryCount {
			guard
				position <= UInt64.max - bytesBefore - 46,
				let header = reader.bytes(at: position + bytesBefore, count: 46),
				_u32(header, 0) == 0x02014b50,
				let nameLength = _u16(header, 28),
				let extraLength = _u16(header, 30),
				let commentLength = _u16(header, 32)
			else {
				break
			}

			guard let name = reader.bytes(at: position + bytesBefore + 46, count: Int(nameLength)) else {
				break
			}
			if _isUnsafe(name) {
				throw Failure.unsafePath(String(decoding: name.prefix { $0 != 0 }, as: UTF8.self))
			}

			position += 46 + UInt64(nameLength) + UInt64(extraLength) + UInt64(commentLength)
			index += 1
		}
	}

	private static func _isUnsafe(_ name: Data) -> Bool {
		// Zip reads the name with String(cString:), so it ends at the first NUL
		let bytes = name.prefix { $0 != 0 }
		// "/" and "\" both separate components (Zip turns "\" into "/")
		let components = bytes.split(omittingEmptySubsequences: false) { $0 == 0x2F || $0 == 0x5C }
		return components.contains { $0.count == 2 && $0.allSatisfy { $0 == 0x2E } }
	}

	/// Last position of a little-endian 32-bit signature in `data`.
	private static func _lastIndex(of signature: UInt32, in data: Data) -> Int? {
		guard data.count >= 4 else { return nil }
		var index = data.count - 4
		while index >= 0 {
			if _u32(data, index) == signature {
				return index
			}
			index -= 1
		}
		return nil
	}

	private static func _u16(_ data: Data, _ offset: Int) -> UInt16? {
		guard offset >= 0, offset + 2 <= data.count else { return nil }
		let base = data.startIndex + offset
		return UInt16(data[base]) | UInt16(data[base + 1]) << 8
	}

	private static func _u32(_ data: Data, _ offset: Int) -> UInt32? {
		guard offset >= 0, offset + 4 <= data.count else { return nil }
		let base = data.startIndex + offset
		return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[base + $1]) << (8 * UInt32($1)) }
	}

	private static func _u64(_ data: Data, _ offset: Int) -> UInt64? {
		guard offset >= 0, offset + 8 <= data.count else { return nil }
		let base = data.startIndex + offset
		return (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[base + $1]) << (8 * UInt64($1)) }
	}

	/// Small buffered reader, so multi-GB IPAs are never loaded into memory.
	private final class _Reader {
		let size: UInt64
		private let _handle: FileHandle
		private var _bufferStart: UInt64 = 0
		private var _buffer = Data()
		private static let _chunk = 1 << 20

		init(_ url: URL) throws {
			_handle = try FileHandle(forReadingFrom: url)
			size = try _handle.seekToEnd()
		}

		func close() {
			try? _handle.close()
		}

		/// `count` bytes at `offset`, or nil when they are not all inside the file.
		func bytes(at offset: UInt64, count: Int) -> Data? {
			guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
				return nil
			}
			if count == 0 {
				return Data()
			}
			let bufferEnd = _bufferStart + UInt64(_buffer.count)
			if offset < _bufferStart || offset + UInt64(count) > bufferEnd {
				let length = min(max(count, Self._chunk), Int(min(size - offset, UInt64(Int.max))))
				guard
					(try? _handle.seek(toOffset: offset)) != nil,
					let data = try? _handle.read(upToCount: length),
					data.count >= count
				else {
					return nil
				}
				_bufferStart = offset
				_buffer = data
			}
			let start = Int(offset - _bufferStart)
			return _buffer.subdata(in: start..<(start + count))
		}
	}
}
