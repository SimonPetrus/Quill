## How does it work?

Quill signs an IPA on the device with Zsign, using a `.p12` and `.mobileprovision` pair, then installs it. There are two ways to install.

#### Install (Server)

- Quill runs a local HTTPS server that hosts the signed IPA, its manifest and assets such as icons.
- `itms-services://?action=download-manifest&url=<PLIST_URL>` is opened with `UIApplication.open` to start the install. iOS requires a valid HTTPS connection for the manifest URL.
- Quill generates a Local CA on the device. It is a name-constrained root CA, limited to `localhost`, and the server certificate is issued from it. Nothing leaves the device and no internet is needed.
- You trust the root once in Settings > General > About > Certificate Trust Settings (see [Local CA setup](README.md#local-ca-setup)). Quill shows the status as "Trusted" when it works.
- itms-services starts the install automatically; Quill monitors the progress of the IPA being streamed.

#### Install (Pairing)

- Establish a heartbeat with a TCP provider. This needs a pairing file from [PlumeImpactor](https://github.com/khcrysalis/Impactor?tab=readme-ov-file#pairing-file) and a [VPN](https://apps.apple.com/us/app/localdevvpn/id6755608044).
- Check the connection to the socket routed to `10.7.0.1`.
- Open an `AFC` connection, create a staging directory at `/PublicStaging/` and upload the IPA there.
- Command the install of that IPA over the same connection, like `ideviceinstaller` but fully on the phone.

Pairing needs a computer for its initial setup. This is also the method needed to update Quill itself, since the server method cannot install over the running app.

Quill is based on [Feather](https://github.com/claration/Feather).
