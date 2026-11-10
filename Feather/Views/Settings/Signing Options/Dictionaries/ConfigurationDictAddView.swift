//
//  ConfigurationDictAddView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct ConfigurationDictAddView: View {
	@Environment(\.dismiss) var dismiss
	
	@State private var _newKey = ""
	@State private var _newValue = ""
	@State private var _showOverrideAlert = false
	
	var saveButtonDisabled: Bool {
		_newKey.isEmpty || _newValue.isEmpty
	}
	
	@Binding var dataDict: [String: String]
	var editingKey: String? = nil
	
	// MARK: Body
	var body: some View {
		NBList(editingKey == nil ? .localized("New") : .localized("Edit")) {
			Section {
				TextField(.localized("Value"), text: $_newKey)
				TextField(.localized("Replacement"), text: $_newValue)
			}
			.autocapitalization(.none)
		}
		.onAppear {
			if let editingKey, _newKey.isEmpty, _newValue.isEmpty {
				_newKey = editingKey
				_newValue = dataDict[editingKey] ?? ""
			}
		}
		.toolbar {
			NBToolbarButton(
				.localized("Save"),
				style: .text,
				placement: .confirmationAction,
				isDisabled: saveButtonDisabled
			) {
				if let editingKey, editingKey != _newKey {
					dataDict.removeValue(forKey: editingKey)
				}
				dataDict[_newKey] = _newValue
				OptionsManager.shared.saveOptions()
				dismiss()
			}
		}
	}
}
