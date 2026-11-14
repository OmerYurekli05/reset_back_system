# Changelog

## 1.0.2 - 2026-11-14
- Release artık `ResetBack.exe` içeriyor (ps2exe ile derlendi, yönetici olarak açılır, konsol penceresi yok)
- .exe gerçek ortamda doğrulandı: pencere açılıyor, arka plan taraması tamamlanıyor

## 1.0.1 - 2026-11-14
- Komut satırında tek öğe seçilince "Seçili öğe yok" hatası düzeltildi (PS 5.1 tekil nesne .Count sorunu)
- Wi-Fi geri yüklemede sadece mevcut kullanıcıya eklenebilen profiller için yedek yöntem; hata nedeni loga yazılıyor (49/49)
- Yönetici modülleri gerçek ortamda doğrulandı: 184 sürücü paketi, 49 Wi-Fi ağı, güç planı, BitLocker, registry, MSI Afterburner

## 1.0.0 - 2026-11-14
- Tek dosyalık derleme (`build/build.ps1`): kod, dil dosyaları, kataloglar ve arayüz tek `ResetBack.ps1` içinde; release zip'i
- README kullanım kılavuzu (TR/EN), ekran görüntüleri, katalog rehberi (`docs/CATALOG.md`)
- GUI duman testi derlenmiş tek dosyayla da çalışır (`-SingleFile`)

## 0.3.0
- Hazır seçim profilleri (`profiles/`), joker karakter desteği, `-SaveProfilePath`
- Katalog: 12 yeni uygulama (tarayıcılar, VLC, qBittorrent, ShareX, Rainmeter, FileZilla, WinSCP, geliştirici ayarları, Blender…)
- `system.registry` başvuru yedeği, yedeklemede açık program uyarısı, açılış kayıtları

## 0.2.0
- WPF arayüz: kategori listesi, rozetler, arka planda çalışma, ilerleme ve log, TR/EN geçişi
- Açık program, hassas veri ve sistem diski uyarıları, deneme modu, üzerine yazma seçeneği

## 0.1.0
- Çekirdek motor, `manifest.json` yedek formatı
- Programlar (winget), editörler, sistem (sürücü, Wi-Fi, güç, BitLocker, hosts, ortam değişkenleri), kişisel klasörler, uygulama kataloğu
- Komut satırı ve test paketi
