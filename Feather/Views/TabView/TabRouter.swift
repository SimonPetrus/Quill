//
//  TabRouter.swift
//  Quill
//
//  Shared tab selection, so the app update alert and notification can open the Library tab.
//

import SwiftUI

@MainActor
final class TabRouter: ObservableObject {
	static let shared = TabRouter()
	
	/// Changes on every request, so repeated "open Library" requests are always observed.
	@Published private(set) var openLibraryRequest: UUID?
	
	func requestLibrary() {
		openLibraryRequest = UUID()
	}
	
	private init() {}
}
