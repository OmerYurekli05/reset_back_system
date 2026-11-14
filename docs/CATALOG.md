# Katalog rehberi / Catalog guide

## 🇹🇷 Uygulama ekleme

Uygulama ayarları ve kayıtları [`catalog/apps.json`](../catalog/apps.json) dosyasından okunur. Yeni bir uygulama için kod yazmana gerek yok, bir giriş eklemen yeterli:

```json
{
  "id": "my-app",
  "name": "My App",
  "paths": ["%APPDATA%\\MyApp\\config", "%DOCUMENTS%\\MyApp\\settings.ini"],
  "processes": ["MyApp"],
  "exclude": ["cache", "logs"],
  "sensitive": false,
  "admin": false,
  "default": true,
  "note": { "tr": "Ayarlar ve profiller", "en": "Settings and profiles" }
}
```

| Alan | Zorunlu | Açıklama |
|---|---|---|
| `id` | evet | Küçük harf, rakam ve `-`. Öğe kimliği `app.<id>` olur |
| `name` | evet | Listede görünen ad |
| `paths` | evet | Klasör ya da dosya yolları. Sadece var olanlar yedeklenir |
| `processes` | hayır | Açıksa kapatılması istenecek işlem adları (`.exe` olmadan) |
| `exclude` | hayır | Klasör yedeklenirken atlanacak alt klasör adları |
| `sensitive` | hayır | Şifre ya da anahtar içeriyorsa `true`: varsayılan seçili gelmez, uyarı verir |
| `admin` | hayır | Okumak ya da yazmak için yönetici gerekiyorsa `true` (ör. Program Files) |
| `default` | hayır | `false` ise listede seçili gelmez (büyük klasörler için) |
| `note` | evet | Türkçe ve İngilizce kısa açıklama |

**Yol değişkenleri:** tüm Windows ortam değişkenleri (`%APPDATA%`, `%LOCALAPPDATA%`, `%USERPROFILE%`, `%ProgramFiles%`, `%ProgramFiles(x86)%` …) ve bilinen klasörler: `%DOCUMENTS%`, `%DESKTOP%`, `%PICTURES%`, `%VIDEOS%`, `%MUSIC%`, `%DOWNLOADS%`. Yolu sabit yazma (`C:\Users\Ali\...` gibi), yeni sistemde kullanıcı adı farklı olabilir.

Ekledikten sonra testleri çalıştır:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

## 🇹🇷 Editör ekleme

VS Code tabanlı editörler [`catalog/editors.json`](../catalog/editors.json) içinde tanımlıdır: `cli` (eklenti kurmak için komut satırı aracının olası yolları), `userDir` (ayar klasörü), `process`, isteğe bağlı `extra` (ayrıca kopyalanacak dosyalar).

---

## 🇬🇧 Adding an app

App settings and saves come from [`catalog/apps.json`](../catalog/apps.json). Adding an app needs no code, just an entry like the one above.

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Lower-case letters, digits and `-`. The item id becomes `app.<id>` |
| `name` | yes | Name shown in the list |
| `paths` | yes | Folder or file paths. Only existing ones are backed up |
| `processes` | no | Process names (without `.exe`) the user is asked to close |
| `exclude` | no | Sub-folder names skipped when copying a folder |
| `sensitive` | no | `true` when it holds passwords or keys: not selected by default, shows a warning |
| `admin` | no | `true` when admin rights are needed (e.g. Program Files) |
| `default` | no | `false` to leave it unselected (large folders) |
| `note` | yes | Short Turkish and English description |

**Path variables:** every Windows environment variable plus the known folders `%DOCUMENTS%`, `%DESKTOP%`, `%PICTURES%`, `%VIDEOS%`, `%MUSIC%`, `%DOWNLOADS%`. Never hard-code a user name.

## 🇬🇧 Adding an editor

VS Code based editors live in [`catalog/editors.json`](../catalog/editors.json): `cli` (possible paths of the command line tool used to install extensions), `userDir` (settings folder), `process`, optional `extra` (additional files to copy).

## Backup format

```
ResetBack-2026-11-14_1530/
├─ manifest.json          tool, formatVersion, appVersion, created, computer, os, items[]
├─ system-info.txt        hardware / OS summary
├─ backup-log-*.txt
├─ programs.winget/       installed-programs.csv, winget.json
├─ editors.<id>/          extensions.txt, User/, extra<n>/
├─ system.<name>/
├─ userdata.<folder>/files/
└─ app.<id>/p<n>/          one sub-folder per catalog path index
```
`manifest.json` is language-neutral JSON so other tools (such as the planned C# version) can read the same backups.

## winget eşleme kataloğu / winget map

[`catalog/winget-map.json`](../catalog/winget-map.json):
- `map`: kurulu programın adı (regex) → winget ya da msstore kimliği. `winget export` bir programı eşleyemezse (kullanıcıya özel kurulumlar, msstore kaynağı kapalıyken Store uygulamaları) buradan tamamlanır. `$1` kimlikte ilk regex grubuyla değiştirilir. / Program name regex → winget or msstore id, used when `winget export` cannot match an installed program.
- `never`: asla kurulmayacak paketler (ör. `Microsoft.AppInstaller`: kurulurken winget'in kendisini kapatır). / Never installed (App Installer would close winget mid-run).
- `defaultOff`: Windows ile gelen uygulamalar; listede görünür ama varsayılan seçili gelmez. / Shown but not selected by default.

Yeni bir kimlik eklemeden önce doğrula / verify before adding: `winget show --id <id> --exact --source <winget|msstore>`
