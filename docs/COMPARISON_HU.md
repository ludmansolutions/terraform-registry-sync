# Összehasonlítás: cpina/push-to-another-repository vs terraform-registry-sync

A korábbi GitHub Action (`cpina/github-action-push-to-another-repository`) és a jelenlegi manifest-alapú pipeline (`terraform-registry-sync`) egymás melletti összehasonlítása.

---

## Architektúra

| Szempont | Korábbi (cpina) | Jelenlegi (terraform-registry-sync) |
|----------|----------------|--------------------------------------|
| **Futtatókörnyezet** | Docker konténer (Alpine + git) | GitHub-hosted runner (ubuntu-24.04) |
| **Belépési pont** | Egyetlen `entrypoint.sh` (176 sor) | `publish-module.sh` (550+ sor, 6 alparancs) |
| **Konfiguráció** | Action bemenetek az `action.yml`-ben | JSON manifest (`.github/terraform-modules.json`) |
| **Hatókör** | Általános könyvtár-push bármely repóba | Terraform modul publikáló pipeline |
| **Komponensek** | 3 fájl: `action.yml`, `Dockerfile`, `entrypoint.sh` | 3 alapfájl: workflow YAML, manifest JSON, segédszkript |
| **Több modul** | Modulonként egy meghívás (manuális mátrix) | Manifest-alapú automatikus felismerés mátrix stratégiával |

## Trigger modell

| Trigger | Korábbi | Jelenlegi |
|---------|---------|-----------|
| **PR** | Nem támogatott | Csak validáció (nincs publikálás) |
| **Push a main ágra** | Manuális konfiguráció workflow-onként | Módosult modulok automatikus felismerése, publikálás staging repóba |
| **Verzió tag** | Nem támogatott | Tag mint `terraform-gcp-v1.2.3` indítja a production kiadást |
| **Manuális indítás** | Nem támogatott | Teljes kontroll: modul, csatorna, ref, verzió, dry run |
| **Ütemezett** | Nem támogatott | Nem támogatott (egyiknek sincs rá szüksége) |

## Biztonság

| Szempont | Korábbi | Jelenlegi |
|----------|---------|-----------|
| **Hitelesítés** | SSH deploy kulcs vagy PAT (`API_TOKEN_GITHUB`) | GitHub App telepítési token (rövid élettartamú, repó-szintű) |
| **Token hatókör** | Széles PAT repo hozzáféréssel az összes repóhoz | Egyetlen cél-repóra korlátozva jobonként |
| **Token élettartam** | Hosszú élettartamú (PAT soha nem jár le, hacsak nem rotálják) | Rövid élettartamú (GitHub App token, ~1 óra) |
| **Token az URL-ekben** | Token beágyazva a git remote URL-be | `GIT_ASKPASS` szkript — token soha nem jelenik meg URL-ekben vagy logokban |
| **Action rögzítés** | Felhasználók jellemzően `@v5` módosítható taget használnak | Minden action teljes SHA-ra rögzítve verzió megjegyzéssel |
| **Jogosultságok** | Nincs megadva (örökli az alapértelmezettet) | `contents: read` workflow szinten, felülírás jobonként |
| **Környezet elkülönítés** | Nincs | Külön környezetek staging és production számára |
| **Környezet jóváhagyás** | Nincs | Kötelező reviewerek production-höz |
| **Titkok kezelése** | Egyetlen megosztott titok | Környezetenkénti titkok (staging vs production) |

## Validáció

| Ellenőrzés | Korábbi | Jelenlegi |
|------------|---------|-----------|
| **terraform fmt** | Nincs | `terraform fmt -check -recursive` |
| **terraform init** | Nincs | `terraform init -backend=false` |
| **terraform validate** | Nincs | `terraform validate` |
| **tflint** | Nincs | `tflint` (kihagyható) |
| **terraform test** | Nincs | Opcionális (alapértelmezetten kikapcsolva) |
| **Validáció célpontja** | N/A | Pontosan azt a payload-ot validálja, ami publikálásra kerül |
| **Publikálás előtti kapu** | Nincs — közvetlenül másol és push-ol | Minden ellenőrzésnek át kell mennie az artifact feltöltés előtt |

## Szinkronizációs modell

| Szempont | Korábbi | Jelenlegi |
|----------|---------|-----------|
| **Másolási módszer** | `cp -a` a célkönyvtár törlése után | `rsync --delete` kizárásokkal |
| **Destruktív viselkedés** | Mindent töröl a célkönyvtárban, frissen másol | Kontrollált rsync biztonsági küszöbértékekkel |
| **Biztonsági védelem** | Nincs — vakon törli a cél tartalmát | Jelölő fájl (`.registry-sync-root`) szükséges a cél repóban |
| **Törlési küszöbérték** | Nincs | Megszakít, ha a célfájlok >50%-a törlésre kerülne |
| **Mi kerül publikálásra** | Nyers forráskönyvtár | Gondozott payload artifact (lapított, szűrt, validált) |
| **Tiltott fájlok szűrése** | Nincs — mindent másol | Eltávolítja: `*.tfstate`, `*.tfvars`, `.terraform/`, stb. |
| **Payload csomagolás** | Közvetlen workspace-ból célba | Build artifact feltöltve, majd a publish job letölti |
| **Fájl lapítás** | Nincs — megőrzi a forrás struktúrát | `infra/*.tf` lapítva a gyökérbe |

## Kiadási modell

| Szempont | Korábbi | Jelenlegi |
|----------|---------|-----------|
| **Staging** | Nem támogatott | Commit a staging repóba (nincs release) |
| **Production** | Nem támogatott | Tag + GitHub Release a cél repón |
| **Release létrehozás** | Nincs | `gh release create --verify-tag --target <sha>` |
| **Tag biztonság** | N/A | Ellenőrzi, hogy a tag létezik a remote-on a release létrehozása előtt |
| **Verzió forrása** | N/A | Git tagből kinyerve (pl. `terraform-gcp-v1.2.3` -> `1.2.3`) |
| **Visszaállítás** | Újrafuttatás régi forrással | Javító verzió publikálása (nincs tag módosítás) |

## Audit nyomvonal

| Szempont | Korábbi | Jelenlegi |
|----------|---------|-----------|
| **Commit üzenet** | Konfigurálható sablon `ORIGIN_COMMIT` változóval | Strukturált metaadat: forrás repó, SHA, modul, csatorna, futás URL |
| **Release jegyzetek** | N/A | Forrás link, cél SHA, workflow futás URL, payload digest |
| **MANIFEST.txt** | Nincs | Minden fájl SHA256 hash-e + forrás metaadat |
| **Nyomonkövethetőség** | Csak commit üzenet | Forrás commit -> workflow futás -> payload artifact -> cél commit -> release |

## Konkurencia

| Szempont | Korábbi | Jelenlegi |
|----------|---------|-----------|
| **Konkurencia vezérlés** | Nincs | Modulonkénti, csatornánkénti konkurencia csoportok |
| **Staging** | N/A | `cancel-in-progress: true` (felváltott futások összevonódnak) |
| **Production** | N/A | `cancel-in-progress: false` (futó kiadások soha nem szakadnak meg) |

## Üzemeltetési eszközök

| Eszköz | Korábbi | Jelenlegi |
|--------|---------|-----------|
| **Beállítás validáció** | Nincs | `validate-setup.sh` ellenőrzi a repókat, jelölőket, környezeteket, titkokat |
| **Dry run** | Nincs | `DRY_RUN=true` kihagyja a push-t/release-t |
| **Tesztkészlet** | Nincs | 18 bats teszt fixture modullal |
| **Helyi build** | N/A | `build-release` parancs helyi csomagoláshoz |
| **Artifact tanúsítás** | Nincs | `actions/attest-build-provenance` a payload artifactokra |

## Új modul hozzáadása

| Lépés | Korábbi | Jelenlegi |
|-------|---------|-----------|
| **1** | Új workflow fájl létrehozása vagy mátrix bejegyzés hozzáadása | Bejegyzés hozzáadása a `terraform-modules.json`-be |
| **2** | Titkok konfigurálása | Cél repók létrehozása + `.registry-sync-root` hozzáadása |
| **3** | Action bemenetek konfigurálása | GitHub App telepítése a cél repókra |
| **4** | Manuális tesztelés | Változtatás push-olása — staging automatikusan megtörténik |
| **Workflow módosítás szükséges** | Igen (új workflow vagy mátrix módosítás) | Nem |

## Összefoglalás

| Dimenzió | Korábbi | Jelenlegi |
|----------|---------|-----------|
| **Egyszerűség** | Nagyon egyszerű, általános | Komplexebb, szakterület-specifikus |
| **Biztonság** | Alapszintű (PAT, nincs rögzítés, nincs validáció) | Megerősített (App tokenek, SHA rögzítés, minimális jogosultság, környezet elkülönítés) |
| **Validáció** | Nincs | Teljes Terraform validációs készlet |
| **Biztonságosság** | Destruktív, védelem nélkül | Jelölő fájlok, törlési küszöbértékek, dry run |
| **Auditálhatóság** | Csak commit üzenet | Teljes lánc: forrás -> artifact -> cél -> release |
| **Skálázhatóság** | Manuális modulonkénti beállítás | Manifest-alapú, nulla workflow módosítás modulonként |
| **Tesztelhetőség** | Nincs teszt | 18 automatizált teszt |
| **Karbantartás** | Funkció-fagyasztott | Aktívan karbantartott |

A korábbi action hasznos általános építőelem egyszerű cross-repo push-okhoz. A jelenlegi rendszer egy célzottan épített Terraform modul publikáló pipeline, amely a korábbi megoldás elemzése során feltárt biztonsági, validációs és üzemeltetési hiányosságokat orvosolja.

---

## Teljesítmény összehasonlítás

### Kódbázis méret

| Metrika | Korábbi (cpina) | Jelenlegi (terraform-registry-sync) |
|---------|----------------|--------------------------------------|
| **Alap szkript** | 176 sor (`entrypoint.sh`) | 603 sor (`publish-module.sh`) |
| **Workflow YAML** | N/A (a felhasználó írja sajátját) | 419 sor (`publish-terraform-modules.yml`) |
| **Konfig/manifest** | 77 sor (`action.yml`) | 42 sor (`terraform-modules.json`) |
| **Beállítási eszközök** | Nincs | 181 sor (`validate-setup.sh`) |
| **Tesztek** | Nincs | 274 sor (`publish-module.bats`, 18 teszt) |
| **Összes szállított sor** | ~253 | ~1 519 |

### Futásidejű overhead

| Metrika | Korábbi | Jelenlegi |
|---------|---------|-----------|
| **Konténer build** | ~110-160 MB Alpine image (futásonként építve) | Nincs (natív runner) |
| **Docker pull + build** | ~15-30mp hidegindítás | 0mp |
| **Terraform beállítás** | N/A | ~10-15mp (`setup-terraform` + `setup-tflint`) |
| **Runner indítás** | Docker konténer inicializáció | GitHub runner (már fut) |
| **Nettó hidegindítási overhead** | Magasabb (Docker build minden futásnál) | Alacsonyabb (natív, eszközbeállítás gyorsítótárazott) |

### Git műveletek egyetlen modul publikálásakor

| Művelet | Korábbi | Jelenlegi |
|---------|---------|-----------|
| **Clone** | 1 sekély (`--depth 1`) | 1 sekély (`--depth 1`) |
| **Config** | 4 (`user.email`, `user.name`, `http.version`, `lfs`) | 3 (`safe.directory`, `user.name`, `user.email`) |
| **Diff/status** | 2 (`git status`, `git diff-index`) | 2 (`git diff-index`, `git ls-files`) |
| **Stage + commit** | 2 (`git add .`, `git commit`) | 2 (`git add -A`, `git commit`) |
| **Push** | 1 | 1 (staging) vagy 2 (production: commit + tag) |
| **Tag/release** | 0 | 3 (production: `git tag`, `git push tag`, `gh release create`) |
| **Összes git művelet** | 10 | 9 (staging) vagy 13 (production) |

### Hálózati oda-vissza utak publikálásonként

| Fázis | Korábbi | Jelenlegi |
|-------|---------|-----------|
| **SSH keyscan** | 1 | 0 (HTTPS + App tokent használ) |
| **Clone** | 1 | 1 |
| **Push commit** | 1 | 1 |
| **Push tag** | 0 | 1 (csak production) |
| **Tag ellenőrzés remote-on** | 0 | 1 (csak production) |
| **Release létrehozás** | 0 | 1 (csak production, `gh release create`) |
| **Artifact feltöltés** | 0 | 1 (payload artifact) |
| **Artifact letöltés** | 0 | 1 (publish job letölti a payload-ot) |
| **Token generálás** | 0 | 1 (GitHub App token kiállítás) |
| **Összesen (staging)** | 3 | 5 |
| **Összesen (production)** | 3 | 8 |

### Másolás/szinkronizáció teljesítmény

| Metrika | Korábbi | Jelenlegi |
|---------|---------|-----------|
| **Módszer** | `cp -ra` (teljes rekurzív másolás) | `rsync --delete` (differenciális szinkronizáció) |
| **Előzetes ellenőrzés** | Nincs | `rsync -n` dry-run + törlés számlálás |
| **Első publikálás** | Egyenértékű sebesség | Egyenértékű sebesség |
| **Későbbi publikálások** | Teljes másolás minden alkalommal | rsync csak a módosult fájlokat továbbítja |
| **Nagy modul (100+ fájl, kevés változás)** | Mind a 100+ fájlt másolja | Csak a módosult fájlokat továbbítja |
| **Tiltott fájlok kezelése** | Nincs (mindent másol) | `find + delete` söprés másolás után |

### Validációs overhead (csak jelenlegi)

| Lépés | Becsült idő | Kihagyható? |
|-------|-------------|-------------|
| `terraform fmt -check -recursive` | 1-3mp | Nem |
| `terraform init -backend=false` | 5-15mp (provider letöltés) | Nem |
| `terraform validate` | 1-3mp | Nem |
| `tflint --init` + `tflint` | 3-10mp | Igen (`SKIP_TFLINT=true`) |
| `terraform test` | 10-60mp (ha vannak tesztek) | Igen (alapértelmezetten kikapcsolva) |
| **Összes validációs overhead** | ~10-30mp jellemzően | Korábbinál 0mp (nincs validáció) |

### Végponttól végpontig becsült időzítés (egyetlen modul)

| Fázis | Korábbi | Jelenlegi (staging) | Jelenlegi (production) |
|-------|---------|---------------------|------------------------|
| **Runner/konténer indítás** | 15-30mp (Docker build) | 5-10mp (runner allokáció) | 5-10mp |
| **Checkout** | 0mp (az action-ön belül fut) | 3-5mp | 3-5mp |
| **Eszköz beállítás** | 0mp (Docker-be sütve) | 10-15mp (Terraform + TFLint) | 10-15mp |
| **Modulok felismerése** | N/A (beégetett) | 2-5mp | 2-5mp |
| **Payload építés** | 1-3mp (`cp -ra`) | 2-5mp (lapítás + másolás + szűrés) | 2-5mp |
| **Validáció** | 0mp (nincs) | 10-30mp | 10-30mp |
| **Artifact feltöltés/letöltés** | 0mp | 5-15mp | 5-15mp |
| **Tanúsítás** | 0mp | 3-5mp | 3-5mp |
| **App token generálás** | 0mp | 2-3mp | 2-3mp |
| **Cél clone** | 3-5mp | 3-5mp | 3-5mp |
| **Szinkronizáció** | 1-3mp | 2-5mp | 2-5mp |
| **Push** | 3-5mp | 3-5mp | 3-5mp |
| **Tag + release** | 0mp | 0mp | 5-10mp |
| **Környezet jóváhagyás** | 0mp | 0mp | Manuális várakozás |
| **Összesen (jóváhagyás nélkül)** | ~25-50mp | ~50-110mp | ~55-120mp |

### Több modulos skálázás

| Modulok | Korábbi | Jelenlegi |
|---------|---------|-----------|
| **1 modul** | 1 workflow futás | 1 workflow futás (3 job) |
| **2 modul** | 2 külön workflow futás (szekvenciális vagy manuális) | 1 workflow futás, mátrix párhuzamosan (2x validáció, 2x publikálás) |
| **5 modul** | 5 külön futás | 1 workflow futás, mátrix párhuzamosan (5x validáció, 5x publikálás) |
| **Modul hozzáadása** | Új workflow fájl vagy mátrix szerkesztés | 1 JSON bejegyzés a manifestben |
| **Skálázási minta** | Lineáris: N modul = N workflow konfig | Konstans: N modul = 1 workflow, N mátrix bejegyzés |

### Erőforrás-felhasználás

| Erőforrás | Korábbi | Jelenlegi |
|-----------|---------|-----------|
| **Docker image tárolás** | ~110-160 MB futásonként (első után gyorsítótárazott) | 0 (natív runner) |
| **Artifact tárolás** | 0 | Payload artifact modulonként (7 napos megőrzés) |
| **Titkok** | 1 PAT (megosztva az összes repó között) | 2 titok környezetenként (App ID + kulcs) |
| **GitHub API hívások** | 0 | 3-6 publikálásonként (token kiállítás, tanúsítás, release) |
| **Runner percek** | ~1 perc modulonként | ~2 perc modulonként (validációval együtt) |

### Kompromisszumok összefoglalása

| | Korábbi nyer | Jelenlegi nyer |
|---|-------------|----------------|
| **Sebesség (egyetlen modul, validáció nélkül)** | Gyorsabb ~30-60mp-cel (nincs validáció, nincs artifact oda-vissza) | |
| **Sebesség (több modul)** | | Mátrix párhuzamosság, egyetlen workflow futás |
| **Későbbi szinkronizációk (nagy repók)** | | rsync differenciális átvitel |
| **Hidegindítás** | | Nincs Docker build overhead |
| **Üzemeltetési költség** | Kevesebb API hívás, kevesebb tárolás | |
| **Biztonsági költség** | | Validáció elkapja a hibákat publikálás előtt |
| **Skálázási költség** | | Nulla konfigurációs modul hozzáadások |

> **Lényeg**: A jelenlegi pipeline modulonként ~30-60 másodperccel többet vesz igénybe a korábbi action-höz képest, ami szinte teljes egészében a validációból és az artifact kezelésből adódik. Ez a hibás Terraform production-be jutásának megakadályozásának ára. Több modulos publikálásoknál a mátrix párhuzamosság ennek az overhead-nek a nagy részét visszanyeri.
