# Kod strony WordPress (repozytorium wdrożeniowe)

Każdy `git push` na gałąź **main** wdraża stronę na VPS1 i VPS2 (po kolei, z testem po każdym węźle).

| Plik | Do czego |
|---|---|
| `.wp-version` | wersja WordPressa (`latest` albo konkretny numer wersji) |
| `plugins.txt` | wtyczki z wordpress.org (`nazwa [wersja]`) |
| `wp-content/plugins/`, `wp-content/themes/` | własny kod |
| `deploy/post-deploy.sh` | zadania po wdrożeniu (aktywacja wtyczek, zmiany w bazie) |

Nie commituj `wp-config.php` ani `uploads/` – dokłada je serwer.
