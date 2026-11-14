# reset_back_system

> 🇹🇷 Türkçe aşağıda · 🇬🇧 English below

---

## 🇹🇷 Türkçe

**reset_back_system**, Windows'u formatlamadan önce neyin yedekleneceğini **onay kutularıyla seçmeni** sağlayan, format sonrası da hepsini doğru sırayla geri yükleyen bir araçtır.

> ⚠️ Proje geliştirme aşamasında. Henüz kullanıma hazır değil.

### Ne yedekler?
| Kategori | İçerik |
|---|---|
| **Programlar** | Kurulu programlar (winget) → format sonrası toplu kurulum. winget'te olmayanlar için "elle kur" listesi |
| **Editör eklentileri** | VS Code, Cursor, Antigravity, Windsurf eklentileri ve ayarları |
| **Sistem** | Wi-Fi profilleri, sürücüler, güç planı, BitLocker kurtarma anahtarı, hosts, ortam değişkenleri |
| **Kullanıcı verisi** | Masaüstü, Belgeler, `.ssh`, `.gitconfig`, oyun kayıtları ve bilinen uygulamaların ayarları |

### Nasıl çalışır?
1. **Yedekle (format öncesi):** Program bilgisayarı tarar, bulduklarını listeler. Sen seçersin, seçtiklerin bir hedef klasöre (USB, D: vb.) yedeklenir.
2. **Geri Yükle (format sonrası):** Yedek klasörü okunur, sadece yedekte olanlar gösterilir. Sen seçersin, program doğru sırayla geri yükler:
   sürücüler → Wi-Fi → programlar → eklentiler → ayarlar → kullanıcı dosyaları.

### Özellikler (planlanan)
- Türkçe / İngilizce arayüz
- Deneme modu (dry-run): hiçbir şeye dokunmadan ne yapılacağını gösterir
- Hassas veriler (Wi-Fi şifreleri, BitLocker anahtarları) için uyarı
- Geri yüklemeden önce ilgili uygulama açıksa kapatma uyarısı
- Topluluk tarafından genişletilebilen uygulama kataloğu (`catalog/apps.json`)

### Yol haritası
| Sürüm | İçerik |
|---|---|
| v0.1 | Çekirdek + 4 modül, komut satırından çalışır |
| v0.2 | WPF arayüz (onay kutulu ağaç, ilerleme çubuğu, log penceresi) |
| v0.3 | Seçim profilleri, katalog genişletme, testler |
| v1.0 | Tek `.exe`, GitHub Release |
| v2 | C# / .NET sürümü (aynı yedek formatı ve katalog) |

---

## 🇬🇧 English

**reset_back_system** lets you **pick with checkboxes** what to back up before reinstalling Windows, then restores everything in the right order afterwards.

> ⚠️ Work in progress. Not ready for use yet.

### What does it back up?
| Category | Contents |
|---|---|
| **Programs** | Installed programs (winget) → bulk reinstall after reset. A "manual install" list for anything not on winget |
| **Editor extensions** | VS Code, Cursor, Antigravity, Windsurf extensions and settings |
| **System** | Wi-Fi profiles, drivers, power plan, BitLocker recovery key, hosts, environment variables |
| **User data** | Desktop, Documents, `.ssh`, `.gitconfig`, game saves and settings of known apps |

### How it works
1. **Backup (before reset):** scans the PC and lists what it finds. You choose, and your selection is backed up to a target folder (USB, D:, …).
2. **Restore (after reset):** reads the backup folder and shows only what it contains. You choose, and it restores in order:
   drivers → Wi-Fi → programs → extensions → settings → user files.

### Features (planned)
- Turkish / English UI
- Dry-run mode: shows what would happen without touching anything
- Warnings for sensitive data (Wi-Fi passwords, BitLocker keys)
- Asks you to close an app before its settings are restored
- Community-extendable app catalog (`catalog/apps.json`)

### Roadmap
| Version | Contents |
|---|---|
| v0.1 | Core + 4 modules, command line |
| v0.2 | WPF GUI (checkbox tree, progress bar, log window) |
| v0.3 | Selection profiles, bigger catalog, tests |
| v1.0 | Single `.exe`, GitHub Release |
| v2 | C# / .NET version (same backup format and catalog) |

---

License: [MIT](LICENSE)
