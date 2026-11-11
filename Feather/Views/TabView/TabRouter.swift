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
	
	@Published var selected: TabEnum = .sources
	
	private init() {}
}
