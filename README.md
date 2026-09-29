# VueVPN

Client OpenVPN pribadi untuk macOS Apple Silicon: **Swift/AppKit → Objective-C++ → embedded OpenVPN 3 Core**. Tidak membutuhkan instalasi OpenVPN CLI.

Implementasi memakai window 960 × 720, profil `.ovpn`, PIN/password dengan opsi Keychain, menu bar native, beberapa koneksi bersamaan, routing IPv4 per profil, dan DNS dari server VPN.

## Menjalankan hasil build

1. Salin `artifacts/VueVPN.app` ke `/Applications`.
2. Buka aplikasi sendiri. Pilih **App settings → Enable VPN helper**.
3. Jika diminta, izinkan VueVPN di **System Settings → General → Login Items & Extensions**, kemudian tekan **Refresh status**.
4. Import profil development `.ovpn`. Pilih profil, periksa subnet, lalu **Connect to VPN**.
5. Masukkan PIN/password. Centang **Remember on this Mac** jika ingin menyimpannya setelah koneksi sukses.

Build lokal ini menargetkan **macOS 26.0+ arm64**, sesuai dependency native yang tersedia di Mac pembuat. Framework helper menggunakan API macOS 13+, tetapi binary OpenSSL lokal memerlukan macOS 26. Build untuk macOS lebih lama membutuhkan dependency native yang dibangun ulang dengan deployment target tersebut.

Menutup window menyembunyikannya. Aplikasi dan VPN tetap berjalan melalui menu bar. **Quit VueVPN** membersihkan koneksi terlebih dahulu. Tidak ada autoconnect saat aplikasi dibuka.

## Tema dan interaksi

Pilih **App settings → Appearance → Light / Dark / System**. Default **System**
mengikuti appearance macOS secara langsung; Light/Dark mempertahankan pilihan
meskipun tema macOS berubah. Pilihan tersimpan di preferences aplikasi, berlaku
untuk seluruh profil, dan tidak memerlukan restart atau reconnect VPN.

Dark memakai palet hijau gelap. Input, dialog, diagram, statistik, dan toast
mengikuti tema; menu bar/menu native mengikuti macOS. Kontrol yang dapat diklik
menampilkan cursor tangan, kontrol disabled memakai panah, dan input memakai
I-beam. Menu serta tombol window bawaan tetap memakai perilaku macOS.

Animasi koneksi memakai layer Core Animation, tanpa timer yang menggambar ulang
Overview setiap frame. Angka traffic/durasi diperbarui terpisah sekitar sekali
per detik. Rendering workspace dijeda ketika window tersembunyi, diminimalkan,
sepenuhnya tertutup, atau tertutup dialog; menu bar dan koneksi tetap aktif.
Animasi juga dijeda ketika ilustrasinya keluar dari area scroll. Low Power Mode
mempertahankan animasi normal; pengaturan Reduce Motion tetap dihormati.

## Memperbarui aplikasi

Quit VueVPN lama, ganti `/Applications/VueVPN.app` dengan build `artifacts/VueVPN.app` terbaru, lalu buka kembali. **Tidak perlu disable-enable helper untuk pembaruan rutin**, termasuk saat berpindah dari versi lama yang belum memiliki deteksi versi.

Aplikasi membandingkan fingerprint executable helper yang ditandatangani di bundle dengan fingerprint proses helper melalui XPC. Bila berbeda, aplikasi menunggu semua koneksi VPN terputus, melakukan unregister, menunggu callback macOS memastikan proses lama berhenti, lalu register ulang. Koneksi baru dibuka kembali setelah fingerprint helper baru terverifikasi. Perubahan UI dengan executable helper yang sama tidak memicu restart helper.

Jika ada VPN aktif, status **update pending** ditampilkan; koneksi tetap berjalan sampai pengguna disconnect. **Disconnect all and update** tersedia di App settings. Profil dan PIN yang tersimpan di Keychain tidak diubah. Bila macOS meminta persetujuan, izinkan di System Settings. Helper yang sengaja dinonaktifkan tidak diaktifkan otomatis. Saat pembaruan berlangsung, tunggu sampai selesai sebelum Quit.

Status **not found** dengan bundle lengkap ditangani sebagai registrasi yang perlu dipulihkan: aplikasi memeriksa executable signed dan plist, lalu mencoba registrasi otomatis. Setelah helper lama berhenti, registrasi dilanjutkan memakai instance SMAppService baru. Kegagalan registrasi sementara dicoba maksimal tiga kali dengan jeda; fase ini tetap tampil **updating** sampai fingerprint helper terverifikasi. Helper yang berstatus not registered karena sengaja dinonaktifkan tetap membutuhkan Enable, kecuali registrasinya hilang di tengah pembaruan atau pengguna memilih Retry.

Disconnect memakai sinyal asinkron ke engine, termasuk saat sleep atau jaringan berubah. Core menghentikan loop event setelah shutdown agar pekerjaan tertunda tidak menahan `connect()` selamanya; transport ditutup sebelum bypass route dilepas. Jika status Disconnecting tidak selesai selama 30 detik, aplikasi menampilkan **Disconnect stalled** dan **Retry disconnect**. Timeout tidak dianggap berhasil: kepemilikan sesi/route tetap dipertahankan, koneksi pengganti ditolak, dan update helper menunggu cleanup. Retry tidak merestart helper atau memutus profil lain.

Kegagalan permanen ditampilkan dengan **Retry helper update**, yang melanjutkan registrasi tanpa perlu klik Enable lagi. Tidak ada loop unregister/register tanpa batas. Helper yang tidak dapat dihubungi tidak langsung dihentikan karena aplikasi belum dapat memastikan keadaan koneksinya. Deteksi bundle hanya berlaku pada `.app` lengkap yang signed; hasil compile unsigned belum merupakan bundle siap pakai dan tidak boleh digunakan untuk pengujian VPN.

## Profil dan routing

- Profil Pritunl dengan `password_mode: pin` menggunakan PIN dan username dari metadata profil. Username dapat disesuaikan di **Edit profile**. Profil username/password standar juga didukung.
- Profil `route-nopull` dengan route eksplisit diawali dalam mode **Selected networks**. Profil lain diawali dalam mode **All IPv4 traffic**.
- Editor menerima prefix (`24`, `/24`) atau subnet mask (`255.255.255.0`). Alamat dinormalisasi menjadi network address.
- Hanya satu full IPv4 tunnel aktif. Profil split lainnya boleh aktif jika subnet dan domain DNS tidak bertumpang tindih.
- Backend mendukung DNS IPv4 dan domain suffix tersimpan; nilai kosong memakai pengaturan server. Pada Selected networks, DNS otomatis tanpa domain suffix diabaikan sehingga koneksi tetap memakai DNS sistem, tanpa route tambahan ke resolver VPN. Hostname internal memerlukan suffix tersimpan atau suffix dari server; DNS manual tanpa suffix tetap ditolak. IP resolver yang digunakan juga diroute ke VPN. Bagian Internal DNS sementara disembunyikan dari Overview dan Profile settings. Pengaturan yang sudah tersimpan tetap dipertahankan ketika profil diedit; penanganan DNS server di backend tetap berjalan. All IPv4 tetap memakai DNS server tanpa mewajibkan suffix.
- Route push dari server tidak menentukan mode routing: pengaturan pada VueVPN yang berlaku.
- Menyimpan perubahan network pada profil aktif hanya me-reconnect profil tersebut.
- IPv6 tidak diubah atau diblokir. Full tunnel berarti seluruh **IPv4**, dengan pengecualian transport VPN, alamat interface lokal/peer, dan route jaringan lokal yang lebih spesifik milik macOS. Tidak ada kill switch.
- Reconnect dibatasi lima percobaan berturut-turut dengan backoff 2/4/8/16/30 detik; offline/sleep menunda percobaan. Kesalahan autentikasi, sertifikat, atau konfigurasi menghentikan retry.
- Profil dengan framing kompresi lama (termasuk `comp-lzo no`) memakai mode kompatibilitas receive-only. VueVPN tidak mengompresi data keluar, tetapi dapat menerima data terkompresi dari server tersebut. Profil tanpa direktif kompresi tetap menggunakan mode `no`; `allow-compression no` selalu dihormati.

## Data lokal

Profil disimpan di `~/Library/Application Support/com.vuevpn.desktop/profiles`, direktori `0700`, file `0600`. Sertifikat/key yang direferensikan file diimpor menjadi inline; file sumber tidak diubah. Metadata sinkronisasi Pritunl tidak disimpan. Password tidak ditulis ke JSON, log, atau localStorage.

Password yang diingat menggunakan macOS Keychain dengan service `com.vuevpn.desktop.credentials`. **Forget password** menghapusnya. Password yang ditolak server dihapus agar koneksi berikutnya meminta input ulang. Tanpa remember, credential hanya dipertahankan dalam memori untuk reconnect sesi tersebut.

Helper berjalan terpisah dengan hak administrator. Komunikasi XPC memerlukan signing identifier dan Team ID yang cocok pada kedua arah, serta user console aktif. UI tidak berjalan sebagai root. Helper tidak menerima command shell atau path file dari UI; profil dibatasi pada konfigurasi inline yang didukung.

## Development dan build

Prasyarat: Apple Silicon, macOS 26+, Xcode 26 dengan Swift 6, Python 3,
CMake, Asio, OpenSSL 3, dan LZ4. Build script mencari dependency Homebrew di
`/opt/homebrew`. Node.js, npm, Rust, Tauri, WebView, dan OpenVPN CLI tidak diperlukan.

Siapkan dependency jika belum tersedia:

```sh
rtk proxy brew install cmake asio openssl@3 lz4
rtk proxy python3 scripts/native.py prepare
```

OpenVPN Core dipin ke commit dalam `scripts/native.py`; patch endpoint IPv4
tetap diterapkan oleh script. File vendor tidak dicommit.

Build Release beserta helper dan seluruh library, tanpa membuka aplikasi:

```sh
rtk proxy python3 scripts/package.py
```

Jika hanya ada satu identity Apple Development/Developer ID Application, script
memilihnya otomatis. Jika ada beberapa, set `VUEVPN_SIGNING_IDENTITY` ke SHA-1
identity yang diinginkan. Gunakan identity/Team yang sama dengan build sebelumnya.
Signing lokal tidak melakukan notarization atau publikasi. Script memverifikasi
signature app/helper dan dependency sebelum mengganti hasil build sebelumnya.

Hasil siap diuji manual: **`artifacts/VueVPN.app`**. Quit aplikasi lama, salin
hasil ini ke `/Applications`, kemudian buka sendiri. Build tidak mendaftarkan
atau menjalankan helper.

Untuk development dengan simbol debug dan helper lengkap:

```sh
rtk proxy python3 scripts/package.py --configuration Debug
```

Alur menjalankannya sama: salin hasil package ke `/Applications` dan buka
secara manual. Tidak ada server frontend atau hot reload. Project dapat diedit
di `macos/VueVPN.xcodeproj`. Compile cepat tanpa packaging/signing:

```sh
rtk proxy python3 scripts/build.py
```

Hasil compile di `macos/build/Build/Products/Debug/VueVPN.app` belum berisi
helper lengkap; gunakan hasil package untuk mencoba koneksi. Setelah menambah
atau menghapus file Swift, jalankan `python3 scripts/sync_sources.py`.

## Pengujian tanpa membuka aplikasi

```sh
rtk proxy python3 scripts/test_core.py
rtk proxy python3 scripts/test_ui.py all
rtk proxy python3 scripts/native.py test
```

Core memakai fake XPC/Keychain, clock sintetis, dan storage sementara. UI memakai
AppKit/CoreGraphics offscreen tanpa NSWindow atau event loop aplikasi. Empat suite
native menguji policy, parser OpenVPN, lifecycle, dan kepemilikan network dengan
dependency palsu. Test tidak menjalankan helper root, mengubah route/DNS/Keychain,
atau membuat koneksi VPN.

Perbandingan gambar native menggunakan referensi beku dari UI lama, dengan
target minimal **95%** pixel sesuai setelah toleransi warna **2/255 per channel**
untuk dithering. Nilai selisih pixel exact juga dilaporkan. Hasil, cakupan, serta
batas pemeriksaan ada di `docs/NATIVE_MIGRATION.md`; referensi bukan resource app.

Window nyata, interaksi mouse/keyboard, approval macOS, Keychain, autentikasi,
trafik VPN, sleep/wake, dan pergantian Wi-Fi perlu diuji pengguna melalui
`docs/MANUAL_TEST.md`. Hasil unit test tidak membuktikan koneksi live.

## Batas dukungan

TUN IPv4 dengan sertifikat/key inline dan PIN/password. TAP, external PKI, encrypted private key, OTP/dynamic challenge, SSO, device authentication, dynamic firewall Pritunl, script/plugin, proxy, dan konfigurasi eksternal berantai belum didukung. Error spesifik ditampilkan saat import atau validasi native sebelum koneksi.

## Menghapus aplikasi

Pilih **App settings → Disable helper and disconnect all**, lalu Quit. Setelah itu hapus `/Applications/VueVPN.app`. Hapus profil melalui UI terlebih dahulu jika ingin sekaligus menghapus credential Keychain; file `.ovpn` sumber tetap ada. Route journal helper berada di `/var/run/com.vuevpn.helper/routes.json` dan hanya berisi kepemilikan route, tanpa credential.

Jika cleanup route gagal, aplikasi menampilkan error dan tidak mengklaim cleanup selesai. Jangan hapus route secara massal. Restart macOS sebelum mencoba koneksi lagi.
