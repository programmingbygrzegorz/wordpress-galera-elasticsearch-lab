# Ćwiczenia

Każdy blok to ok. 30–45 minut. Zadania najpierw spróbuj zrobić sam, rozwiązanie jest pod „Rozwiązanie”.
Na każdej maszynie działa `lab-status` (szybki przegląd) i `sudo lab-chaos` (kontrolowane awarie).

Przed startem: lab działa (`vagrant up --no-parallel`), strona otwiera się pod https://wordpress.lab,
a `lab-status` na vps1 pokazuje `wsrep_cluster_size 3` i Elasticsearch `"status" : "green"`.

**Spis:** [A. Load balancer](#a-load-balancer) · [B. Galera](#b-mariadb-galera) · [C. Elasticsearch](#c-elasticsearch) ·
[D. S3 i s3fs](#d-s3-i-s3fs) · [G. Wdrożenia z Git](#g-wdrożenia-z-git) · [Z. Zabbix](#z-zabbix) · [X. Awarie łączone](#x-awarie-łączone)

---

## A. Load balancer

### A1. Rozkład ruchu

Sprawdź, który węzeł odpowiada na kolejne żądania. Otwórz panel statystyk HAProxy i znajdź liczniki sesji dla vps1 i vps2.

<details><summary>Rozwiązanie</summary>

Na maszynie `lb` (albo w PowerShellu: `curl.exe -skI https://wordpress.lab/`):

```bash
for i in $(seq 10); do curl -skI https://wordpress.lab/ | grep -i x-served-by; done
```

Wynik na zmianę `vps1` / `vps2` – to `balance roundrobin`. Nagłówek dodaje nginx (`add_header X-Served-By $hostname`),
a wtyczka `lab-served-by` pokazuje to samo w prawym dolnym rogu strony.

Panel: http://192.168.57.5:8404/stats – kolumna **Sessions → Total** rośnie po równo.
Stan z wiersza poleceń: `lab-status` na `lb` albo:

```bash
echo "show servers state be_wordpress" | sudo socat stdio /run/haproxy/admin.sock
```
</details>

### A2. Awaria węzła WWW

Zatrzymaj nginx na vps1. Po ilu sekundach HAProxy przestaje wysyłać do niego ruch? Czy w tym czasie jakieś żądania kończą się błędem?
Uruchom nginx z powrotem – po jakim czasie vps1 wraca do puli?

<details><summary>Rozwiązanie</summary>

```bash
# vps1
sudo systemctl stop nginx
# lb – obserwuj co sekundę
watch -n1 'echo "show servers state be_wordpress" | sudo socat stdio /run/haproxy/admin.sock | awk "{print \$4, \$6}"'
```

Konfiguracja: `default-server inter 3s fall 3 rise 2` → węzeł wypada po **3 nieudanych sprawdzeniach co 3 s (ok. 9 s)**,
wraca po **2 udanych (ok. 6 s)**. W oknie 9 s część żądań trafiających na vps1 dostaje **503/502** – dlatego na prawdziwych serwerach
skraca się `inter` i dodaje `option redispatch` + `retries 2`, żeby żądanie przy błędzie połączenia poszło na drugi węzeł.

Spróbuj: dopisz w `backend be_wordpress` linie `option redispatch` i `retries 2`, `sudo haproxy -c -f /etc/haproxy/haproxy.cfg`,
`sudo systemctl reload haproxy`, powtórz test. (Ansible nadpisze plik przy następnym `vagrant provision lb` – trwałą zmianę rób
w `ansible/roles/haproxy/templates/haproxy.cfg.j2`).
</details>

### A3. Health check sprawdza więcej niż port

Zatrzymaj **MariaDB** (nie nginx) na vps1. Co zwraca `/healthz` na vps1, co widzi HAProxy i co zobaczyłby użytkownik,
gdyby LB sprawdzał tylko, czy port 80 odpowiada?

<details><summary>Rozwiązanie</summary>

```bash
# vps1
sudo systemctl stop mariadb
curl -s http://127.0.0.1/healthz          # DB DOWN, kod 503
curl -sI -H "Host: wordpress.lab" -H "X-Forwarded-Proto: https" http://127.0.0.1/ | head -1   # 500 – błąd połączenia z bazą
```

HAProxy oznacza vps1 jako DOWN, bo `http-check expect status 200` dostaje 503. Gdyby sprawdzał tylko TCP na porcie 80,
co drugi użytkownik widziałby „Error establishing a database connection”.

`/healthz` (plik `/var/www/health/healthz.php`) sprawdza: połączenie z lokalną bazą, `wsrep_ready = ON` i czy istnieje wydanie WordPressa.

Powrót: `sudo systemctl start mariadb` – węzeł dociąga brakujące zmiany przez IST (ćwiczenie B2).
</details>

### A4. Sticky sessions i algorytm leastconn

Włącz sticky sessions (ciasteczko `SRV`) i sprawdź, że kolejne żądania z tym ciasteczkiem trafiają na ten sam węzeł.
Kiedy WordPress ich potrzebuje, a kiedy nie? Zmień algorytm na `leastconn` i zrób test obciążenia.

<details><summary>Rozwiązanie</summary>

W `/etc/haproxy/haproxy.cfg` na `lb` odkomentuj `cookie SRV insert indirect nocache` (serwery mają już `cookie vps1/vps2`), potem:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy
curl -skI https://wordpress.lab/ | grep -iE "set-cookie|x-served-by"      # Set-Cookie: SRV=vps2
for i in $(seq 5); do curl -skI -b "SRV=vps2" https://wordpress.lab/ | grep -i x-served-by; done   # zawsze vps2
```

Sam WordPress **nie potrzebuje** sticky sessions: logowanie trzyma w ciasteczkach podpisanych kluczami z `wp-config.php`,
które są identyczne na obu węzłach (dlatego Ansible generuje je raz, do `.lab/`). Potrzebują ich wtyczki używające sesji PHP
(sklepy, formularze wieloetapowe) – sesje leżą w `/var/lib/php/sessions` lokalnie na węźle.

`leastconn`: zmień `balance roundrobin` → `balance leastconn`, przeładuj. Test obciążenia z `lb`:

```bash
sudo apt-get install -y apache2-utils
ab -n 500 -c 20 https://wordpress.lab/
```

W panelu statystyk porównaj **Cur/Max sessions**. `leastconn` ma sens przy długich żądaniach (eksporty, API), przy krótkich daje to samo co round robin.
</details>

---

## B. MariaDB Galera

### B1. Stan klastra i replikacja

Sprawdź na każdym węźle rozmiar klastra, stan węzła i czy jest gotowy. Utwórz tabelę na vps1, dopisz wiersze z każdego węzła
i odczytaj je na vps2. Dlaczego `id` nie rosną o 1?

<details><summary>Rozwiązanie</summary>

```bash
sudo mariadb -e "SHOW STATUS WHERE Variable_name IN
  ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment','wsrep_ready','wsrep_connected')"
```

Oczekiwane: `3`, `Primary`, `Synced`, `ON`, `ON`.

```bash
# vps1
sudo mariadb -e "CREATE DATABASE IF NOT EXISTS lab;
  CREATE TABLE lab.t (id INT AUTO_INCREMENT PRIMARY KEY, node VARCHAR(20), ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP);
  INSERT INTO lab.t (node) VALUES (@@hostname);"
# vps2 i vps3
sudo mariadb -e "INSERT INTO lab.t (node) VALUES (@@hostname); SELECT * FROM lab.t;"
```

`id` nie idą po kolei (są „dziury”), bo przy `wsrep_auto_increment_control=ON` krok to liczba węzłów (3), a każdy węzeł ma inny offset –
dwa węzły piszące jednocześnie nigdy nie wygenerują tego samego klucza. Sprawdź: `SHOW VARIABLES LIKE 'auto_increment%';`

Replikacja jest **synchroniczna**: `COMMIT` kończy się dopiero, gdy wszystkie węzły przyjmą zmianę (certyfikacja) – dlatego
każdy VPS może pisać do swojej lokalnej bazy (`DB_HOST=127.0.0.1` w `wp-config.php`).
</details>

### B2. Węzeł wraca po krótkiej przerwie (IST)

Zatrzymaj MariaDB na vps2, dopisz kilka wierszy na vps1, uruchom vps2. Znajdź w logu, jak węzeł dostał brakujące dane.

<details><summary>Rozwiązanie</summary>

```bash
# vps2
sudo systemctl stop mariadb
# vps1
sudo mariadb -e "INSERT INTO lab.t (node) VALUES ('w czasie przerwy'), ('w czasie przerwy');
  SHOW STATUS LIKE 'wsrep_cluster_size';"     # 2
# vps2
sudo systemctl start mariadb
sudo journalctl -u mariadb --since "-5 min" | grep -iE "IST|SST|Synced"
```

W logu: `Receiving IST` / `IST received` – węzeł dostał tylko brakujące transakcje z **gcache** węzła-dawcy
(`gcache.size=256M` w `/etc/mysql/mariadb.conf.d/60-galera.cnf`). Szybkie, bez kopiowania całej bazy.
</details>

### B3. Pełna kopia danych (SST)

Wymuś na vps2 pełną kopię danych od innego węzła. Który węzeł był dawcą i czy w tym czasie mógł normalnie pracować?

<details><summary>Rozwiązanie</summary>

```bash
# vps2
sudo systemctl stop mariadb
sudo rm /var/lib/mysql/grastate.dat /var/lib/mysql/galera.cache   # węzeł „zapomina”, na jakim etapie był
sudo systemctl start mariadb      # trwa dłużej
sudo journalctl -u mariadb --since "-5 min" | grep -iE "SST|donor|mariabackup"
```

Bez `grastate.dat` węzeł nie zna swojej pozycji, więc dostaje **SST** – pełną kopię przez `mariabackup` (`wsrep_sst_method`).
Dawca na czas kopiowania ma stan `Donor/Desynced` (`wsrep_local_state_comment`). `mariabackup` nie blokuje zapisów,
ale obciąża dysk i sieć – przy dużej bazie SST potrafi trwać godzinami, dlatego ważny jest odpowiednio duży `gcache`.

Hasło użytkownika `sst` jest w `wsrep_sst_auth` – sprawdź uprawnienia: `sudo mariadb -e "SHOW GRANTS FOR 'sst'@'localhost'"`.
</details>

### B4. Awaria całego klastra – bootstrap ⭐

Najważniejsze ćwiczenie bloku. Wyłącz wszystkie trzy węzły bazy i uruchom je ponownie. Dlaczego MariaDB nie startuje?
Przywróć klaster tak, żeby nie stracić danych.

<details><summary>Rozwiązanie</summary>

Wyłączenie po kolei (ostatni wyłączony ma najnowsze dane):

```bash
# na vps1, potem vps2, potem vps3
sudo mariadb -e "INSERT INTO lab.t (node) VALUES (CONCAT('przed wyłączeniem ', @@hostname));"
sudo systemctl stop mariadb
```

Start na dowolnym węźle: `sudo systemctl start mariadb` wisi i kończy się błędem – węzeł szuka klastra pod adresami z
`wsrep_cluster_address`, nikogo nie znajduje i **nie wie, czy ma najnowsze dane**, więc odmawia startu (ochrona przed utratą danych).

**1. Który węzeł ma najnowsze dane?**

```bash
sudo cat /var/lib/mysql/grastate.dat
```

- czyste wyłączenie: `seqno` > 0, a ostatni wyłączony węzeł ma `safe_to_bootstrap: 1`,
- awaria (np. `vagrant halt` albo wyłączony prąd): `seqno: -1` na wszystkich – wtedy na każdym węźle:

```bash
sudo galera_recovery     # wypisuje --wsrep_start_position=<uuid>:<seqno>
```

Wybierz węzeł z **najwyższym seqno**. Jeśli wszędzie `safe_to_bootstrap: 0`, na wybranym węźle ustaw ręcznie
`safe_to_bootstrap: 1` w `grastate.dat`.

**2. Założenie klastra na tym jednym węźle, potem dołączenie pozostałych:**

```bash
sudo galera_new_cluster                     # tylko na wybranym węźle!
sudo systemctl start mariadb                # na pozostałych, po kolei
sudo mariadb -e "SHOW STATUS LIKE 'wsrep_cluster_size'"    # 3
sudo mariadb -e "SELECT * FROM lab.t ORDER BY id DESC LIMIT 3"   # wiersze sprzed wyłączenia są
```

**Nigdy** nie rób `galera_new_cluster` na dwóch węzłach – powstaną dwa niezależne klastry z rozjechanymi danymi.
To samo dzieje się po `vagrant halt` całego labu – zapisz sobie tę procedurę.
</details>

### B5. Kworum i odcięcie węzła

Odetnij vps3 od sieci na 2 minuty (`sudo lab-chaos isolate 120`). Jaki stan mają vps3 i pozostałe węzły? Czy strona działa?
Co by się stało, gdyby klaster miał tylko 2 węzły?

<details><summary>Rozwiązanie</summary>

```bash
# vps3 (polecenie wraca po 2 minutach; w drugim oknie vagrant ssh vps3)
sudo lab-chaos isolate 120
sudo mariadb -e "SHOW STATUS LIKE 'wsrep_cluster_status'; SELECT 1;"
```

vps3 widzi tylko siebie (1 z 3 – brak większości), przechodzi w **non-Primary** i odrzuca zapytania
(`WSREP has not yet prepared node for application use`). vps1 i vps2 mają 2 z 3 = **kworum**, działają dalej (`wsrep_cluster_size 2`),
strona działa. Po przywróceniu sieci vps3 sam wraca (IST).

Przy **2 węzłach** zerwanie połączenia między nimi = obie połowy mają 1 z 2, żadna nie ma większości → **obie** przestają przyjmować
zapytania. Dlatego klaster Galery ma nieparzystą liczbę węzłów (albo 2 + `garbd` – arbiter bez danych).

Dodatkowo: odetnij vps1 (`sudo lab-chaos isolate 60` na vps1) i zobacz w panelu HAProxy, że vps1 wypada z puli –
`/healthz` sprawdza `wsrep_ready`.
</details>

---

## C. Elasticsearch

### C1. Klaster, węzły i shardy

Sprawdź stan klastra, listę węzłów (który jest masterem?) i utwórz indeks z 3 shardami i 1 repliką. Jak shardy rozłożyły się na węzły?

<details><summary>Rozwiązanie</summary>

```bash
curl -s localhost:9200/_cluster/health?pretty
curl -s 'localhost:9200/_cat/nodes?v&h=name,ip,node.role,master,heap.percent'     # master oznaczony *
curl -s -X PUT localhost:9200/lab -H 'Content-Type: application/json' \
  -d '{"settings":{"number_of_shards":3,"number_of_replicas":1}}'
for i in $(seq 1 20); do curl -s -X POST localhost:9200/lab/_doc -H 'Content-Type: application/json' -d "{\"nr\":$i}" >/dev/null; done
curl -s 'localhost:9200/_cat/shards/lab?v'
```

6 shardów (3 główne `p` + 3 repliki `r`), ES nigdy nie kładzie repliki na tym samym węźle co jej shard główny.
</details>

### C2. Utrata jednego węzła

Zatrzymaj Elasticsearch na vps2. Jaki jest stan klastra zaraz po zatrzymaniu, a jaki po ok. 1–2 minutach? Uruchom go ponownie.

<details><summary>Rozwiązanie</summary>

```bash
# vps2
sudo systemctl stop elasticsearch
# vps1
watch -n2 "curl -s localhost:9200/_cluster/health | jq '{status, number_of_nodes, unassigned_shards}'; curl -s 'localhost:9200/_cat/shards/lab?v'"
```

Od razu **yellow** – wszystkie dane są dostępne, ale części replik brakuje. ES czeka
`index.unassigned.node_left.delayed_timeout` (domyślnie 1 min), czy węzeł nie wróci, potem odtwarza repliki na pozostałych węzłach → **green**.
Dlaczego jest yellow, wyjaśnia: `curl -s localhost:9200/_cluster/allocation/explain?pretty`.

Po `sudo systemctl start elasticsearch` na vps2 klaster przenosi część shardów z powrotem (rebalancing).
</details>

### C3. Utrata dwóch węzłów

Zatrzymaj Elasticsearch na vps2 **i** vps3. Czy da się odczytać dane z vps1? Porównaj z zachowaniem Galery z ćwiczenia B5.

<details><summary>Rozwiązanie</summary>

```bash
curl -s localhost:9200/_cluster/health?pretty      # po chwili: master_not_discovered_exception
```

1 z 3 węzłów master-eligible to brak większości – nie da się wybrać mastera, klaster przestaje działać
(ta sama zasada kworum co w Galerze). WordPress z ElasticPress w takiej sytuacji wraca do wyszukiwania przez MySQL.
Uruchom oba węzły – klaster sam się złoży.

Pytanie dodatkowe: w `elasticsearch.yml` jest `cluster.initial_master_nodes`. Służy **tylko** do pierwszego założenia klastra.
Po założeniu klastra usuwa się go z konfiguracji – inaczej przy błędzie (np. czysty katalog danych na 2 węzłach) mógłby powstać nowy, pusty klaster.
</details>

### C4. ElasticPress – wyszukiwarka WordPressa w Elasticsearch

Włącz wtyczkę ElasticPress przez repozytorium Git (patrz blok G), zaindeksuj wpisy i sprawdź, że wyszukiwanie na stronie idzie przez ES.

<details><summary>Rozwiązanie</summary>

W repozytorium strony w `deploy/post-deploy.sh` odkomentuj dwie linie z `elasticpress`, potem `git commit` i `git push` (G1).
ElasticPress łączy się z `EP_HOST` = `http://127.0.0.1:9200` (lokalny węzeł, `wp-config.php`).

```bash
curl -s 'localhost:9200/_cat/indices?v' | grep -i post        # indeks wpisów
sudo -u www-data HOME=/tmp wp --path=/var/www/wordpress/current elasticpress stats
```

Dodaj kilka wpisów w panelu i wyszukaj na stronie (`https://wordpress.lab/?s=słowo`). Zatrzymaj ES na wszystkich węzłach –
wyszukiwarka dalej działa (wolniej, przez bazę), a w panelu pojawi się ostrzeżenie ElasticPress.
</details>

---

## D. S3 i s3fs

### D1. Wspólne pliki na obu węzłach

Wgraj obrazek przez **Media → Dodaj** i sprawdź, gdzie fizycznie leży plik.

<details><summary>Rozwiązanie</summary>

```bash
# vps1 i vps2 – ten sam plik widoczny na obu
ls -l /var/www/wordpress/shared/uploads/$(date +%Y/%m)/
mount | grep s3fs
# vps3 – plik w buckecie S3
echo "fs.ls /buckets/wp-uploads/$(date +%Y/%m)" | weed shell -master=vps3:9333
```

`wp-content/uploads` w każdym wydaniu to symlink do `shared/uploads`, a tam jest zamontowany bucket `wp-uploads` przez **s3fs**
(opcje w `/etc/fstab`). Bez tego obrazek wgrany na vps1 dawałby 404, gdy LB skieruje żądanie na vps2.
</details>

### D2. Awaria S3

Zatrzymaj S3 na vps3 (`sudo systemctl stop seaweedfs`). Co dzieje się ze stroną, obrazkami i wgrywaniem plików? Przywróć działanie.

<details><summary>Rozwiązanie</summary>

```bash
# vps1
timeout 10 ls /var/www/wordpress/shared/uploads || echo "S3 nie odpowiada"
lab-status
```

Strona się ładuje (kod PHP jest lokalnie), ale obrazki nie, a wgrywanie zwraca błąd. Procesy czytające z s3fs mogą **wisieć** –
to częsty powód „zamulonego” serwera, gdy magazyn S3 ma problem.

Po `sudo systemctl start seaweedfs` s3fs zwykle sam wznawia pracę. Jeśli widzisz `Transport endpoint is not connected`, proces s3fs
padł – montujesz ponownie:

```bash
sudo umount -l /var/www/wordpress/shared/uploads
sudo mount /var/www/wordpress/shared/uploads
```
</details>

### D3. Start serwera bez S3 – pułapka

Zatrzymaj S3 na vps3, zrestartuj vps2 (`sudo reboot`), wgraj obrazek tak, żeby trafił na vps2 (sticky session z A4), potem uruchom S3
i ponownie zamontuj uploads. Gdzie jest obrazek?

<details><summary>Rozwiązanie</summary>

Po restarcie bez S3 montowanie się nie udało, a `shared/uploads` jest **zwykłym katalogiem na dysku vps2**. WordPress zapisał
plik lokalnie. Po zamontowaniu S3 plik „znika” – jest przykryty przez punkt montowania i nie ma go w S3, więc vps1 też go nie widzi.

```bash
mountpoint /var/www/wordpress/shared/uploads     # "is not a mountpoint" = problem
```

Wniosek: monitoruj, czy uploads jest zamontowany (w Zabbixie: `vfs.fs.discovery` albo własny item z `mountpoint`),
a w `/healthz` można dodać sprawdzenie montowania, żeby LB nie wysyłał ruchu na taki węzeł.
</details>

---

## G. Wdrożenia z Git

Repozytorium strony jest na VPS3: `/srv/git/wordpress-site.git`. Push na `main` uruchamia hook `post-receive` → `wp-deploy`.

### G1. Pierwsza zmiana i wdrożenie

Zmień kolor paska z nazwą węzła we wtyczce `lab-served-by`, wypchnij zmianę i obserwuj przebieg wdrożenia. Ile wydań jest teraz na vps1?

<details><summary>Rozwiązanie</summary>

```bash
vagrant ssh vps3
git clone /srv/git/wordpress-site.git && cd wordpress-site
git config user.name "Twoje Imię"; git config user.email "ty@example.com"
sed -i 's/background:#1d2327/background:#b32d2e/' wp-content/plugins/lab-served-by/lab-served-by.php
git commit -am "Czerwony pasek z nazwą węzła" && git push
```

W terminalu widać wyjście hooka: budowa wydania na vps1 → test → vps2 → test → `post-deploy`. Na vps1:

```bash
ls /var/www/wordpress/releases/ ; readlink /var/www/wordpress/current
curl -skI https://wordpress.lab/ | grep -i x-wp-release       # vps1 · commit abc1234
```

Pracę z Windowsa (np. w VS Code) też da się skonfigurować: klucz `.lab/deploy_ed25519` i adres
`deploy@192.168.57.12:/srv/git/wordpress-site.git`.
</details>

### G2. Zepsute wdrożenie ⭐

Wprowadź błąd składni PHP we wtyczce i zrób push. Co się stało z vps1, a co z vps2? Czy strona działała przez cały czas? Napraw to „po gitowemu”.

<details><summary>Rozwiązanie</summary>

```bash
echo "<?php this is not php" >> wp-content/plugins/lab-served-by/lab-served-by.php
git commit -am "Zepsuty kod" && git push
```

Na vps1 powstaje nowe wydanie, `wp-smoke-test` dostaje **500**, `wp-deploy` robi `wp-rollback` na vps1 i **przerywa** –
vps2 nie jest ruszany. Strona działała cały czas (przez chwilę mogła odpowiadać błędem z vps1, zanim LB go wyłączył albo test cofnął zmianę).
To wdrożenie kroczące (*rolling deployment*) z automatycznym cofnięciem.

Ważne: `main` w repozytorium **już wskazuje na zepsuty commit** (hook `post-receive` nie może odrzucić pusha).
Poprawka to nowy commit:

```bash
git revert --no-edit HEAD && git push
```
</details>

### G3. Wtyczka z wordpress.org i blokada panelu

Dodaj wtyczkę **Query Monitor** przez `plugins.txt` i aktywuj ją w `deploy/post-deploy.sh`. Spróbuj potem zainstalować dowolną
wtyczkę z panelu WordPressa – dlaczego się nie da?

<details><summary>Rozwiązanie</summary>

```bash
echo "query-monitor" >> plugins.txt
echo "wp plugin activate query-monitor" >> deploy/post-deploy.sh
git commit -am "Query Monitor" && git push
```

`wp-release` pobiera wtyczkę z `downloads.wordpress.org` (do pamięci podręcznej `/var/cache/wp-lab`) i dokłada do każdego wydania.

W panelu nie ma przycisku „Dodaj wtyczkę”, bo `wp-config.php` ma `DISALLOW_FILE_MODS = true`. Gdyby panel mógł instalować wtyczki,
trafiałyby tylko na jeden węzeł (ten, który obsłużył żądanie), a przy następnym wdrożeniu by znikały. **Jedynym źródłem kodu jest Git.**
Na prawdziwej stronie przypinaj wersje: `query-monitor 3.17.0` – wtedy wdrożenie jest powtarzalne.
</details>

### G4. Ręczny rollback i rozjazd węzłów

Wykonaj `sudo wp-rollback` tylko na vps1. Co pokazuje nagłówek `X-WP-Release` przy kolejnych odświeżeniach? Jak poprawnie wrócić
do konkretnej wersji na wszystkich węzłach?

<details><summary>Rozwiązanie</summary>

Po rollbacku na jednym węźle strona serwuje **dwie różne wersje** na zmianę (vps1 stary commit, vps2 nowy) – rozjazd, który przy
zmianach w bazie potrafi zepsuć stronę. `wp-rollback` to gaszenie pożaru na jednym węźle.

Poprawnie, na wszystkich węzłach i z testem:

```bash
# vps3
git -C /srv/git/wordpress-site.git log --oneline | head
wp-deploy <commit>          # wdrożenie wskazanego commita (bez zmiany main)
```

albo trwale: `git revert` + `git push`.
</details>

---

## Z. Zabbix

Zabbix: http://192.168.57.12/ (`Admin` / `zabbix`). Agenci na wszystkich maszynach są już skonfigurowani
(`/etc/zabbix/zabbix_agent2.conf`, metadane `HostMetadata=wplab …`), ale hosty trzeba dodać.

### Z1. Autorejestracja hostów

Skonfiguruj akcję autorejestracji, tak żeby wszystkie 4 maszyny same pojawiły się w Zabbixie z szablonem Linuxa.

<details><summary>Rozwiązanie</summary>

**Alerts → Actions → Autoregistration actions → Create action:**
- warunek: *Host metadata* **contains** `wplab`,
- operacje: *Add host*, *Add to host groups*: `WordPress Lab`, *Link templates*: `Linux by Zabbix agent active`.

Po 1–2 minutach hosty pojawią się w **Data collection → Hosts**. Jeśli nie: na maszynie
`sudo journalctl -u zabbix-agent2 -n 30` i w Zabbixie **Reports → Audit log**.

Dodatkowo: druga akcja z warunkiem *Host metadata contains* `web` → szablon `Nginx by Zabbix agent`
(wymaga strony `stub_status` w nginx – dobre ćwiczenie z konfiguracji nginx).
</details>

### Z2. Szablony dla klastrów

Podłącz monitoring Elasticsearch i HAProxy. Jakie makra trzeba ustawić?

<details><summary>Rozwiązanie</summary>

- Elasticsearch: do hosta `vps3` dołącz szablon **Elasticsearch Cluster by HTTP** – szablon odpytuje `/_cluster/health`
  i `/_nodes/stats`; port i adres ustawiasz w makrach szablonu (zakładka *Macros → Inherited and host macros*).
- HAProxy: do hosta `lb` dołącz **HAProxy by HTTP** – w makrach podaj adres strony statystyk
  (`http://192.168.57.5:8404/stats`) i login/hasło (`admin` / `.lab/haproxy_stats_password`).
- Galera: **MySQL by Zabbix agent 2** – wymaga użytkownika do monitoringu
  (`CREATE USER 'zbx_monitor'@'localhost' IDENTIFIED BY '...'; GRANT REPLICATION CLIENT, PROCESS, SHOW DATABASES, SHOW VIEW ON *.* TO 'zbx_monitor'@'localhost';`)
  i makr z danymi logowania. Dodaj własny item `mysql.custom.query` z `SHOW STATUS LIKE 'wsrep_cluster_size'` i trigger `< 3`.
</details>

### Z3. Scenariusz WWW i „mrugające” alerty ⭐

Skonfiguruj scenariusz WWW sprawdzający stronę co minutę i trigger, który zgłasza problem. Potem uruchom
`sudo lab-chaos flap 15` na `lb` i obserwuj listę problemów.

<details><summary>Rozwiązanie</summary>

Host `lb` → **Web scenarios → Create web scenario**:
- *Name*: `WP-WEB`, *Update interval*: `1m`, *Attempts*: `1`,
- krok: *URL* `https://wordpress.lab/`, *Timeout* `15s`, *Required status codes* `200`.

Trigger (**Triggers → Create trigger**), nazwa `WP-WEB-dostepnosc`:

```
last(/lb/web.test.fail[WP-WEB])<>0
```

`sudo lab-chaos flap 15` co 1–4 minuty wstrzymuje ruch na 20–90 s. W **Monitoring → Problems** zobaczysz serię
„Problem → Resolved in 5xs” – problem zgłaszany po **jednym** nieudanym
sprawdzeniu, a rozwiązany po pierwszym udanym (stąd czasy ~1 min, ~2 min, ~4 min).
</details>

### Z4. Koniec z „mrugającymi” alertami ⭐

Przerób scenariusz i trigger tak, żeby krótkie zawieszenia (do 2 minut) nie wysyłały alertu, a dłuższa awaria – tak.

<details><summary>Rozwiązanie</summary>

1. Scenariusz: *Attempts* `3` (Zabbix ponawia krok przed uznaniem błędu), *Timeout* `30s`.
2. Trigger: problem dopiero, gdy strona nie działa **przez 3 minuty bez przerwy**:

   ```
   min(/lb/web.test.fail[WP-WEB],3m)>0
   ```

   Opcjonalnie histereza – *Recovery expression*: `max(/lb/web.test.fail[WP-WEB],2m)=0` (rozwiązanie dopiero po 2 minutach poprawnej pracy).
3. Uruchom ponownie `sudo lab-chaos flap 15` – krótkie zawieszenia nie generują problemów. Potem `sudo lab-chaos slow 300 20000`
   (5 minut ciągłej awarii) – problem pojawia się po ~3 minutach.

Dobra praktyka: najpierw ustalić przyczynę krótkich zawieszeń (logi z godzin alertów),
a niezależnie od tego ustawić trigger tak, żeby alarmował tylko o realnych awariach.
</details>

---

## X. Awarie łączone

### X1. „Strona co chwilę się zawiesza”

Na vps1 uruchom `sudo lab-chaos slow 180 4000`. Zachowuj się jak dyżurny: ustal, który węzeł ma problem, jaki i jak to widać
w HAProxy, Zabbixie i logach.

<details><summary>Rozwiązanie</summary>

Kolejność diagnozy: **objaw → który węzeł → która warstwa → log.**

1. Panel HAProxy: vps1 przechodzi w DOWN (health check `inter 3s` nie mieści się w timeoucie) i wraca – „mruga”.
2. `curl -skI https://wordpress.lab/` z `lb` kilka razy – odpowiedzi z vps1 trwają kilka sekund (`time curl …`).
3. Na vps1: `lab-status` (usługi OK), `ping -c3 vps2` (opóźnienie ~4000 ms) → problem z siecią, nie z aplikacją.
4. `tc qdisc show` pokazuje `netem delay 4000ms` – „winowajca”.

Na prawdziwych serwerach ta sama ścieżka prowadzi do: przeciążonego PHP-FPM (`pm.max_children` w logu php-fpm), wolnej bazy, wiszącego s3fs
albo sieci.
</details>

### X2. „Po awarii zasilania nic nie działa”

Wyłącz cały lab (`vagrant halt`), włącz go ponownie (`vagrant up --no-parallel`) i doprowadź do pełnego działania.
Zrób z tego checklistę.

<details><summary>Rozwiązanie</summary>

1. **Galera** – nie wstanie sama: procedura z B4 (`grastate.dat`, `galera_recovery`, `galera_new_cluster` na jednym węźle).
2. **S3** – `systemctl status seaweedfs` na vps3.
3. **s3fs** – `mountpoint /var/www/wordpress/shared/uploads` na vps1 i vps2; jeśli vps3 wstał później, zamontuj ponownie (D2).
4. **Elasticsearch** – `_cluster/health` → green (składa się sam, gdy są min. 2 węzły).
5. **WordPress** – `wp-smoke-test` na vps1 i vps2.
6. **HAProxy** – oba węzły UP w panelu statystyk.
7. **Zabbix** – brak aktywnych problemów.

Gotową checklistę dopisz do swoich notatek – przyda się przy każdym klastrze.
</details>
