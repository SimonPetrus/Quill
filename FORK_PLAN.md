# FeatherSP — Fork Çalışma Planı ve Bulgular

> Bu dosya, `claration/Feather` fork'u (`SimonPetrus/FeatherSP`) üzerinde yapılacak işlerin
> tek kaynağıdır. Yerelde (VS Code / Claude Code vb.) çalışan asistana doğrudan verilmek üzere
> hazırlandı. Bulgular 10 Kasım 2026 tarihli upstream durumuna göredir.

---

## 0. Asistan için çalışma kuralları (değiştirme)

- Maddeleri **aşağıdaki sırayla, tek tek** yap. Her madde = **ayrı branch + tek commit**
  (`fix/<issue>-kisa-ad`, `feat/<issue>-kisa-ad`, issue yoksa `feat/c4-...` gibi).
- Her maddeye başlamadan önce: ilgili kodu oku, kök nedeni / yaklaşımı **3–5 cümleyle** anlat
  ve **onay bekle**. Onay gelmeden kod yazma.
- Her değişikliğin yanına 1–2 cümlelik **neden** yaz (commit mesajında da).
- Kullanıcı "bekle" yazarsa **anında dur**.
- Her maddeden sonra: CI derlemesinin geçtiğini doğrula, sonra kullanıcıya **cihazda neyi nasıl
  test edeceğini** kısaca yaz ve **sonucu bekle**. Onay gelmeden sıradaki maddeye geçme.
- Zaten var olan özelliği yeniden yazma; önce kodda var mı bak (bkz. §4 "Zaten var").
- **Lisans GPL-3.0:** `LICENSE`, README'deki ve Credits/About ekranındaki orijinal yazar
  atıflarına dokunma. Upstream PR'dan kod alınırsa commit mesajında yazarını belirt.
- Açık onay olmadan **release, tag, upstream'e PR yok**. İstenmedikçe zip/paketleme yapma.
- Yeni metinler `Feather/Resources/Localizable.xcstrings` üzerinden eklenmeli (en + tr en azından).
- Cihazda test edilemez; derleme dışında doğrulanamayan her şeyi açıkça "cihazda test et" diye belirt.

---

## 1. Mevcut durum (Aşama 1 tamam)

- Fork: `SimonPetrus/FeatherSP`. `upstream` → `https://github.com/claration/Feather.git`.
- Çalışma branch'i: `claude/feather-fork-setup-390bqg` = upstream `main` (`31ab6de`, v2.9.0)
  + yalnızca CI commit'leri. **Uygulama koduna henüz dokunulmadı.**
- Yeni maddeler için branch'leri bu branch'ten aç (CI workflow'u burada).

- Yayın akışı: `.github/workflows/release.yml` (workflow_dispatch). Sürüm: `gh workflow run release.yml -R SimonPetrus/Quill -f version=X -f dry_run=false` — YALNIZCA kullanıcı onayıyla. `dry_run=true` (varsayılan) tag/Release/`source` dalı oluşturmaz. Kaynak: `https://raw.githubusercontent.com/SimonPetrus/Quill/source/source.json`.

### Proje yapısı
- `Feather.xcodeproj` (tek app hedefi `Feather`, SwiftUI, iOS 16+, iPhone+iPad,
  `SUPPORTED_PLATFORMS = iphoneos iphonesimulator` — Catalyst hedeflenmiyor).
- Yerel paketler: `AltSourceKit` (kaynak formatı), `NimbleKit` (NimbleViews/JSON/Extensions).
- Submodule'ler: `Zsign` (khcrysalis/Zsign-Package — imzalama motoru, C++/OpenSSL),
  `IDeviceKitten` (khcrysalis/IDeviceKit → ürün `IDeviceSwift`, idevice/eşleştirme).
  Klonladıktan sonra: `git submodule update --init`.
- Uzak paketler (sabit sürüm): Vapor 4.104 (yerel kurulum sunucusu), Nuke 12.8, Zip 2.1.2,
  SWCompression 4.8, OpenSSL 3.3 (Zsign üzerinden), swift-nio/crypto.
- Kod: `Feather/Backend` (Core Data `Storage*`, `Server/ServerInstaller*`, `Observable/*Manager`),
  `Feather/Utilities/Handlers` (Signing, Zsign, Tweak, Archive, CertificateFile, AppFile),
  `Feather/Views/*`, çeviriler `Feather/Resources/Localizable.xcstrings` (tr: 280 metnin 271'i).

### Derleme
- Yerel (yalnızca macOS + Xcode 26.x): `git submodule update --init && make iphoneos`
  → `packages/Quill.ipa` (imzasız/ad-hoc; `CODE_SIGNING_ALLOWED=NO`).
  `make` ayrıca `maccatalyst` dener; proje Catalyst desteklemediği için **sadece `make iphoneos`** kullan.
- CI: `.github/workflows/build.yml` — her push/PR/manuel çalıştırmada macOS runner'da
  Xcode 26.3 ile `make iphoneos`.
  - Paketler ayrı ve 3 kez denenen bir adımda çözülüyor (ilk denemede xcodebuild
    `IDESwiftPackageCore` içinde `NSMutableArray insertObjects` istisnasıyla çökmüştü).
  - Manuel çalıştırmada `xcode` girdisiyle sürüm seçilebilir (örn. `26.6.0`).
  - **IPA alma:** hesabın Actions artifact kotası dolu olduğu için IPA ayrıca
    `ipa-builds` branch'ine tek commit olarak force-push ediliyor (`Quill.ipa` + `BUILD_INFO.txt`
    içinde commit ve sha256). Almak için:
    `git fetch origin ipa-builds && git show FETCH_HEAD:Quill.ipa > Quill.ipa`
    Kullanıcı IPA'sı `ipa-builds` (= quill dalı), ara derlemeler (diğer dallar) `ipa-builds-dev`.
  - Artifact yükleme `continue-on-error` — kota açılınca artifact olarak da gelir.
- Upstream'den kalan `release.yml` yeniden yazıldı (manuel `workflow_dispatch` yayın akışı, §1); `update_repo.yml` ve `app-repo.json` silindi.

---

## 2. Kritik bulgular

1. **"Fully Local" kurulum herkes için bozuk.** `backloop.dev` servisi kapandı; `https://backloop.dev/pack.json`
   hâlâ cevap veriyor ama içindeki `*.backloop.dev` sertifikası **29 Ekim 2026'da sona erdi**
   (`notAfter=Oct 29 10:20:49 2026 GMT`). Bu sertifika:
   - derlemede `Makefile` `deps` hedefiyle IPA'ya gömülüyor (`server.crt`, `server.pem`, `commonName.txt`),
   - uygulamada "Update SSL Certificates" ile aynı adresten indiriliyor
     (`Feather/Views/Settings/Installation/Server & SSL/ServerView.swift:56`).
   Yeni "Ready'de takılma" bildirimleri bundan: #686, #722, #730, #738, #743. Orijinal #476 kapatılmış
   ama sorun bu nedenle geri geldi. Çözüm → Madde 1.
2. **Bizim derleme 2.9.0 release'inden yeni.** `main`'de 2.9.0 sonrası birleşmiş düzeltmeler var:
   #697/Zsign-Package #4 (revoke kontrolünde çökme), #704 (custom entitlements'ta zsign hatasının yutulması),
   #717 (Zsign/OpenSSL güncellemesi), #721 (minimum iOS gösterimi), #723 (entitlement birleştirme), #654 (kaynaktan uygulama güncelleme kontrolü).
3. **Sertifika saklama (C5 raporu):**
   - `.p12` ve `.mobileprovision` düz dosya olarak `Documents/Feather/Certificates/<uuid>/` altına kopyalanıyor
     (`CertificateFileHandler.swift`).
   - `Info.plist`'te `UIFileSharingEnabled = true` → bu dosyalar Dosyalar uygulamasından / Finder'dan görülebilir.
   - P12 şifresi Core Data'da **düz metin** (`CertificatePair.password`, `Storage+Certificate.swift`).
4. **P12–profil uyumu kontrol edilmiyor (C4):** içe aktarmada yalnızca şifre kontrol ediliyor
   (`FR.checkPasswordForCertificate` → `p12_password_check`). Zsign `ZSignAsset::Init`
   (`Zsign/src/openssl.cpp` ~660) p12'deki sertifika özel anahtarla eşleşiyorsa profilin
   `DeveloperCertificates` listesinde olup olmadığına **bakmıyor** → imzalama "başarılı", iOS kurulumu reddediyor.
5. **#734 kök nedeni büyük ihtimalle bulundu:** `SigningHandler._modifyDict` içinde "File Sharing" seçeneği
   `UISupportsDocumentBrowser` yazıyor; Dosyalar uygulamasında görünmek için gereken
   `LSSupportsOpeningDocumentsInPlace` hiç yazılmıyor (`UIFileSharingEnabled` ayrı "iTunes File Sharing" seçeneğinde).

---

## 3. Yapılacaklar — sırayla

Her maddede: **Issue · Sorun · Bulgu/Yaklaşım · Dosyalar · Zorluk · Cihazsız doğrulama · Cihaz testi.**
Upstream issue linki: `https://github.com/claration/Feather/issues/<no>`.

### Faz 1 — Kritik

#### 1. Fully Local için kendi SSL sertifikası (localhost CA) — #686, #722, #738, #743, #576; PR #726
- **Sorun:** §2.1. Ayrıca #576: offline'da / DNS rebinding koruması olan DNS'lerde (AdGuard, Quad9, NextDNS) `backloop.dev` çözülemiyor.
- **Yaklaşım:** PR #726'yı (Nyasami, `refs/pull/726/head`, 7 commit, `main`'in 1 commit gerisinde) temel al ve tamamla:
  - Uygulama ilk açılışta kendi kök CA'sını (10 yıl) ve `feather.localhost` sunucu sertifikasını (1 yıl) üretir
    (`swift-certificates` / `X509` + `Crypto`, PR'daki `ServerInstaller+SSL.swift`, `RootMaterialModel.swift`).
  - PR'da **eksik:** "Install Local CA" düğmesi `// TODO: use the local server to open a path to the data url`
    olarak kalmış. Tamamla: yerel Vapor sunucusu üzerinden CA'yı `.mobileconfig` (veya `.cer`) olarak sun,
    Safari'de aç; kullanıcıya iki adımı göster: profili yükle (Ayarlar → Genel → VPN ve Aygıt Yönetimi) ve
    **Ayarlar → Genel → Hakkında → Sertifika Güven Ayarları**'nda tam güveni aç.
  - Sunucu sertifikası süresi dolmadan yeniden üretilsin (açılışta kontrol).
  - `Makefile` `deps` hedefi ve `backloop.dev` indirmesi kaldırılsın (PR bunu yapıyor) — CI artık süresi dolmuş sertifika gömmesin.
  - Eski `Documents/server.crt|pem` (backloop) dosyaları varsa yok say/sil; PR aynı dosya adlarını kullanıyor, karışmasın.
  - Commit mesajında PR #726 yazarını belirt.
- **Dosyalar:** `Feather/Backend/Server/ServerInstaller+TLS.swift`, yeni `ServerInstaller+SSL.swift`,
  `Models/RootMaterialModel.swift`, `ServerInstaller.swift` (CA sunma rotası), `ServerView.swift`, `FR.swift`,
  `Makefile`, `project.pbxproj` + her iki `Package.resolved` (yeni `swift-certificates` bağımlılığı), xcstrings.
- **Zorluk:** Orta. **Cihazsız:** derleme + sertifika üretim kodu. **Cihaz testi:** Ayarlar → Kurulum → Server / Fully Local →
  "Install Local CA" → profili yükle + güveni aç → bir IPA imzala/kur; Wi-Fi ve hücresel kapalıyken (uçak modu) tekrar dene.

### Faz 2 — Kullanıcının seçtiği sıra

#### 2. Kurulumdan sonra imzalı IPA'yı silme — #673
- **Bulgu:** "Delete After Signing" (`post_deleteAppAfterSigned`, `SigningView.swift` ~300) **zaten var** ama içe aktarılan
  (imzasız) uygulamayı siliyor. İstenen: kurulumdan sonra **imzalı** kopyanın silinmesi.
- **Yaklaşım:** yeni seçenek `post_deleteSignedAfterInstall`. idevice yönteminde kurulum tamamlanınca;
  sunucu yöntemlerinde "kurulum bitti" bilgisi gelmediği için IPA iOS'a gönderildikten sonra (`InstallerStatusViewModel` durumu) sil.
  Kurulum ekranı kapanmadan dosya silinmemeli.
- **Dosyalar:** `OptionsManager.swift`, `SigningOptionsView.swift`, `Views/Library/Install/InstallPreviewView.swift`,
  `InstallProgressView.swift`, `Backend/Observable/InstallerStatusViewModel.swift`, `Storage+Signed.swift`, xcstrings.
- **Zorluk:** Kolay–orta. **Cihazsız:** derleme. **Cihaz testi:** seçeneği aç, imzala+kur; kurulum bitince Kütüphane → İmzalı'da kaybolmalı, imzasız kalmalı; seçenek kapalıyken kalmalı.

#### 3. Kaynak sabitleme / favori — #664
- **Yaklaşım:** `AltSource` entity'sine `isPinned` (Bool, varsayılan false) — yeni model sürümü + hafif (lightweight) migration;
  `SourcesView` listesinde sabitlenenler üstte ayrı bölüm; hücrede bağlam menüsü / kaydırma ile sabitle/çöz.
- **Dosyalar:** `Backend/Storage/Feather.xcdatamodeld` (yeni sürüm), `Storage+Sources.swift`, `Views/Sources/SourcesView.swift`,
  `SourcesCellView.swift`, `SourcesViewModel.swift`, xcstrings.
- **Zorluk:** Kolay–orta. **Cihazsız:** derleme. **Cihaz testi:** mevcut kaynaklar güncellemeden sonra kaybolmamalı (migration); sabitle → üste çıkmalı, uygulama yeniden açılınca kalmalı.

#### 4. P12 – mobileprovision uyumluluk kontrolü — C4
- **Bulgu:** §2.4.
- **Yaklaşım:** içe aktarırken ve imzalamadan önce kontrol et: (a) p12 sertifikası profilin `DeveloperCertificates`'inde var mı
  (DER karşılaştırması veya SHA-1/SHA-256 parmak izi), (b) sertifika/profil süresi, (c) Team ID eşleşmesi.
  Eşleşmezse net Türkçe/İngilizce uyarı ("Bu sertifika bu profile ait değil"). Zsign'da `certcheck.cpp` ~210
  zaten `DeveloperCertificates` ayrıştırıyor — yeniden kullan ya da Swift tarafında `Security` (`SecPKCS12Import`) ile yap.
- **Dosyalar:** `Views/Settings/Certificates/CertificatesAddView.swift`, `Utilities/FR.swift`,
  `Utilities/CertificateReader/CertificateReader.swift`, `Views/Signing/SigningView.swift`, xcstrings.
- **Zorluk:** Kolay–orta. **Cihazsız:** büyük ölçüde (mantık; elde örnek p12/profil varsa). **Cihaz testi:** doğru çift → sorunsuz; farklı hesabın p12'si + profil → net uyarı, içe aktarma engellenmeli.

#### 5. Tüm uygulamaları toplu yeniden imzalama — #543
- **Bulgu:** Kütüphanede düzenleme modu + çoklu seçim (`_selectedAppUUIDs`, `LibraryView.swift`) zaten var.
- **Yaklaşım:** seçili (veya tümü) uygulamaları varsayılan sertifika + mevcut seçeneklerle sırayla imzalayan kuyruk; ilerleme ve hata özeti.
- **Dosyalar:** `Views/Library/LibraryView.swift`, `Utilities/Handlers/SigningHandler.swift`, xcstrings.
- **Zorluk:** Orta. **Cihazsız:** derleme. **Cihaz testi:** 3+ uygulama seç → toplu imzala → hepsi İmzalı'da, biri hata verirse diğerleri devam etmeli.

#### 6. Feather için uygulama içi güncelleme kontrolü — #646
- **Bulgu:** #654 yalnızca **kütüphanedeki uygulamaların** kaynaklardan güncellemesini kontrol ediyor; Feather'ın kendisini değil.
- **Karar (uygulandı):** kaynak = Quill'in kendi AltStore kaynağı (`source` dalındaki `source.json`, release.yml üretir); `app-repo.json` kaldırıldı. Kontrol yalnızca bilgi verip sayfayı açar, otomatik indirmez.
- **Dosyalar:** yeni küçük `Backend/Observable/SelfUpdateManager.swift`, `Views/Settings/SettingsView.swift` / `AboutView.swift`, xcstrings.
- **Zorluk:** Kolay–orta. **Cihazsız:** kısmen (sürüm karşılaştırma mantığı). **Cihaz testi:** Ayarlar'da "Güncellemeleri kontrol et" → doğru sürüm mesajı.

### Faz 3 — Kolay işler

#### 7. Uygulama bilgi ekranında kaynak adı — #495
- **Bulgu:** `Signed`/`Imported` entity'lerinde `source` (URI) ve `SourceMetadata`'da `sourceRepositoryName` zaten tutuluyor.
- **Dosyalar:** `Views/Library/Info/LibraryInfoView.swift`, `Storage+SourceMetadata.swift`. Ek olarak dosya boyutu da gösterilebilir (§4'teki eksik alan).
- **Zorluk:** Kolay. **Cihaz testi:** kaynaktan indirilen uygulama → Bilgi'de kaynak adı; elle içe aktarılan → alan gizli.

#### 8. "File share" açıkken dosyalar görünmüyor — #734
- **Bulgu:** §2.5. **Yaklaşım:** File Sharing seçeneği `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` yazsın
  (`UISupportsDocumentBrowser` ayrı bir anlam taşıyor, kaldırmadan önce etkisini değerlendir).
- **Dosyalar:** `Utilities/Handlers/SigningHandler.swift` (`_modifyDict`), gerekirse `SigningOptionsView.swift` açıklaması.
- **Zorluk:** Kolay. **Cihazsız:** imzalanmış `Info.plist` çıktısı. **Cihaz testi:** seçenekle imzala → Dosyalar → Bu iPhone'da uygulama klasörü görünmeli.

#### 9. ExtensionKit uzantı noktası bundle ID'si — #744
- **Bulgu:** `_modifyPluginIdentifiers` `CFBundleIdentifier`, `WKCompanionAppBundleIdentifier`, `WKAppBundleIdentifier`,
  `NSExtensionFileProviderDocumentGroup` değiştiriyor; ExtensionKit alanlarını değil.
- **Yaklaşım:** aynı eski→yeni değişimini şunlara da uygula: uzantının `Info.plist`'indeki `EXAppExtensionAttributes` →
  `EXExtensionPointIdentifier`, ve ana uygulamadaki `Extensions/*.appexpt` plist anahtarları. `.appex` yanında
  `Extensions/` altındaki ExtensionKit paketlerini de dolaş. (Referans: zhlynn/zsign PR #415.)
- **Dosyalar:** `Utilities/Handlers/SigningHandler.swift`.
- **Zorluk:** Kolay–orta. **Cihazsız:** plist dönüşümü. **Cihaz testi:** Empo (issue'daki örnek) veya ExtensionKit içeren uygulamayı yeni bundle ID ile imzala → uzantı çalışmalı.

#### 10. Profilden bundle ID'yi otomatik doldurma — #636
- **Yaklaşım:** seçili profilin `application-identifier`'ı joker (`TEAMID.*`) değilse imzalama ekranında bundle ID'yi
  ondan öner/doldur. Ayrıca issue'daki ek istek: tanımlı identifier eşlemesi silinmeden düzenlenebilsin.
- **Dosyalar:** `Views/Signing/SigningView.swift`, `SigningPropertiesView.swift`, `CertificateReader.swift`,
  `Views/Settings/Signing Options/Dictionaries/ConfigurationDict*View.swift`.
- **Zorluk:** Kolay. **Cihaz testi:** joker olmayan ad-hoc profil → ID otomatik gelmeli; joker profil → değişmemeli.

#### 11. Watch bileşenini kaldırma anahtarı — #489
- **Bulgu:** `_removeWatchIfNeeded` yalnızca `Info.plist`'i olmayan Watch yer tutucularını siliyor; gerçek Watch uygulaması kalıyor.
- **Yaklaşım:** "Watch uygulamasını kaldır" seçeneği (varsayılan kapalı) → `Watch/` klasörünü tamamen sil.
- **Dosyalar:** `SigningHandler.swift`, `OptionsManager.swift`, `SigningOptionsView.swift`, xcstrings.
- **Zorluk:** Kolay. **Cihazsız:** çıktı paketi incelenebilir.

#### 12. İmzalamadan önce dylib'leri dışa çıkarma — #498
- **Yaklaşım:** Dylib listesinde (ve Framework'lerde) "Dışa aktar" → share sheet / Dosyalar.
- **Dosyalar:** `Views/Signing/Shared/SigningDylibView.swift`, `SigningFrameworksView.swift`.
- **Zorluk:** Kolay–orta. **Cihaz testi:** bir dylib'i dışa aktar → Dosyalar'da açılabilmeli.

#### 13. Uzantıları toplu seçip kaldırma — #294
- **Dosyalar:** `Views/Signing/Shared/SigningFrameworksView.swift` (çoklu seçim → `removeFiles`).
- **Zorluk:** Kolay–orta.

### Faz 4 — Orta işler

#### 14. Sertifika ve şifrelerin güvenli saklanması — C5
- **Bulgu:** §2.3. **Yaklaşım (önce kullanıcıya onaylat):** şifre → Keychain
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, anahtar = sertifika uuid); `.p12`/profil → paylaşılmayan
  `Application Support/Feather/Certificates/<uuid>/`, `FileProtectionType.complete`. Açılışta tek seferlik migration
  (eski konumdan taşı, Core Data'daki şifreyi temizle). Dışa aktarma (`FR.exportCertificateAndOpenUrl`) yeni konumla çalışmaya devam etmeli.
- **Dosyalar:** `Storage+Certificate.swift`, `CertificateFileHandler.swift`, `Extensions/FileManager+documents.swift`,
  `Utilities/FR.swift`, `Storage.swift` (migration), yeni `KeychainHelper.swift`.
- **Zorluk:** Orta. **Cihazsız:** derleme. **Cihaz testi:** güncellemeden önce sertifikalı kurulum → güncelle → sertifikalar duruyor,
  imzalama çalışıyor, Dosyalar'da `Certificates` klasörü görünmüyor.

#### 15. Bozuk imzalama ayarları — #504
- **Bulgu:** `OptionsManager` seçenekleri JSON olarak saklayıp varsayılanlarla birleştiriyor (`OptionsManager.swift` ~17–40);
  repo sahibinin önerisi UserDefaults'a ayrı anahtarlarla geçmek.
- **Yaklaşım:** decode başarısızlığında sessizce bozuk değerle devam etmek yerine bozuk anahtarı atıp varsayılanı kullan,
  logla; tek tek anahtar okuma. Mevcut kullanıcı ayarlarını koruyan migration.
- **Dosyalar:** `Backend/Observable/OptionsManager.swift`, `Views/Settings/Reset/ResetView.swift`.
- **Zorluk:** Orta. **Cihazsız:** kısmen (decode mantığı).

#### 16. Sertifika bitiş bildirimi — C1
- **Bulgu:** kodda hiç `UNUserNotificationCenter` yok; bitiş tarihi `CertificatePair.expiration`'da.
- **Yaklaşım:** her sertifika için bitişten 7 ve 1 gün önce yerel bildirim (sertifika eklenince/silinince yeniden planla),
  izin isteme, Ayarlar'da aç/kapat. İptal (revoke) için arka plan kontrolü (`BGAppRefreshTask`) iOS'ta güvenilmez —
  yalnızca uygulama açılışında kontrol edip bildirim göster.
- **Dosyalar:** yeni `Backend/Observable/NotificationManager.swift`, `Storage+Certificate.swift`, `CertificatesView.swift`,
  `FeatherApp.swift`, `Info.plist` (gerekirse), xcstrings.
- **Zorluk:** Kolay (bitiş) / Zor (arka plan iptal). **Cihaz testi:** cihaz tarihini ileri alarak veya kısa süreli test planlamasıyla.

#### 17. Anlaşılır hata mesajları + log dışa aktarma + Türkçe açıklamalar — C3 + C6
- **Bulgu:** hatalar çoğunlukla ham `error.localizedDescription` ile gösteriliyor (ör. `SigningView.swift` ~289).
  Loglama `Extensions/Logger++.swift` (os `Logger`).
- **Yaklaşım:** sık hatalar (zsign "Can't find paired certificate", parola, provisioning uyumsuzluğu, `0xe8008001`
  ApplicationVerificationFailed, `-7001` RSD, ağ/SSL) için kod → açıklama + çözüm önerisi tablosu, metinler xcstrings'te (tr dahil);
  Ayarlar'da "Logları dışa aktar" (`OSLogStore(scope: .currentProcessIdentifier)` → .txt → share sheet).
- **Dosyalar:** yeni `Utilities/ErrorExplainer.swift`, `Logger++.swift`, `SettingsView.swift`, hata gösteren view'lar, xcstrings.
- **Zorluk:** Orta.

#### 18. Ayar ve sertifika yedekleme / geri yükleme — C2 (14'ten sonra)
- **Bulgu:** yalnızca kaynak listesi dışa aktarılabiliyor (`SourcesAddView.swift` ~80).
- **Yaklaşım:** ayarlar + kaynaklar + sertifikalar (p12, profil, şifre) tek arşiv; sertifika içeren yedek kullanıcı parolasıyla şifrelensin
  (CryptoKit AES-GCM + PBKDF/HKDF). Geri yüklemede çakışan uuid'leri atla.
- **Dosyalar:** yeni `Utilities/Handlers/BackupHandler.swift`, `SettingsView.swift`, `Storage*.swift`, xcstrings.
- **Zorluk:** Orta.

#### 19. Kaynaktan sürüm seçerek güncelleme — #655
- **Bulgu:** güncelleme tespiti **var** (`UpdateManager.swift`, #654); kaynak uygulama detayında sürüm geçmişi
  (`Views/Sources/Apps/Detail/VersionHistoryView.swift`) var. Eksik: kütüphanedeki uygulamadan sürüm seçip indirme.
- **Dosyalar:** `UpdateManager.swift`, `Views/Library/LibraryCellView.swift`, `VersionHistoryView.swift`, `DownloadManager.swift`.
- **Zorluk:** Orta.

#### 20. Uygulamaya özel keychain grubu — #575
- **Yaklaşım:** seçenek: `keychain-access-groups`'u `TEAMID.<yeni-bundle-id>` olarak yaz. Yalnızca joker profillerde mümkün —
  joker değilse seçeneği devre dışı bırak ve açıkla.
- **Dosyalar:** `SigningHandler.swift` (`_mergeEntitlements` civarı), `OptionsManager.swift`, `SigningOptionsView.swift`.
- **Zorluk:** Orta. **Cihaz testi:** iki uygulama aynı profille → biri diğerinin keychain girdisini görmemeli.

#### 21. Dylib'lerin Watch uygulamasına ve PlugIns'e enjekte edilmesi — #672
- **Bulgu:** enjeksiyon yalnızca ana `.app` Mach-O'suna (`_inject`); `injectIntoExtensions` seçeneği var — kapsamını incele.
- **Dosyalar:** `SigningHandler.swift` (`_inject`), `TweakHandler.swift`, `OptionsManager.swift`.
- **Zorluk:** Orta. **Cihaz:** gerekli.

#### 22. Tweak hataları (AMFI "has entitlements but is not a main binary") — #616
- **Bulgu:** enjekte edilen dylib/framework'ler (CydiaSubstrate, Tweak1.dylib) entitlement'larla imzalanıyor; iOS bunu
  ana olmayan binary'de reddediyor.
- **Yaklaşım:** Zsign çağrısında yalnızca ana executable ve appex executable'larına entitlement ver; dylib/framework'leri entitlement'sız imzala.
- **Dosyalar:** `Utilities/Handlers/ZsignHandler.swift`, `Zsign/swift/*`, gerekirse Zsign C++ (`bundle.cpp`).
- **Zorluk:** Orta. **Cihaz:** gerekli (Frida Gadget ile issue'daki senaryo).
- **Durum: uygulandı (build/vendor-zsign).** Zsign vendor edildi (`Zsign/VENDORED.md`); `Zsign/src/archo.cpp` artık dylib/framework'lere entitlement slotu yazmıyor (yalnız MH_EXECUTE). Cihazda doğrulama bekliyor.

#### 23. Büyük IPA içe aktarma / kurulum sonrası hata — #661, #659
- **Bulgu:** 2.7 GB IPA'da içe aktarma başarısız, ilerleme çubuğu yok (#661); #659 yalnızca ekran görüntüsü (iOS 26.5).
- **Yaklaşım:** `ArchiveHandler`/`AppFileHandler`'da bellek kullanımı (tüm dosyayı belleğe alma), disk alanı kontrolü,
  ilerleme ve anlaşılır hata. #659 için önce ekran görüntüsündeki hatayı oku.
- **Dosyalar:** `Utilities/Handlers/ArchiveHandler.swift`, `AppFileHandler.swift`, `Views/Download/*`.
- **Zorluk:** Orta–zor. **Cihaz:** gerekli (büyük IPA).

### Faz 5 — Cihaz ağırlıklı / zor

#### 24. iOS 27.2'de Semi Local kurulum — #745
- **Bulgu:** Semi Local, manifest için harici `https://api.palera.in/genPlist` kullanıyor ve IPA'yı **http** ile sunuyor
  (`ServerInstaller+Compute.swift`). iOS 27.2 http payload'u veya palera.in'i reddediyor olabilir. Madde 1 bitince
  Semi Local yerine Fully Local önerilebilir.
- **Zorluk:** Zor (neden belirsiz). **Cihaz:** gerekli — önce kullanıcıdan iOS 27.2 cihazda log al.

#### 25. idevice ile büyük uygulama kurulumunda çökme — #586, #665
- **Dosyalar:** `IDeviceKitten` (submodule), kurulum ekranları. **Zorluk:** Zor. **Cihaz:** gerekli (3.5 GB IPA). Önce crash log.

#### 26. "Cannot find RSD adapter (-7001)" — #733
- **Dosyalar:** `IDeviceKitten`, `Views/Settings/Installation/Tunnel & Pairing/TunnelView.swift`. **Zorluk:** Zor. **Cihaz:** gerekli.

#### 27. idevice ile kurmadan önce eski uygulamayı zorla silme — #393
- **Dosyalar:** `IDeviceKitten` (installation_proxy uninstall), kurulum seçenekleri. **Zorluk:** Orta. **Cihaz:** gerekli.

#### 28. Feather'ı share sheet hedefi yapma — #581
- **Bulgu:** `Info.plist`'te `CFBundleDocumentTypes` zaten var ("Birlikte aç" listesi); share sheet için **Share Extension**
  hedefi gerekir (yeni target, App Group). Ücretsiz Apple ID'lerde ek uzantı imzalama/App Group sorunlu — kullanıcıya etkisini anlat.
- **Dosyalar:** yeni extension target, `project.pbxproj`, `Makefile`/CI. **Zorluk:** Zor.

#### 29. Gerçek uzantı imzalama (uzantı başına profil) — #676
- **Bulgu:** `SigningHandler.swift` ~503: "this will not consider app extensions, zsign doesnt have functionality be more specific".
- **Dosyalar:** Zsign, sertifika/imzalama ekranları. **Zorluk:** Zor.

### Faz 6 — Başlamadan önce kullanıcıya sor (kapsam dışı önerisi)

| # | Issue | Neden ertelenmeli |
|---|---|---|
| 30 | #635 Catalyst'te sertifika eklenemiyor | Proje Catalyst'i hedeflemiyor (`SUPPORTED_PLATFORMS`), Mac gerekli |
| 31 | #690 visionOS'ta Kütüphane/Ayarlar çökmesi | Vision Pro gerekli, log yok |
| 32 | #562 Apple TV desteği | En büyük iş; tvOS hedefi + kurulum yolu yok |
| 33 | #183 Uygulama verisini dışa/içe aktarma | Jailbreak'siz cihazda başka uygulamanın konteynerine erişilemez |
| 34 | C7 SHA-256 bütünlük doğrulaması | `AltSourceKit` modelinde hash alanı yok, kaynakların çoğu sağlamıyor; önce kullanılan kaynaklarda alan var mı bak |
| 35 | #590 Revoke kontrolünde çökme | Kodda düzeltilmiş görünüyor (Zsign-Package #4, `main`'de); yalnızca cihazda doğrula, gerekirse yeniden aç |

---

## 4. Zaten var — yeniden geliştirme

- **Sertifika revoke kontrolü:** var (`Storage+Certificate.swift` `revokagedCertificate` → `Zsign.checkRevokage`); çökme düzeltmesi `main`'de, 2.9.0 release'inde yok.
- **Birden fazla sertifika + geçiş:** var (`isDefault`, `CertificatesView`).
- **Uygulama detay ekranı** (`LibraryInfoView.swift`): Ad, Sürüm, Bundle ID, Eklenme tarihi, Minimum OS (#721),
  Sertifika, Alternatif ikonlar, Frameworks & PlugIns, Dylibs, Entitlements var. **Eksik:** kaynak adı (Madde 7), dosya boyutu.
- **Arka plan indirme:** var (`DownloadManager.swift`); hata sonrası `resumeData` ile devam ediyor.
  **Eksik:** elle duraklat/devam düğmesi, indirme kuyruğu (şu an paralel).
- **Kütüphanede toplu seçme/silme:** var (düzenleme modu). **"İmzala ve kur":** var (`post_installAppAfterSigned`).
- **"İmzaladıktan sonra sil":** var ama imzasız olanı siliyor (bkz. Madde 2).
- **Kaynaktan uygulama güncelleme tespiti:** var (#654, `UpdateManager.swift`).
- **Kaynak listesini dışa aktarma:** var (`SourcesAddView.swift`).

## 5. Kapsam dışı (yapma)

- IPA içinde şüpheli URL / zararlı imza taraması.
- Entitlements'ı "şüpheli" diye etiketleme (göstermek serbest).
- İki IPA sürümünü karşılaştırma.
- Ayrı imzalama geçmişi ekranı.

## 6. Upstream PR değerlendirmesi

- **#726 — localhost için self-signed sertifika (Nyasami):** doğru yön, en kritik iş; ama CA yükleme akışı `TODO`.
  Madde 1'de temel alınacak. Almak için: `git fetch upstream pull/726/head:pr-726`.
- **#640 — UIKit refactor (claration, taslak):** son commit 25 Mayıs 2026, `main`'in 30 commit gerisinde, yalnızca sekme çubuğu
  ve Ayarlar'ı UIKit'e çevirmiş; `SettingsView`, `AppearanceView`, `ResetView`, `AppIconView`, `TabView/*` silinmiş,
  `FeatherApp.swift` → `AppDelegate`/`SceneDelegate`, `Info.plist` değişmiş. Sahibi "bitirmeyebilirim" diyor.
  Ayarlar'a dokunan maddelerle (6, 14, 16, 17, 18) doğrudan çakışır; Kütüphane/İmzalama/Kaynaklar'a dokunmuyor.
  **Karar: `main` üzerinden devam.** Birleşirse Ayarlar UI değişikliklerini UIKit'e taşımak gerekir.
- **#742 — öneri listesine kaynak ekleme:** ilgisiz.

## 7. Upstream'i takip etme

```sh
git fetch upstream main
git log --oneline HEAD..upstream/main   # yeni upstream commit'leri
```
Upstream'de önemli düzeltme gelirse kullanıcıya sor; kendiliğinden merge/rebase yapma.
