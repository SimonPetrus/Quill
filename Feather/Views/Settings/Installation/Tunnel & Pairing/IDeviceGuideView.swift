//
//  IDeviceGuideView.swift
//  Quill
//
//  Step-by-step guide for setting up the idevice installation method.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct IDeviceGuideView: View {
	// MARK: Body
	var body: some View {
		NBList(.localized("How to set up idevice")) {
			Section {
				_step(1, .localized("Get a pairing file on a computer"), .localized("Install iTunes or Apple Devices (Windows) for the iPhone driver, then download idevice_pair. Connect the iPhone with a cable, tap \"Trust\" and enter the passcode. Select the device in idevice_pair, generate the pairing file and save it. Send it to your phone (AirDrop, Files, Telegram)."))
				Button(.localized("Open idevice_pair Downloads"), systemImage: "arrow.down.circle") {
					UIApplication.open("https://github.com/jkcoxson/idevice_pair/releases")
				}
				_step(2, .localized("Import the pairing file"), .localized("Tap \"Import Pairing File\" in the idevice settings and pick the file."))
				_step(3, .localized("Install and connect LocalDevVPN"), .localized("Get LocalDevVPN from the App Store and connect it. The VPN stays on your device; it only lets Quill reach the install service of your phone."))
				Button(.localized("Download LocalDevVPN"), systemImage: "arrow.down.app") {
					UIApplication.open("https://apps.apple.com/us/app/localdevvpn/id6755608044")
				}
				_step(4, .localized("Use Wi-Fi or Airplane mode"), .localized("Be connected to Wi-Fi, or turn on Airplane mode."))
				_step(5, .localized("Install with idevice"), .localized("Set Installation Type to idevice and install. You can switch back to Server afterwards. The pairing file stays valid until you reset the phone."))
			} header: {
				Text(.localized("With a computer (one time)"))
			}
			
			Section {
				Text(verbatim: String.localized(
					"Install the update with another signer that is still on your phone (for example Feather). Open the Quill IPA there, set the bundle ID to %@ and install it with the server method. Quill keeps its data.",
					arguments: Bundle.main.bundleIdentifier ?? "-"
				))
				.font(.subheadline)
			} header: {
				Text(.localized("Without a computer"))
			}
		}
	}
	
	@ViewBuilder
	private func _step(_ number: Int, _ title: String, _ detail: String) -> some View {
		HStack(alignment: .top, spacing: 12) {
			Text("\(number)")
				.font(.headline)
				.foregroundStyle(.white)
				.frame(width: 26, height: 26)
				.background(Circle().fill(Color.accentColor))
			VStack(alignment: .leading, spacing: 4) {
				Text(title).font(.headline)
				Text(detail)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
		}
		.padding(.vertical, 2)
	}
}
