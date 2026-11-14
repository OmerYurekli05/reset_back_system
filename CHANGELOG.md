# Changelog

## 1.2.1 - 2026-11-14
- Eşleme kataloğuna eklendi: iCloud Outlook → iCloud (Store), Copilot → Microsoft Copilot (Store, varsayılan kapalı), VALORANT → RiotGames.Valorant.EU
- Gerçek bir geri yüklemenin 27 programlık "elle kur" listesiyle regresyon testi: 11'i winget/Store ile kuruluyor, 11'i sürücü/bileşen olarak eleniyor, 5'i (winget'te olmayanlar) elle kur listesinde kalıyor

## 1.2.0 - 2026-11-14
Başka bir bilgisayardaki gerçek kurulumda görülen 14 sorun düzeltildi:
- **Programlar artık tek tek kuruluyor** (`winget import` yerine `winget install`): her paketin çıkış kodu kontrol ediliyor, App Installer işlemi yarıda kesemiyor (App Installer hiç kurulmuyor), zaten kurulu olanlar atlanıyor, takılan kurulum 30 dk sonra kesiliyor
- "Zaten kurulu" ve "yeniden başlatma gerekli" kodları başarı sayılıyor; gerçek hatalar kod ve nedeniyle loglanıyor
- winget yoksa App Installer kaydı tetikleniyor; yine yoksa "elle kur" listesi yine de çıkarılıyor
- Store (msstore) kaynağı kapalıysa açılıyor; Store uygulamaları yedekten düşmüyor
- `catalog/winget-map.json`: export'un eşleyemediği programlar (Chrome, Discord, Steam, iCloud, Python, NVIDIA App…) ad → ID eşlemesiyle ekleniyor; eski yedeklere de uygulanıyor
- Geri yüklemede paket listesi yedekteki gerçek dosyalardan kuruluyor (elle düzenlenmiş `winget.json` ile manifest uyuşmazlığı yok)
- Windows ile gelen uygulamalar (Teams, Outlook, 365 Copilot, Edge, runtime'lar…) varsayılan olarak seçili gelmiyor
- "Elle kur" listesi: sürücü, SDK, servis, yazıcı ve sistem bileşenleri filtreleniyor; sürüm iki kez yazılmıyor; dosya her seferinde zaman damgalı (`missing-programs-<tarih>.txt`)
- Uyarılı sonuç: eksik ya da kurulamayan program varsa öğe "Tamam, ama uyarılar var" olarak raporlanıyor
- winget'in İngilizce lisans/indirme satırları gösterilmiyor; sadece "kuruluyor / kuruldu / zaten kurulu / KURULAMADI"
- Log ve yedek klasörü adlarında saniye var (aynı dakikadaki çalıştırmalar çakışmıyor)
- Yedek bulunursa program doğrudan geri yükleme modunda açılıyor, önce bilgisayarı taramıyor; mod değişince süren tarama iptal ediliyor

## 1.1.0 - 2026-11-14
- **Programları tek tek seçme:** winget listesindeki her program ayrı onay kutusu; arama kutusu, "görünenleri seç/kaldır"
  - Yedeklerken çıkarılan programlar yedeğe girmez, geri yüklerken çıkarılanlar kurulmaz
  - Çıkarılan programlar "elle kur" listesinde gösterilmez
- Program adları `winget list` çıktısından alınır (Store uygulamaları dahil okunur adlar, dilden bağımsız)
- Komut satırı: `-IncludePrograms` / `-ExcludePrograms` (joker karakter, id ya da ad)
- Profiller program seçimini de saklar (`programsExclude`)
- Düzeltme: paket listesi olmayan öğelerde boş program seçici görünmesi

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
