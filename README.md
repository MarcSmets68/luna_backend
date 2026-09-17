# Luna Backend (OpenEdge 12.8 / PASOE)

## Layout
```
Backend/
├── src/                  ABL source (WebHandlers, Business Entities, ProDataSets)
│   └── Luna/
│       ├── Web/
│       │   ├── TestHandler.cls        Smoke-test WebHandler (GET /web/test)
│       │   ├── LakproductieHandler.cls "Lakproduktie" overview (GET /web/lakproduktie) + create bestelling (POST /web/lakproduktie/bestelling)
│       │   ├── ArtikelHandler.cls     CRUD for `artikel` (GET/POST/PUT/DELETE /web/artikel[/{artnr}])
│       │   ├── KlantHandler.cls       CRUD for `klant` (GET/POST/PUT/DELETE /web/klant[/{klnr}])
│       │   ├── OfferteHandler.cls     CRUD for `offerte` (GET/POST/PUT/DELETE /web/offerte[/{offnr}/{versie}], offnr/versie auto-allocation on create), plus nested CRUD for `offlijn` (.../lijn[/{lijnnr}], lijnnr auto-allocation on create) and POST .../lijn/{lijnnr}/reorder
│       │   ├── BonHandler.cls         CRUD for `bon` (GET/POST/PUT/DELETE /web/bon[/{bonnr}]), plus nested CRUD for `bonlijn` (.../lijn[/{lijnnr}])
│       │   ├── FactuurHandler.cls     CRUD for `factuur` (GET/POST/PUT/DELETE /web/factuur[/{facnr}]), plus nested CRUD for `faclijn` (.../lijn[/{lijnnr}]) and `fac_led` (.../lijn/{lijnnr}/led[/{groepnr}/{ledLijn}])
│       │   ├── DashboardHandler.cls   Read-only dashboard summary (GET /web/dashboard)
│       │   ├── BestelorderHandler.cls Read-only for `order` (GET /web/bestelorder[/{ordnr}]), plus nested read-only `ordlijn` (.../{ordnr}/lijn)
│       │   ├── DevUsersHandler.cls    DEV/DEBUG ONLY - read-only flat list of `gebruiker` (GET /web/dev-users), Password never returned - do not extend/wire into auth
│       │   ├── LeverancierHandler.cls CRUD for `lever` (GET/POST/PUT/DELETE /web/leverancier[/{levnr}])
│       │   ├── LoginHandler.cls       Auth-MVP login (POST /web/login) - see "Auth-MVP (login/logout)" section below
│       │   ├── LogoutHandler.cls      Auth-MVP logout (POST /web/logout, X-Auth-Token header) - see "Auth-MVP (login/logout)" section below
│       │   ├── AiSearchHandler.cls    AI-powered natural-language search (POST /web/ai-search) - see "AI Search" section below
│       │   └── PricingHandler.cls     Iteratie A pricing engine (POST /web/pricing/bereken) - see "Pricing engine (Iteratie A, K1-K5)" section below
│       └── BusinessLogic/
│           ├── LakproductieBE.cls          1:1 port of legacy ExportLakProductie.w (3 sources: lopende-orders / lopende-productielijnen / min-max-voorraad)
│           ├── LakproductieVerkoopService.cls  Rolling 1/3/6/9/12-month verkoop totals per artnr, shared by LakproductieBE
│           ├── LakproductieCacheService.cls  On-disk cache for the Lakproduktie overview (see "Lakproduktie-cache" section below), refreshed every 5 minutes by scripts/RefreshLakproductieCache.ps1
│           ├── LakproductieBestellingBE.cls  Creates a purchase order (`order`+`ordlijn`) from a confirmed Lakproduktie bestelling-preview, bumps bonlijn/bonlijn_productie.besteld
│           ├── ArtikelBE.cls          DB access + validation for artikel CRUD (+ Fase 1 voorraad-verrijking, see design doc)
│           ├── StockAvailabilityBE.cls  Fase 1/FR-4: on-demand composiet-beschikbaarheid over `artlijn` (GET /web/artikel/{artnr}/beschikbaarheid)
│           ├── ArtlogBE.cls           Fase 1/FR-5: paged/filtered `artlog` movement history (GET /web/artikel/{artnr}/artlog)
│           ├── KlantBE.cls            DB access + validation for klant CRUD
│           ├── OfferteBE.cls          DB access + validation for offerte CRUD (cascades delete to offlijn)
│           ├── OfflijnBE.cls          DB access + validation for offlijn (offerte line) CRUD
│           ├── BonBE.cls              DB access + validation for bon CRUD
│           ├── BonLijnBE.cls          DB access + validation for bonlijn (order line) CRUD (no cascade delete)
│           ├── FactuurBE.cls          DB access + validation for factuur CRUD (cascades delete to faclijn/fac_led)
│           ├── FacLijnBE.cls          DB access + validation for faclijn (invoice line) CRUD (cascades delete to fac_led)
│           ├── FacLedBE.cls           DB access + validation for fac_led (LED-configuration detail) CRUD
│           ├── DashboardBE.cls        DB access for the dashboard summary (read-only)
│           ├── BestelorderBE.cls      DB access for `order` (purchase orders to suppliers, read-only)
│           ├── OrdlijnBE.cls          DB access for `ordlijn` (purchase order lines, read-only, child of BestelorderBE)
│           ├── DevUsersBE.cls         DEV/DEBUG ONLY - DB access for `gebruiker` (read-only, Password never referenced)
│           ├── LeverancierBE.cls      DB access + validation for lever (supplier) CRUD
│           ├── AuthBE.cls             Auth-MVP login/logout/session validation - see "Auth-MVP (login/logout)" section below
│           ├── AiSearchBE.cls         AI-search orchestration + hardcoded entity/field/operator whitelist - see "AI Search" section below
│           ├── GeminiGateway.cls      Thin wrapper around the Google Gemini REST API, used only by AiSearchBE - see "AI Search" section below
│           └── PricingEngineBE.cls    Iteratie A pure read-only pricing engine (K1-K5) - 1:1 port of legacy Include/Prijs.i - see "Pricing engine (Iteratie A, K1-K5)" section below
├── build/                Compiled r-code (generated, not source of truth - safe to delete/regenerate)
├── scripts/
│   ├── compile.p         CLI compile-all procedure
│   ├── compile.ps1       Wrapper: run this after every backend change
│   ├── RefreshLakproductieCache.p    Batch entry point - refreshes the Lakproduktie cache file (see "Lakproduktie-cache" section below)
│   ├── RefreshLakproductieCache.ps1  Wrapper, meant to be run every 5 minutes by a Windows Scheduled Task
│   ├── Luna-RefreshLakproductieCache-task.xml  Scheduled Task definition for the above (import manually - see below)
│   ├── SeedTestPasswords.p    Batch entry point - sets gebruiker.Password to a shared test password on every row (see "Auth-MVP (login/logout)" section below)
│   ├── SeedTestPasswords.ps1  Wrapper - requires an explicit -Confirm switch, never run automatically
│   ├── SeedTestNiveaus.p      Batch entry point - sets gebruiker.niveau on a small NAMED list of test users only (ABNA -> 5, MS -> 9, JS -> 9; see "Auth-MVP (login/logout)" section below) - not a bulk/random reassignment
│   └── SeedTestNiveaus.ps1    Wrapper - requires an explicit -Confirm switch, never run automatically
└── bruno/                Bruno collection - import this folder directly in Bruno
```

Follow the architecture rule from the root `AGENTS.md`: WebHandlers stay thin
(routing/parsing/response shaping only); all business logic and DB access
belongs in Business Entities via ProDataSets.

## PASOE instance
This backend runs against the existing PASOE instance `MarcTest`
(`C:\OpenEdge\MarcOepas`, Tomcat ports 8080/8443). Its `openedge.properties`
has been extended with:
- `[AppServer.Agent.MarcTest] PROPATH` — includes `Backend/build` (compiled
  r-code, checked first) and `Backend/src` (source, PASOE dev-mode fallback).
- `[AppServer.SessMgr.MarcTest] agentStartupParam` — adds
  `-db LunaNew -H lhdc01 -S 4500 -N TCP -U ABNA` so every agent connects to
  the shared LunaNew test database on `lhdc01` (user `ABNA`, no password) on
  startup. This is the same broker the legacy frontend UI tests against -
  **never start, stop, or reconfigure the broker itself, and never touch
  anything else on lhdc01**; this backend only ever connects to it as an
  ordinary network client, same as any other Progress client. As of the
  codepage fix below, this same line also carries `-cpinternal UTF-8
  -cpstream UTF-8`.

### Session codepage (`-cpinternal`/`-cpstream` UTF-8)
Before this fix, sending a non-ASCII character (e.g. `é`) in a JSON request
body to any WebHandler (e.g. `POST /web/leverancier`) crashed the ABL session
mid-request and PASOE returned a raw HTML 500 page instead of JSON. Root
cause: the agent session had no explicit internal/stream codepage, so it
defaulted to a codepage that couldn't represent the incoming UTF-8 bytes.
Fix: appended `-cpinternal UTF-8 -cpstream UTF-8` to `agentStartupParam` in
`[AppServer.SessMgr.MarcTest]` (`C:\OpenEdge\MarcOepas\conf\openedge.properties`,
outside this workspace) and restarted PASOE. Verified end-to-end: characters
representable in the `LunaNew` database's own codepage (`iso8859-1` — e.g.
`é`, `ü`, `ñ`) now write and read back correctly as clean JSON, with no more
500s. Existing ASCII data (spot-checked via `GET /web/leverancier/1` and
`GET /web/klant/1`) is unaffected/uncorrupted.

**Known residual limitation, not fixed by this change**: `LunaNew`'s
database codepage is `iso8859-1`, which has no code point for the Euro sign
(`€`, U+20AC) at all — no agent-side session codepage setting can make the
database store a character outside its own codepage's repertoire. A `€`
sent in a request body is silently substituted with `?` on write (no error,
no corruption of other data, just that one character lost). Fixing this for
real would require changing `LunaNew`'s database codepage itself, which is a
schema/DB-admin-level change outside this ticket's approved scope — flagging
as a separate follow-up if Euro-sign support in free-text fields is
required.
- `[MarcTest.ROOT.WEB] handler1=Luna.Web.TestHandler: /test` — maps
  `GET /web/test` to the smoke-test WebHandler.
- `handler3=Luna.Web.ArtikelHandler: /artikel` — maps `/web/artikel` (and,
  via the implicit trailing wildcard, `/web/artikel/{artnr}`) to the artikel
  CRUD WebHandler.
- `handler4=Luna.Web.KlantHandler: /klant` — maps `/web/klant` (and, via the
  implicit trailing wildcard, `/web/klant/{klnr}`) to the klant CRUD
  WebHandler.
- `handler5=Luna.Web.OfferteHandler: /offerte` — maps `/web/offerte` (and,
  via the implicit trailing wildcard, `/web/offerte/{offnr}/{versie}` and
  `/web/offerte/{offnr}/{versie}/lijn[/{lijnnr}]`) to the offerte + offlijn
  CRUD WebHandler.
- `handler6=Luna.Web.BonHandler: /bon` — maps `/web/bon` (and, via the
  implicit trailing wildcard, `/web/bon/{bonnr}`) to the bon CRUD
  WebHandler.
- `handler7=Luna.Web.FactuurHandler: /factuur` — maps `/web/factuur` (and,
  via the implicit trailing wildcard, `/web/factuur/{facnr}`,
  `/web/factuur/{facnr}/lijn[/{lijnnr}]` and
  `/web/factuur/{facnr}/lijn/{lijnnr}/led[/{groepnr}/{ledLijn}]`) to the
  factuur + faclijn + fac_led CRUD WebHandler. Added to the actual
  `openedge.properties` at `C:\OpenEdge\MarcOepas\conf` (outside this
  workspace) and the PASOE instance has been restarted to pick it up. No
  further mapping changes were needed to add faclijn/fac_led CRUD - same
  approach as offerte/offlijn (handler5): nested resources are routed to
  the same handler via the mount point's implicit trailing wildcard.
- `handler8=Luna.Web.DashboardHandler: /dashboard` — maps `/web/dashboard`
  to the dashboard summary WebHandler. Added to the actual
  `openedge.properties` at `C:\OpenEdge\MarcOepas\conf` (outside this
  workspace) and the PASOE instance has been restarted to pick it up.
- `handler9=Luna.Web.BestelorderHandler: /bestelorder` — maps
  `/web/bestelorder` (and, via the implicit trailing wildcard,
  `/web/bestelorder/{ordnr}`) to the read-only bestelorder (purchase
  order) WebHandler. Add this to the actual `openedge.properties` at
  `C:\OpenEdge\MarcOepas\conf` (outside this workspace) and restart the
  PASOE instance to pick it up.
- `handler10=Luna.Web.DevUsersHandler: /dev-users` — maps `/web/dev-users`
  to a DEV/DEBUG-only WebHandler that returns a flat list of `gebruiker`
  rows (kode/naam/email/niveau/passief - `Password` is never read or
  returned, see `Luna.BusinessLogic.DevUsersBE` class header) for backend
  connectivity verification. Deliberately namespaced under `dev-users`, not
  `users`, so it's obviously not a production user-management endpoint - do
  not extend it with create/update/delete or wire it into auth. Added to
  the actual `openedge.properties` at `C:\OpenEdge\MarcOepas\conf` (outside
  this workspace) and the PASOE instance has been restarted to pick it up.
- `handler11=Luna.Web.LeverancierHandler: /leverancier` — maps
  `/web/leverancier` (and, via the implicit trailing wildcard,
  `/web/leverancier/{levnr}`) to the leverancier (supplier) CRUD
  WebHandler. Added to the actual `openedge.properties` at
  `C:\OpenEdge\MarcOepas\conf` (outside this workspace) and the PASOE
  instance has been restarted to pick it up.
- `handler12=Luna.Web.LoginHandler: /login` — maps `POST /web/login` to
  the Auth-MVP login WebHandler. Added to the actual `openedge.properties`
  at `C:\OpenEdge\MarcOepas\conf` (outside this workspace) and the PASOE
  instance has been restarted to pick it up.
- `handler13=Luna.Web.LogoutHandler: /logout` — maps `POST /web/logout`
  to the Auth-MVP logout WebHandler. Same as handler12 above - added to
  the actual `openedge.properties` and PASOE restarted.
- `handler14=Luna.Web.AiSearchHandler: /ai-search` — maps
  `POST /web/ai-search` to the AI-powered natural-language search
  WebHandler (see "AI Search" section below). Added to the actual
  `openedge.properties` at `C:\OpenEdge\MarcOepas\conf` (outside this
  workspace) and the PASOE instance has been restarted to pick it up.
- `POST /web/lakproduktie/bestelling` (create a purchase order from a
  Lakproduktie bestelling-preview, see `Luna.BusinessLogic.LakproductieBestellingBE`)
  needed no `openedge.properties` change - it's routed to the same
  `Luna.Web.LakproductieHandler` mapping already in place for
  `GET /web/lakproduktie`, via that mount point's implicit trailing
  wildcard (same approach as handler5/handler7 above).
- Several other feature branches added `handler15`..`handler25` directly
  to the live `openedge.properties` (rapportage, LED reference-data
  endpoints, pakbon) ahead of this README being updated for them - not
  documented here, see the live file at `C:\OpenEdge\MarcOepas\conf` for
  the current full list. `handler26=Luna.Web.PricingHandler: /pricing` —
  maps `POST /web/pricing/bereken` to the pricing-engine WebHandler (see
  "Pricing engine (Iteratie A, K1-K5)" section below). Added to the actual
  `openedge.properties` at `C:\OpenEdge\MarcOepas\conf` (outside this
  workspace) and the PASOE instance has been restarted to pick it up.

Restart the instance after changing `openedge.properties`:
```powershell
$env:DLC = "C:\Progress\OpenEdge"
& "C:\OpenEdge\MarcOepas\bin\tcman.bat" stop
& "C:\OpenEdge\MarcOepas\bin\tcman.bat" start
```

## Database
PASOE agents connect to the shared `LunaNew` test database on `lhdc01:4500`
(client/server, `-N TCP`, user `ABNA`, no password) — the same broker the
legacy frontend UI uses to test against. That broker is owned and operated
on lhdc01; **this backend only ever connects to it as a client and must
never start, stop, or change any configuration on lhdc01.** There's nothing
to start locally for this — just confirm the port is reachable:
```powershell
Test-NetConnection -ComputerName lhdc01 -Port 4500
```

### Local fallback copy (optional, dev-only)
A local copy of the database lives in `Databases/` and can be run as its
own broker on `localhost:3050` for offline development. It is **not** used
by default — `agentStartupParam` above points at lhdc01, so switching to
this fallback also requires pointing `agentStartupParam` back at
`-H localhost -S 3050` and restarting PASOE.
```powershell
$env:DLC = "C:\Progress\OpenEdge"
& "$env:DLC\bin\proserve.bat" "C:\LunaWEB - workspace\Databases\LunaNew" -H localhost -S 3050 -N TCP -minport 20000 -maxport 20050
```
Note: the local copy's `.st` structure file originally pointed at the old
network-share path (`F:\Shares\TestLuna\Databases`, now `T:\`). It has been
repaired with `prostrct repair` to point at the local `Databases/` files —
if you ever refresh this copy from the network share, you'll likely need to
repair it again the same way.

Shut down with:
```powershell
& "$env:DLC\bin\proshut.bat" "C:\LunaWEB - workspace\Databases\LunaNew" -by
```

## Compiling (CLI workflow — no PDSOE/Eclipse)
```powershell
$env:DLC = "C:\Progress\OpenEdge"
powershell -File "Backend\scripts\compile.ps1"
```
This compiles everything under `src/` into `build/`, matching the package
structure. Run it after every meaningful change, before restarting PASOE.

## Testing the endpoint
- Browser: http://localhost:8080/web/test
- Bruno: open Bruno → "Open Collection" → select `Backend/bruno` → pick the
  `Local` environment → run "Test Endpoint".

Expected response:
```json
{
  "status": "ok",
  "message": "Luna backend test endpoint is up",
  "database": "LunaNew",
  "databaseConnected": true,
  "timestamp": "..."
}
```
`databaseConnected` reflects whether the ABL session serving the request is
connected to LunaNew — a `false` here usually means the DB broker isn't
running or the agent needs a restart to pick up `agentStartupParam`.

## Lakproduktie-cache
`GET /web/lakproduktie` (`Luna.Web.LakproductieHandler`) used to recompute
the full overview live on every request via
`Luna.BusinessLogic.LakproductieBE:GetOpenLakproductieItems()`, which takes
up to ~1 minute. It's now served from an on-disk cache
(`Luna.BusinessLogic.LakproductieCacheService`), refreshed every 5 minutes
by a standalone scheduled job — so a normal page load reads a small JSON
file instead of waiting on the live query.

- **Cache file**: `Backend/cache/lakproductie-cache.json` (gitignored —
  generated at runtime, not source of truth). One shared file for every
  user; `GET /web/lakproduktie` returns the same data for everyone today
  (no user-specific filtering server-side), so a single cache is enough.
- **Refresh mechanism**: `Backend/scripts/RefreshLakproductieCache.p` is a
  standalone ABL batch client (run via `_progres -b`, same pattern as
  `compile.ps1`) that calls
  `LakproductieCacheService:RefreshCache()`, which recomputes the overview
  live and writes it to the cache file **atomically** (first to a `.tmp`
  file, then `OS-RENAME`d over the real cache file), so
  `GET /web/lakproduktie` never observes a half-written file.
  `Backend/scripts/RefreshLakproductieCache.ps1` wraps that: it sets
  `PROPATH`/`DLC` and connects to the same `LunaNew` database the PASOE
  agents use (see "PASOE instance" above), same way any other client
  would — it never touches PASOE itself. This runs as its own ABL session,
  independent of the PASOE web agents, so a refresh never competes with or
  slows down normal request handling.
- **Scheduling**: `Backend/scripts/Luna-RefreshLakproductieCache-task.xml`
  is a Windows Scheduled Task definition (same style as
  `Luna-StartDbAndPasoe-task.xml`) that runs
  `RefreshLakproductieCache.ps1` every 5 minutes. Import it on the machine
  that runs PASOE:
  ```powershell
  schtasks /create /xml "C:\LunaWEB - workspace\Backend\scripts\Luna-RefreshLakproductieCache-task.xml" /tn "Luna-RefreshLakproductieCache"
  ```
  (or import via the Task Scheduler UI: Action → Import Task...). This is
  a machine-level change, not something a repo checkout does for you.
- **Cold start / self-healing**: if the cache file doesn't exist yet (a
  fresh deploy, before the first scheduled run), `LakproductieHandler`
  still works — `LakproductieCacheService:GetItems()` falls back to a live
  recompute (paying the ~1 minute cost once) and writes the result to the
  cache file itself, so every request after that is fast again until the
  next scheduled refresh. The same fallback applies if the cache file is
  ever unreadable/corrupt.
- **Failure handling**: if a scheduled refresh fails (e.g. the DB is
  briefly unreachable), the error is appended to
  `Backend/cache/lakproductie-cache-refresh.log` and the existing cache
  file is left untouched — requests keep serving the last good snapshot
  rather than failing. There's no active alerting on this log in this
  scope; check it manually if data looks stale for longer than expected.
- **Staleness**: data can be up to ~5 minutes old (longer only if a
  scheduled refresh fails) — an accepted tradeoff for this feature, not a
  bug.

## Artikel CRUD (`/web/artikel`)
Full CRUD over a curated core subset of the `artikel` table (~120 fields in
total; only identification, description, pricing, stock, supplier and
classification fields are exposed for now). See
`Luna.BusinessLogic.ArtikelBE` for the JSON-key-to-column field map.

| Method | Path                    | Purpose                              |
|--------|-------------------------|---------------------------------------|
| GET    | `/web/artikel`          | List, paged. Query params: `artnr` (prefix), `omschrijving` (substring on NL/FR), `groep` (exact), `onderMinimum` (`intern`/`extern`/`beide`, see below), `externInBewerking` (`true`/`false`), `page` (default 1), `pageSize` (default 25, max 200) |
| GET    | `/web/artikel/{artnr}`  | Get one. 404 if not found. |
| POST   | `/web/artikel`          | Create. Body must include `artnr`. 409 if it already exists. |
| PUT    | `/web/artikel/{artnr}`  | Update. Partial - only fields present in the body are changed. 404 if not found. |
| DELETE | `/web/artikel/{artnr}`  | Delete. 404 if not found. |
| GET    | `/web/artikel/{artnr}/beschikbaarheid` | Fase 1/FR-4: on-demand composiet-beschikbaarheid ("hoeveel kan ik nog bouwen?"), see `Luna.BusinessLogic.StockAvailabilityBE`. 404 if `artnr` doesn't exist; a 200 with `isSamengesteld: false` and an empty `componenten` array for a non-composite artikel (not a 404). |
| GET    | `/web/artikel/{artnr}/artlog` | Fase 1/FR-5: paged/filtered `artlog` movement history, see `Luna.BusinessLogic.ArtlogBE`. Query params: `page`, `pageSize`, `datumVan`, `datumTot` (`YYYY-MM-DD`), `beweging` (raw code, unmapped - see BR-3 note below). 404 if `artnr` doesn't exist; an empty `items` array if it has no `artlog` rows. |

Errors are returned as `{"error": {"message": "...", "code": <status>}}`.

### Fase 1 voorraad-verrijking (`docs/architecture/voorraad-fase1-ontwerp.md`)
Every list/detail row now also carries: `voorraadExtern` (`x-aantal`),
`gereserveerd`, `gereserveerdExtern` (`x-gereserveerd`), `beschikbaar`
(`aantal - gereserveerd`), `beschikbaarExtern` (`x-aantal - x-gereserveerd`),
`onderMinimumIntern`/`onderMinimumExtern` (computed booleans, always `false`
when `stock = false`), `magazijn`, `voorraadMinExtern`/`voorraadMaxExtern`
(`x-minv`/`x-maxv`), `swExtern`, `swExProductie` and `isSamengesteld`
(`EXISTS(FIRST artlijn WHERE artlijn.artnr = artikel.artnr)`, not
`artikel.swMaster` - see design doc OD-3).

`onderMinimum` (`intern`/`extern`/`beide`) and `externInBewerking` are
evaluated per-row on top of the existing `artnr`/`groep`/`omschrijving`
filters and are **not** index-backed - `onderMinimum`/`externInBewerking`
used alone (no `artnr`/`groep` narrowing) can scan a large portion of the
1.8M-row `artikel` table and take significantly longer than the normal
prefix-filtered list call. This is an accepted, documented trade-off (see
design doc §1.2.1), not a bug - always combine these filters with `artnr`/
`groep` in normal use.

`beweging` on `/artlog` is returned raw/unmapped (BR-3) - the exact code
list is not yet confirmed with Marc (see design doc §1.5/OV-1), do not
build translation logic against it without checking back.

**No exact `totalCount`:** `artikel` holds ~1.8M rows in this environment, so
computing an exact total on every list call would require a full table scan
and blow past PASOE's `requestWaitTimeout` (15s). The list response instead
returns `hasMore` (whether another page exists) and stops scanning as soon as
it has gathered one page + 1 row. `artnr`/`groep` filters use existing
indexes and narrow the scan quickly; an `omschrijving`-only filter still
scans every candidate row, so combine it with `groep`/`artnr` where possible.

Note: `artnr` values containing characters like `%` don't round-trip cleanly
through the PASOE path (Tomcat rejects some percent-encoded path segments as
malformed) - this is a transport-level limitation, not specific to this
handler. Prefer the `artnr` query filter on the list endpoint to look up
such records if this becomes an issue.

## Klant CRUD (`/web/klant`)
Full CRUD over a curated core subset of the `klant` (customer) table (~50
fields in total; only identification, contact, address, financial and
status fields are exposed for now). See `Luna.BusinessLogic.KlantBE` for the
JSON-key-to-column field map.

| Method | Path                | Purpose                              |
|--------|---------------------|---------------------------------------|
| GET    | `/web/klant`        | List, paged. Query params: `naam` (space-separated words, case-insensitive - every word must occur somewhere across naam+naam1, in any order, e.g. "Smets Marc" matches naam "Smets"/naam1 "Marc"), `page` (default 1), `pageSize` (default 25, max 200) |
| GET    | `/web/klant/{klnr}` | Get one. 400 if `klnr` is non-numeric. 404 if not found. |
| POST   | `/web/klant`        | Create. Body must include `klnr` (positive integer). 409 if it already exists. |
| PUT    | `/web/klant/{klnr}` | Update. Partial - only fields present in the body are changed. 400 if `klnr` is non-numeric, 404 if not found. |
| DELETE | `/web/klant/{klnr}` | Delete. 400 if `klnr` is non-numeric. 404 if not found. |

Errors are returned as `{"error": {"message": "...", "code": <status>}}`.

Same pagination approach as `/web/artikel`: no exact `totalCount`, the list
response returns `hasMore` and stops scanning as soon as it has gathered one
page + 1 row. There is no index on `naam`/`naam1`, so a `naam` filter scans
every klant row (same tradeoff as the `naam` filter on `/web/factuur`).

**Fixed regression:** the single-get/update/delete `{klnr}` path-segment
validation used the `INTEGER(...) NO-ERROR` + `EQ ?` pattern, which on this
OpenEdge version doesn't detect a failed conversion - `INTEGER()` failing
leaves the target variable at its default (`0`), not the unknown value (`?`).
`GET/PUT/DELETE /web/klant/abc` therefore fell through to "not found" and
returned `404` instead of the documented `400`. Fixed by also checking
`ERROR-STATUS:ERROR` right after the `INTEGER()` call, matching the pattern
already used correctly elsewhere in this file (e.g. `/web/bon`) - confirmed
live, `GET /web/klant/abc` now correctly returns `400` ("Invalid klnr abc").

## Leverancier CRUD (`/web/leverancier`)
Full CRUD over a curated core subset of the `lever` (supplier) table (only
identification, contact, address, financial and status fields are exposed
for now). See `Luna.BusinessLogic.LeverancierBE` for the JSON-key-to-column
field map.

| Method | Path                     | Purpose                              |
|--------|--------------------------|---------------------------------------|
| GET    | `/web/leverancier`         | List, paged. Query params: `naam` (space-separated words, case-insensitive - every word must occur somewhere across naam+naam1, in any order, e.g. "Smets Marc" matches naam "Smets"/naam1 "Marc"), `page` (default 1), `pageSize` (default 25, max 200) |
| GET    | `/web/leverancier/{levnr}` | Get one. 400 if `levnr` is non-numeric. 404 if not found. |
| POST   | `/web/leverancier`         | Create. `levnr` is generated server-side (last existing `levnr` + 1, first row gets `1`) - any `levnr` in the body is ignored, not required, never rejected. |
| PUT    | `/web/leverancier/{levnr}` | Update. Partial - only fields present in the body are changed. 400 if `levnr` is non-numeric, 404 if not found. |
| DELETE | `/web/leverancier/{levnr}` | Delete. 400 if `levnr` is non-numeric. 404 if not found. |

Errors are returned as `{"error": {"message": "...", "code": <status>}}`.

Same pagination approach as `/web/klant`: no exact `totalCount`, the list
response returns `hasMore` and stops scanning as soon as it has gathered one
page + 1 row. There is no index on `naam`/`naam1`, so a `naam` filter scans
every lever row (same tradeoff as the `naam` filter on `/web/klant`). `type`
and `controle` are raw booleans on `lever` (no semantic label translation,
unlike `klant.geblokkeerd`) - passed straight through as JSON `true`/`false`.

**`levnr` auto-generation:** `LeverancierBE:CreateLeverancier` computes the
next `levnr` server-side, mirroring `BonBE:CreateBon` - inside the same
`DO TRANSACTION` as the `CREATE`, it does
`FIND LAST lever USE-INDEX lever-x1 EXCLUSIVE-LOCK` then
`iNewLevnr = (IF AVAILABLE lever THEN lever.levnr ELSE 0) + 1`. There is
deliberately no retry loop/`Progress.Lang.Error` catch for the
FIND-LAST/CREATE race, same tradeoff already accepted for `/web/bon`.

**Fixed regression:** the single-get/update/delete `{levnr}` path-segment
validation used the `INTEGER(...) NO-ERROR` + `EQ ?` pattern, which on this
OpenEdge version doesn't detect a failed conversion - `INTEGER()` failing
leaves the target variable at its default (`0`), not the unknown value (`?`).
`GET/PUT/DELETE /web/leverancier/abc` therefore fell through to "not found"
and returned `404` instead of the documented `400`. Fixed by also checking
`ERROR-STATUS:ERROR` right after the `INTEGER()` call, matching the pattern
already used correctly elsewhere in this file (e.g. `/web/bon`) - confirmed
live, `GET /web/leverancier/abc` now correctly returns `400` ("Invalid levnr
abc").

**Fixed regression (raw 500 on POST/PUT with a malformed JSON body,
e.g. a leading UTF-8 BOM):** every write-capable WebHandler
(`ArtikelHandler`, `BonHandler`, `FactuurHandler`, `KlantHandler`,
`LakproductieHandler`, `LeverancierHandler`, `OfferteHandler`) shares an
identical `GetJsonBody()` helper that lazily triggers PASOE's own
request-body-to-`JsonObject` deserialization the first time it reads
`poRequest:Entity`. If the raw body isn't valid JSON - most commonly
because some HTTP client/tool prepended a UTF-8 byte-order-mark (BOM)
before the `{` - that lazy deserialization throws a plain
`Progress.Json.ObjectModel`/ABL parser error (message 16068,
"Json Parser Error ... lexical error: invalid char in json text"), **not**
a `Progress.Lang.AppError`. Every `HandlePost`/`HandlePut` method only ever
caught `Progress.Lang.AppError`, so this error escaped uncaught, past our
code entirely, straight into PASOE's generic framework error handler -
which returns a raw `500` (an HTML error page, or, with
`Accept: application/json`, a JSON envelope with the
`exception_class`/`exception_message`/`exception_stack_trace` fields all
empty, since the framework never got a real ABL exception object to
describe). This reproduced 100% of the time for any client that
consistently sent a BOM'd body (e.g. a body written to a temp file via a
tool whose default text encoding includes a BOM, then posted from that
file) and affected **every** write endpoint identically, not just
`/web/leverancier` and `/web/klant` - it was never a PASOE
restart/agent-pool issue and never specific to the `levnr`-path-parsing
fix above. Confirmed via `C:\OpenEdge\MarcOepas\logs\MarcTest.agent.*.log`,
which logged `[OE.W.InternalWebRouter ERROR] Request error for POST
/web/leverancier: status code 500` immediately followed by
`Json Parser Error at offset 1: lexical error: invalid char in json
text.. (16068)` for the exact request. Fixed by having `GetJsonBody()`
wrap the `poRequest:Entity` access in its own `CATCH oError AS
Progress.Lang.Error` block: `Progress.Lang.AppError`s (e.g. the existing
"body must be a JSON object" check) are re-thrown as-is, and anything else
(the JSON parser error case) is converted into a clean `AppError` 400
("Malformed JSON request body: ..."), which the existing
`CATCH oAppError AS Progress.Lang.AppError` in every `HandlePost`/
`HandlePut` already maps to the documented
`{"error": {"message": "...", "code": 400}}` response - confirmed live on
both `/web/leverancier` and `/web/klant` with a BOM'd body (now `400`, was
`500`), and confirmed a normal (non-BOM) `POST`/`PUT` on both endpoints
still returns `201`/`200` as documented.

## Offerte CRUD (`/web/offerte`)
Full CRUD over a curated core subset of the `offerte` (quote) table (~90
fields in total; only identification, customer, amount and status fields
are exposed for now). See `Luna.BusinessLogic.OfferteBE` for the
JSON-key-to-column field map.

| Method | Path                            | Purpose                              |
|--------|---------------------------------|---------------------------------------|
| GET    | `/web/offerte`                  | List, paged. Query params: `klnr` (exact), `offgroep` (exact), `offnr` (prefix match on the string form), `naam` (substring), `page` (default 1), `pageSize` (default 25, max 200). Newest `offnr`/`versie` first. |
| GET    | `/web/offerte/{offnr}/{versie}` | Get one. 404 if not found. |
| POST   | `/web/offerte`                  | Create. Either provide both `offnr` and `versie` (both positive integers, 409 if that combination already exists), or omit both for server auto-allocation (`offnr` = last `offnr` + 1, `versie` = 1). Providing exactly one of the two is 400. |
| PUT    | `/web/offerte/{offnr}/{versie}` | Update. Partial - only fields present in the body are changed. 404 if not found. Business rule: if the body is non-empty, `verloren` was previously `true`, and the body does not itself include a `verloren` key, `verloren` is auto-cleared to `false` (an explicit `verloren` key in the body always wins). |
| DELETE | `/web/offerte/{offnr}/{versie}` | Delete. Cascades to every `offlijn` row for this offnr+versie. 404 if not found. |

Errors are returned as `{"error": {"message": "...", "code": <status>}}`.

Same pagination approach as `/web/klant`: no exact `totalCount`, the list
response returns `hasMore` and stops scanning as soon as it has gathered one
page + 1 row. `klnr` uses the existing `offerte-x3` index and `offgroep`
uses `offerte-x2`; a `naam`-only filter scans every candidate row, so
combine it with `klnr`/`offgroep` where possible.

Note: each row is one `offerte` revision (`offnr` + `versie`) - the list
does not dedupe to "latest versie per offnr". This also applies when
filtering by `offnr`: it still returns every matching `versie` row for that
quote number.

`offnr`/`versie` auto-allocation (added for Offertebeheer Fase 1): when both
are omitted from the `POST /web/offerte` body, `OfferteBE:CreateOfferte`
computes `offnr` as `(last offerte.offnr, via the offerte-x1 index) + 1` and
`versie` as `1`, under the same `EXCLUSIVE-LOCK`/transaction as the
`CREATE` - same locking pattern as `Luna.BusinessLogic.BonBE:CreateBon`'s
`bonnr` allocation. The explicit-`offnr`+`versie` path is unchanged.

## Offlijn CRUD (`/web/offerte/{offnr}/{versie}/lijn`)
Full CRUD over a curated core subset of the `offlijn` (quote line) table
(~60 fields in total; only identification, article, quantity, pricing and
status fields are exposed for now). See `Luna.BusinessLogic.OfflijnBE` for
the JSON-key-to-column field map. `offlijn` is a child of `offerte` (linked
via `offnr`+`versie`), so every endpoint below is nested under its parent
offerte and every method 404s if that offnr+versie doesn't exist.

| Method | Path                                             | Purpose                              |
|--------|--------------------------------------------------|---------------------------------------|
| GET    | `/web/offerte/{offnr}/{versie}/lijn`              | List every line for this offerte, ordered by `lijnnr`. Not paged - a quote has a bounded number of lines. |
| GET    | `/web/offerte/{offnr}/{versie}/lijn/{lijnnr}`     | Get one. 404 if not found. |
| POST   | `/web/offerte/{offnr}/{versie}/lijn`              | Create. Provide `lijnnr` explicitly (positive integer, 409 if it already exists), or omit it for server auto-allocation (`MAX(lijnnr for this offerte, default 0) + 10`). 400 if more than one of `subtotaal`/`kolomtitel`/`infolijn` is `true`, or if `subtotaal: true` is requested with no preceding plain line (all three flags `false`) to sum. |
| PUT    | `/web/offerte/{offnr}/{versie}/lijn/{lijnnr}`     | Update. Partial - only fields present in the body are changed. 404 if not found. 400 if the resulting merged state (existing row + body) would leave more than one of `subtotaal`/`kolomtitel`/`infolijn` `true`. |
| DELETE | `/web/offerte/{offnr}/{versie}/lijn/{lijnnr}`     | Delete. 404 if not found. |
| POST   | `/web/offerte/{offnr}/{versie}/lijn/{lijnnr}/reorder` | Moves the line one position `up` or `down` (body: `{"direction": "up"|"down"}`) by swapping `lijnnr` with its immediate neighbor in that direction. 404 if the line or the neighbor doesn't exist. 400 if the swap would decrease a `subtotaal` line's `lijnnr` (moving a subtotaal line down/away from its group is allowed). Returns `200` with the full refreshed `{"items": [...]}` line list, ordered by `lijnnr` - see `Luna.BusinessLogic.OfflijnBE:ReorderOfflijn`. |

Errors are returned as `{"error": {"message": "...", "code": <status>}}`.
Deleting the parent offerte (`DELETE /web/offerte/{offnr}/{versie}`)
cascades to every line here - lines don't need to be deleted individually
first.

`lijnnr` auto-allocation and the `subtotaal`/`kolomtitel`/`infolijn`
structural guards, plus the `reorder` action, were added for Offertebeheer
Fase 1 (Create/Edit UI). `reorder` is routed through the same
`Luna.Web.OfferteHandler` mount point (no new `openedge.properties` entry
needed) - the handler only gained path-segment routing for the extra
`/reorder` suffix; all swap/guard logic lives in
`Luna.BusinessLogic.OfflijnBE`.

## Bon CRUD (`/web/bon`)
Full CRUD over a curated core subset of the `bon` (customer order) table
(~70 fields in total; only identification, customer, amount and status
fields are exposed for now). See `Luna.BusinessLogic.BonBE` for the
JSON-key-to-column field map.

| Method | Path                | Purpose                              |
|--------|---------------------|---------------------------------------|
| GET    | `/web/bon`          | List, paged. Query params: `klnr` (exact, 0/absent = no filter), `type` (exact, 0/absent = no filter), `page` (default 1), `pageSize` (default 25, max 200). Newest `bonnr` first. |
| GET    | `/web/bon/{bonnr}`  | Get one. 400 if `bonnr` is non-numeric. 404 if not found. |
| POST   | `/web/bon`          | Create. `bonnr` is server-generated (last `bonnr` + 1, computed under the same lock/transaction as the insert - no race between the two). `bonnr`, `bedrag` and `btw` in the body (if sent) are silently ignored. |
| PUT    | `/web/bon/{bonnr}`  | Update. Partial - only fields present in the body are changed. `bonnr`, `bedrag` and `btw` in the body (if sent) are silently ignored. 400 if `bonnr` is non-numeric, 404 if not found. |
| DELETE | `/web/bon/{bonnr}`  | Delete. 400 if `bonnr` is non-numeric. 404 if not found. 409 if the order still has related rows in `bonlijn`, `bonlijn_productie`, `bonlijn_variabel`, `bon_herstel`, `bon_led` or `bon_led_qc`. |

`bonnr`, `bedrag` (`b-bedrag`) and `btw` (`tot-btw`) are **not writable**
via this API on create/update: `bonnr` is assigned server-side, and
`bedrag`/`btw` are computed order totals owned by the order-lines feature
(not yet exposed here). Sending them in a POST/PUT body is accepted but has
no effect - the response always reflects the server-computed values.

Errors are returned as `{"error": {"message": "...", "code": <status>}}`.
Unlike `/web/klant` and `/web/offerte`, invalid (non-numeric) `klnr`,
`page` or `pageSize` on the list endpoint return `400` rather than
silently defaulting - this was an explicit part of the `/web/bon` contract.
The same non-numeric-input-is-400 rule applies to the `{bonnr}` path
segment on the get/update/delete endpoints.

Same pagination approach as `/web/offerte`: no exact `totalCount`, the list
response returns `hasMore` and stops scanning as soon as it has gathered one
page + 1 row. `klnr` uses the existing `bon-x3` index; a `type`-only filter
scans every row in the table, so combine it with `klnr` where possible.

**Known pre-existing quirk (not introduced by the CRUD work above):** the
list endpoint's `klnr`/`page`/`pageSize` query-param validation uses the
`INTEGER(...) NO-ERROR` + `EQ ?` pattern, but on this OpenEdge version a
failed `INTEGER()` conversion with `NO-ERROR` leaves the target variable at
its default (`0`), not the unknown value (`?`) - so e.g. `?klnr=abc`
currently falls through to "treated as 0/no filter" instead of the `400`
documented above, and a real fix means switching that check to
`ERROR-STATUS:ERROR`.

**Fixed regression from the bonlijn-nesting refactor:** the single-get/
update/delete `{bonnr}` path-segment validation used to use
`ERROR-STATUS:ERROR` (correctly returning `400` for a non-numeric `bonnr`).
The refactor that introduced `ParseBonnr`/`ParseLijnnr` (shared by the
nested `lijn` routes) temporarily switched those two methods to the
`INTEGER(...) NO-ERROR` + `EQ ?` pattern, which on this OpenEdge version
doesn't detect the failed conversion (see quirk above) - so
`GET/PUT/DELETE /web/bon/abc` and `.../lijn/abc` briefly returned `404`
instead of `400`. `ParseBonnr`/`ParseLijnnr` have been switched back to
`ERROR-STATUS:ERROR`, matching the pattern that already worked correctly
elsewhere in this file; `GET /web/bon/abc` and
`GET /web/bon/123/lijn/abc` now correctly return `400`
("Invalid bonnr abc"/"Invalid lijnnr abc") again - confirmed live, numeric
happy paths unaffected.

**Still open (out of scope for the `/web/bon` fix above):**
`Luna.Web.FactuurHandler`'s `ParseFacnr` and `Luna.Web.OfferteHandler`'s
equivalent path-segment parsing still use the `INTEGER(...) NO-ERROR` +
`EQ ?` pattern and have the identical quirk (`GET /web/factuur/abc` /
`GET /web/offerte/abc` -> `404`, not `400`), as does this list endpoint's
own `klnr`/`page`/`pageSize` query-param validation above. `Luna.Web.
BestelorderHandler`'s `{ordnr}` path-segment handling has an even more
silent variant of the same quirk - it doesn't check for the failed
conversion at all (`IF iOrdnr EQ ? THEN iOrdnr = 0`), so a non-numeric
`ordnr` is treated as `0`/not-found rather than raising `400`. `Luna.Web.
KlantHandler` and `Luna.Web.LeverancierHandler` had the identical
path-segment quirk and have been fixed (see their sections above) - worth a
follow-up ticket to switch the remaining handlers (`Factuur`, `Offerte`,
`Bestelorder`) to `ERROR-STATUS:ERROR` too.

## Bonlijn CRUD (`/web/bon/{bonnr}/lijn`)
Full CRUD over a curated core subset of the `bonlijn` (order line) table
(~90 fields in total; only identification, article, quantity, pricing and
status fields are exposed for now - production/LED/voorproductie/lock/
offerte-link fields are explicitly out of scope). See
`Luna.BusinessLogic.BonLijnBE` for the JSON-key-to-column field map.
`bonlijn` is a child of `bon` (linked via `bonnr`), so every endpoint below
is nested under its parent bon and every method 404s if that `bonnr`
doesn't exist.

| Method | Path                              | Purpose                              |
|--------|------------------------------------|---------------------------------------|
| GET    | `/web/bon/{bonnr}/lijn`            | List every line for this bon, ordered by `lijnnr`. Not paged - a bon has a bounded number of lines. |
| GET    | `/web/bon/{bonnr}/lijn/{lijnnr}`   | Get one. 404 if not found. |
| POST   | `/web/bon/{bonnr}/lijn`            | Create. `lijnnr` is server-generated (last `lijnnr` for this bonnr + 1, computed under the same lock/transaction as the insert). `bonnr`/`lijnnr` in the body (if sent) are silently ignored. |
| PUT    | `/web/bon/{bonnr}/lijn/{lijnnr}`   | Update. Partial - only fields present in the body are changed. `bonnr`/`lijnnr` are immutable. 404 if not found. |
| DELETE | `/web/bon/{bonnr}/lijn/{lijnnr}`   | Delete. 404 if not found. No cascade - `bonlijn` has no child tables in this scope. |

Errors are returned as `{"error": {"message": "...", "code": <status>}}`.

**No cascade from the parent bon:** unlike `/web/factuur`'s `faclijn`
cascade, `DELETE /web/bon/{bonnr}` does **not** delete its `bonlijn` rows -
`BonBE:DeleteBon`/`HasChildRows` are unchanged and still return `409` if any
`bonlijn` (or `bonlijn_productie`/`bonlijn_variabel`/`bon_herstel`/`bon_led`/
`bon_led_qc`) rows exist. Delete every `bonlijn` row individually via the
endpoint above first, then delete the bon.

Implementation note: `BonHandler` was refactored from a single-segment
`GetBonnrFromPath` helper to the `GetPathRemainder`/`SegmentCount`/`Parse*`
path-parsing pattern (mirroring `Luna.Web.FactuurHandler`) to support this
nesting - the existing `/web/bon` and `/web/bon/{bonnr}` endpoints keep the
same request/response contract as before.

## Factuur CRUD (`/web/factuur`)
Full CRUD over a curated core subset of the `factuur` (invoice) table (~60
fields in total; only identification, customer, amount and status fields
are exposed for now). See `Luna.BusinessLogic.FactuurBE` for the
JSON-key-to-column field map.

v1 only ever operates on **invoices**, never credit notes: `factuur.type EQ
TRUE` is hard-coded inside `FactuurBE`/`FacLijnBE` (not a caller-supplied
filter), and `type` itself is not settable via the API - it's always set to
`TRUE` on create. A credit note (`type EQ FALSE`) looked up/updated/deleted
by `facnr` is treated identically to "doesn't exist" - always `404`.

| Method | Path                    | Purpose                              |
|--------|-------------------------|---------------------------------------|
| GET    | `/web/factuur`          | List, paged. Query params: `klnr` (exact), `naam` (substring), `datum` (exact, `YYYY-MM-DD`), `projectnr` (exact), `page` (default 1), `pageSize` (default 25, max 200). Newest `datum` then `facnr` first. |
| GET    | `/web/factuur/{facnr}`  | Get one. 404 if not found or if it's a credit note. |
| POST   | `/web/factuur`          | Create. Body must include `facnr` (positive integer). 409 if it already exists (as an invoice or a credit note - `facnr` is unique across both). `type` in the body is ignored - always created as an invoice. |
| PUT    | `/web/factuur/{facnr}`  | Update. Partial - only fields present in the body are changed. `facnr`/`type` are immutable/not settable. 404 if not found or it's a credit note. |
| DELETE | `/web/factuur/{facnr}`  | Delete. Cascades to every `faclijn` row for this `facnr` and, for each of those, every `fac_led` row - no orphan lines/LED-detail rows are left behind. 404 if not found or it's a credit note. |

Errors are returned as `{"error": {"message": "...", "code": <status>}}`.

Same pagination approach as `/web/offerte`/`/web/bon`: no exact
`totalCount`, the list response returns `hasMore` and stops scanning as
soon as it has gathered one page + 1 row. `klnr` uses the existing
`factuur-x2` index, `datum` uses `factuur-x4` and `projectnr` uses
`factuur-x5`; a `naam`-only filter scans every candidate row, so combine it
with `klnr`/`datum`/`projectnr` where possible.

## Faclijn CRUD (`/web/factuur/{facnr}/lijn`)
Full CRUD over a curated core subset of the `faclijn` (invoice line) table
(~55 fields in total; only identification, article, quantity, pricing and
status fields are exposed for now). See `Luna.BusinessLogic.FacLijnBE` for
the JSON-key-to-column field map. `faclijn` is a child of `factuur` (linked
via `facnr`), so every endpoint below is nested under its parent factuur
and every method 404s if that `facnr` doesn't exist (or is a credit note).

| Method | Path                                       | Purpose                              |
|--------|---------------------------------------------|---------------------------------------|
| GET    | `/web/factuur/{facnr}/lijn`                | List every line for this factuur, ordered by `lijnnr`. Not paged - an invoice has a bounded number of lines. |
| GET    | `/web/factuur/{facnr}/lijn/{lijnnr}`       | Get one. 404 if not found. |
| POST   | `/web/factuur/{facnr}/lijn`                | Create. Body must include `lijnnr` (positive integer). 409 if it already exists for this factuur. |
| PUT    | `/web/factuur/{facnr}/lijn/{lijnnr}`       | Update. Partial - only fields present in the body are changed. 404 if not found. |
| DELETE | `/web/factuur/{facnr}/lijn/{lijnnr}`       | Delete. Cascades to every `fac_led` row for this `facnr`+`lijnnr`. 404 if not found. |

Errors are returned as `{"error": {"message": "...", "code": <status>}}`.
Deleting the parent factuur (`DELETE /web/factuur/{facnr}`) cascades to
every line here - lines don't need to be deleted individually first.

## Fac_led CRUD (`/web/factuur/{facnr}/lijn/{lijnnr}/led`)
Full CRUD over a curated core subset of the `fac_led` (LED-configuration
detail per invoice line) table (~35 fields in total; only identification,
article, dimensions, pricing and routing/config fields are exposed for
now). See `Luna.BusinessLogic.FacLedBE` for the JSON-key-to-column field
map. `fac_led` is a child of `faclijn` (linked via `facnr`+`lijnnr`), so
every endpoint below is nested under its parent faclijn and every method
404s if that `facnr`+`lijnnr` doesn't exist. Its own key within that scope
is `groepnr`+`ledLijn` (both non-negative integers).

| Method | Path                                                              | Purpose                              |
|--------|--------------------------------------------------------------------|---------------------------------------|
| GET    | `/web/factuur/{facnr}/lijn/{lijnnr}/led`                          | List every LED-detail row for this faclijn, ordered by `groepnr` then `ledLijn`. Not paged. |
| GET    | `/web/factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn}`      | Get one. 404 if not found. |
| POST   | `/web/factuur/{facnr}/lijn/{lijnnr}/led`                          | Create. Body must include `groepnr` and `ledLijn` (non-negative integers). 409 if that combination already exists for this faclijn. |
| PUT    | `/web/factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn}`      | Update. Partial - only fields present in the body are changed. 404 if not found. |
| DELETE | `/web/factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn}`      | Delete. 404 if not found. |

Errors are returned as `{"error": {"message": "...", "code": <status>}}`.
Deleting the parent faclijn (or, transitively, the parent factuur) cascades
to every fac_led row here - rows don't need to be deleted individually
first.

**Implementation note (WebHandler pattern):** every write path always
assigns the Business Entity instance (`FactuurBE`/`FacLijnBE`/`FacLedBE`) to
a local variable before calling a method on it and using its returned
temp-table handle (e.g. `oFactuurBE = NEW FactuurBE(). hResult =
oFactuurBE:GetFactuur(...)`), rather than chaining `NEW FactuurBE():GetX(...)`
inline. The inline form was tried first and intermittently produced a
runtime `3135`/`3140` ("Invalid handle" / "Cannot access the WRITE-JSON
attribute") error when the handler serialized the result - the anonymous
BE instance (and its instance-scoped temp-table) can get garbage collected
before `WRITE-JSON` runs on the handle it returned. Keeping a named
reference to the instance for the lifetime of the call avoids this. Worth
checking `Luna.Web.OfferteHandler` (which does use the inline form for a
few write paths) if any similar handle errors show up there under load.

## Dashboard summary (`/web/dashboard`)
Read-only aggregate over `offerte`, `bon`, `factuur` and `artikel` for the
Luna homepage dashboard: stat cards, a recent-activity feed and open orders
due this week ("productie deze week"). See `Luna.BusinessLogic.DashboardBE`
for the full business rules and field map. There is no dedicated
activity-log or production-stage table in the schema (`bonlijn_productie`
only tracks material reservation per orderlijn) - both features are
derived from existing offerte/bon/factuur data instead.

| Method | Path            | Purpose                    |
|--------|-----------------|-----------------------------|
| GET    | `/web/dashboard` | Returns `statCards` (object), `recentActivity` (array, newest first) and `productionThisWeek` (array). No query params. |

## Bestelorder (read-only) (`/web/bestelorder`)
Read-only access to a curated core subset of the `order` (purchase order to
supplier/leverancier) table (~35 fields in total; only identification,
supplier, amount, delivery and status fields are exposed). See
`Luna.BusinessLogic.BestelorderBE` for the JSON-key-to-column field map.

Named "Bestelorder" rather than "Order" throughout this feature (class
names, buffer alias, endpoint path) for two reasons: `ORDER` is an
ABL/SQL-reserved word (`BestelorderBE` uses an explicit `DEFINE BUFFER
bBestelorder FOR order.` alias rather than a bare `order` buffer), and to
avoid confusion with the unrelated, pre-existing `bon`-based "Orders &
Productie" feature (customer sales orders, `Luna.BusinessLogic.BonBE`) -
`order` (purchase orders to suppliers) and `bon` (customer orders) are
different tables.

| Method | Path                       | Purpose                              |
|--------|----------------------------|---------------------------------------|
| GET    | `/web/bestelorder`         | List, paged. Query params: `levnr` (exact, 0/absent = no filter), `ordnr` (prefix match on the string form, absent = no filter), `naam` (substring match on the leverancier name, case-insensitive, absent = no filter), `sortField` (`ordnr`/`datum`/`naam`/`stempel`, absent/unrecognized falls back to `ordnr`), `sortDir` (`asc`/`desc`, absent/unrecognized falls back to `desc`), `page` (default 1), `pageSize` (default 25, max 200). Response echoes the effective `sortField`/`sortDir`. Defaults to newest `ordnr` first. |
| GET    | `/web/bestelorder/{ordnr}` | Get one. 404 if not found. |
| GET    | `/web/bestelorder/{ordnr}/lijn` | List the `ordlijn` (purchase order line) rows for this order, ordered by `lijnnr`. Curated core subset - see `Luna.BusinessLogic.OrdlijnBE` for the field map. Does **not** 404 if `{ordnr}` doesn't exist - it just returns `{"items": []}` (same "no separate existence check" reasoning as the parent's non-numeric-input handling); callers that need a 404 for a missing order should call `GET /web/bestelorder/{ordnr}` first (this is what the frontend's order-detail page does). |

Errors are returned as `{"error": {"message": "...", "code": <status>}}`.

Unlike `/web/bon`, invalid/non-numeric `levnr`, `page`, `pageSize` or
`{ordnr}` are **not** rejected with `400` - they silently fall back to
"no filter"/default page/pageSize, or (for `{ordnr}`) to a value that will
not match any row and therefore surfaces as a normal `404`. Same approach
as `/web/klant` and `/web/offerte`.

Same pagination approach as `/web/bon`: no exact `totalCount`, the list
response returns `hasMore` and stops scanning as soon as it has gathered one
page + 1 row. `levnr` uses the existing `order-x3` index; an unfiltered list
scans every row in the table (~40k rows in this environment).

Filtering (`ordnr`/`naam`) and sorting on anything but `ordnr` can't use
that early-stop scan directly - `BestelorderBE` stages every matching row
first, then sorts/pages that staged set. Every sort branch is still a
plain static `FOR EACH ... BY ...` (no dynamic queries) - see the class
header and `EmitRow()` in `Luna.BusinessLogic.BestelorderBE` for details.

Read-only in this iteration: no POST/PUT/DELETE. `BestelorderBE` has no
write methods at all.

Notable business rules (see `DashboardBE` class header for the full
reasoning):
- **Open offertes**: latest versie per offnr, not passief/verkocht/verloren,
  AND `datum` within the last 90 days. The date window was added after
  finding that old offerte rows are not consistently marked
  closed in production data - 27457 of 28405 rows matching only the status
  flags were dated before 2025-01-01 (oldest: 2000-02-29), which massively
  overcounted "open" offertes. This 90-day window is a pragmatic choice, not
  a confirmed business definition - revisit with Marc/sales if a more
  reliable "open" indicator surfaces.
- **Lage voorraad**: requires a full scan of ~1.8M `artikel` rows (no index
  on `stock`/`aantal`/`minv`) and can take 45-70s on a cold call. The
  frontend caches this endpoint for 60s (Next.js `revalidate`) so this cost
  isn't paid on every dashboard page load - expect the same latency here on
  a cold call from Bruno. A dedicated index or a precomputed/background
  figure would be the real fix if this becomes a bottleneck.

## Auth-MVP (login/logout)
See `docs/architecture/login-auth-ontwerp.md` for the full design (incl.
two implementation-time deviations from the original design, documented
in that doc's §1.4 and §1.5 - the `X-Auth-Token` header instead of
`Authorization: Bearer`, and the `MTIME`-based token generator instead of
`GENERATE-UUID()`). All DB access (`gebruiker.Password`,
`authenticationToken`) lives exclusively in `Luna.BusinessLogic.AuthBE`.

| Method | Path         | Purpose                                          |
|--------|--------------|---------------------------------------------------|
| POST   | `/web/login`  | Body `{"kode": "...", "password": "..."}`. 200 with `{token, kode, naam, niveau, everyoneAdminActive, expiresAt}` on success. 400 (empty field), 401 (unknown kode/wrong password, identical generic message), 403 (passief account, after the password check). |
| POST   | `/web/logout` | Requires `X-Auth-Token: <token>` header (not `Authorization` - see deviation note above). 200 `{"message": "Uitgelogd"}` on success, 401 if the token is missing/unknown/expired. Deletes the `authenticationToken` row. |

- **`AUTH_EVERYONE_ADMIN` feature flag**: an OS-environment variable read
  fresh (no caching) via `OS-GETENV()` on every `AuthBE:GetEffectiveNiveau()`
  call (used by both `Login()` and `ValidateToken()`), so a flag change
  applies to already-open sessions immediately - no re-login needed. Only
  the exact value `true` (case-insensitive) activates it; anything else,
  including unset, is treated as `false` (fail-closed). When active, every
  login/session gets the hardcoded highest niveau (`9`) regardless of the
  user's actual `gebruiker.niveau`. Must be set in the environment the
  PASOE `MarcTest` agent process itself runs in (e.g. exported before
  `tcman start`) - a PASOE restart is required to pick up a change.
  Verified live: with the flag set to `true` before `tcman start`, `POST
  /web/login` for a niveau-1 user returned `niveau: 9,
  everyoneAdminActive: true`; without it, the same login returned the
  user's real `niveau: 1, everyoneAdminActive: false`.
- **Session duration**: fixed 8 hours from login (`expiryDate = NOW + 8
  hours`), no sliding/rolling expiry. `AuthBE:ValidateToken()` (reusable by
  future Business Entities that need an auth check) deletes an expired
  `authenticationToken` row the moment it's found (passive cleanup) - no
  separate scheduled cleanup job.
- **Seed script (`scripts/SeedTestPasswords.p`/`.ps1`)**: sets
  `gebruiker.Password` to a single shared test password on every existing
  `gebruiker` row (~32). Test-only - the actual password value is
  documented in `docs/handleidingen/login.md` (docs-writer), not here.
  Deliberately **not** wired into `compile.ps1` or any scheduled task -
  it's a manual, one-off operational script with two independent guards
  against an accidental run against a real database: the `.ps1` wrapper
  refuses to run without an explicit `-Confirm` switch, and the `.p`
  script itself refuses to touch the database without the exact `-param
  CONFIRM` flag. Run it like:
  ```powershell
  powershell -File "Backend\scripts\SeedTestPasswords.ps1" -Confirm
  ```
- **Seed script (`scripts/SeedTestNiveaus.p`/`.ps1`)**: sets
  `gebruiker.niveau` on a small, explicit, NAMED list of test users only —
  `ABNA -> 5` (kept a "gewone gebruiker" test account, not admin),
  `MS -> 9` and `JS -> 9` (simulate admin-level users, per
  `AuthBE:GetEffectiveNiveau()`'s hardcoded max of 9) — so per-user
  differences (dashboard/rechten) can be exercised through login. Every
  other `gebruiker` row is left untouched; this is a predictable,
  documentable data fix, **not** a bulk/random reassignment. Same two
  independent guards as `SeedTestPasswords.p`/`.ps1` above (`-Confirm` on
  the wrapper, `-param CONFIRM` on the batch script) and, likewise,
  deliberately **not** wired into `compile.ps1` or any scheduled task. Run
  it like:
  ```powershell
  powershell -File "Backend\scripts\SeedTestNiveaus.ps1" -Confirm
  ```
- **Known infra quirk (see login-auth-ontwerp.md §1.4)**: the standard
  `Authorization` header never reaches `OpenEdge.Web.WebHandler` code in
  this PASOE `MarcTest` configuration - PASOE/Tomcat intercepts it first.
  Confirmed live; use `X-Auth-Token` for any future endpoint that needs to
  read an auth token from a header.

## AI Search (`/web/ai-search`)
AI-powered natural-language search over bon/offerte/klant/artikel/factuur/
bestelorder data, using Google Gemini for stage 1 (NL prompt -> structured
intent) and stage 2 (results -> short NL summary). No auth required, same
as the other list endpoints. See `Luna.BusinessLogic.AiSearchBE`'s class
header for the full orchestration and the exact whitelist.

| Method | Path            | Purpose |
|--------|-----------------|---------|
| POST   | `/web/ai-search` | Body `{"prompt": "..."}` (required, non-empty, max 500 chars - `400` otherwise). Always `200` for a search that ran (even with zero results or an ambiguous prompt) - see response shapes below. |

**Config - `GEMINI_API_KEY`:** the Gemini API key is read from the
`GEMINI_API_KEY` OS-environment variable by `Luna.BusinessLogic.
GeminiGateway` (never hardcoded) - same pattern as `AUTH_EVERYONE_ADMIN` in
`Luna.BusinessLogic.AuthBE`. Must be set in the environment the PASOE
`MarcTest` agent process itself runs in (e.g. exported before `tcman
start`) - a PASOE restart is required to pick up a new/changed key. If it's
unset (or the Gemini call otherwise fails/times out - 8s timeout), stage 1
fails and the endpoint returns `502` with a fixed Dutch message (see error
table below) - **confirmed live** in this environment (no key configured
here): `POST /web/ai-search` with a normal search prompt returns exactly
`{"error": {"message": "De AI-zoekfunctie is momenteel niet beschikbaar.
Probeer het later opnieuw.", "code": 502}}`.

**Response shapes** (`resultType`: `results` / `no_results` /
`clarification`, all `200 OK`):
```json
{
  "queryText": "...", "resultType": "results", "entity": "bon",
  "intent": { "entity": "bon", "filters": [...], "aggregation": {...}, "confidence": 0.91 },
  "items": [ {...} ], "page": 1, "pageSize": 25, "hasMore": false,
  "summary": "...", "clarificationQuestion": null
}
```
`no_results` and `clarification` are the same shape with `items: []` and
`entity`/`intent`/`summary` set to `null` (clarification) or a
deterministic Dutch "no rows matched" summary with no second Gemini call
(no_results) - see the design contract in the class header.

**Error responses** (real HTTP errors, not part of the shapes above):

| Situation | Status | Message |
|---|---|---|
| Empty/missing `prompt` | 400 | `prompt is required` |
| `prompt` > 500 characters | 400 | `prompt is too long (max 500 characters)` |
| Stage 1 (Gemini NL->intent) fails/times out | 502 | `De AI-zoekfunctie is momenteel niet beschikbaar. Probeer het later opnieuw.` |
| Unexpected internal error | 500 | `Er is een fout opgetreden bij het verwerken van je zoekopdracht.` |
| Method other than POST | 405 | `Method not allowed on /ai-search` |

A stage 2 (summary generation) failure/timeout is **never** a 502 - it
falls back to a deterministic template summary (design contract, see
`AiSearchBE:BuildFallbackSummary`).

**Whitelist (`AiSearchBE:InitWhitelist`)** - hardcoded ABL temp-tables,
**not** a new DB table. An LLM-produced intent is only ever translated into
a DB query through this whitelist and the existing entity Business
Entities' own typed parameters - the model's text never reaches a WHERE
clause. Deliberately scoped to what those BEs already support as filter
parameters today (see the "Divergences from the original design doc" note
in `AiSearchBE`'s class header for the handful of fields the original
architect design listed that aren't wired up yet - e.g. `bon.datum`/
`levDatum`, `offerte.passief`/`verkocht`/`verloren`, and `range` on
`factuur.datum`):

| Entity | Aggregatable fields | Filterable fields (operator, indexed?) |
|---|---|---|
| bon | bedrag | klnr (eq, indexed), bonnr (prefix, indexed), type (eq), naam (contains), geparkeerd (eq), verzonden (eq) |
| offerte | bedrag, btw | klnr (eq, indexed), offnr (prefix, indexed), naam (contains) |
| klant | saldo | klnr (eq, indexed), naam (contains) |
| artikel | voorraad, aankoopprijs, verkoopprijs | artnr (prefix, indexed), groep (eq) - `omschrijving` deliberately NOT whitelisted (existing 15.000-row scan-depth cap/performance hotspot on `ArtikelBE:GetArtikelen`, not to be made worse here) |
| factuur | totaal, nBedrag, totBtw | klnr (eq, indexed), datum (eq only, indexed), projectnr (eq, indexed), naam (contains) |
| bestelorder | bedrag | levnr (eq, indexed), ordnr (prefix), naam (contains) |

Every entity `requiresSelectiveFilter` (at least one filter on an
`indexed` field) and caps `pageSize` at 50 - a prompt that doesn't resolve
to a selective filter, a non-whitelisted entity/field/operator, or a
confidence below `0.6`/an explicit `clarificationNeeded` from Gemini all
produce a `clarification` result rather than ever touching the database.

**`Luna.BusinessLogic.BonBE:GetBonnen`** gained a new `pcVerzonden`
parameter (tri-state `""`/`"true"`/`"false"`, same convention as the
existing `pcGeparkeerd`) so AI Search's flagship "openstaande orders"
example (`geparkeerd = false AND verzonden = false`) is expressible -
additive change, `Luna.Web.BonHandler`'s existing call site now passes
`""` (no `?verzonden=` query param wired there yet, AiSearchBE is the only
caller today).

**Anti-hallucination check:** every number Gemini's stage-2 summary
mentions is checked against the actual server-computed aggregates/sample
data (`AiSearchBE:ValidateSummaryAgainstData`) - a best-effort digit-only
comparison (ignores thousands/decimal punctuation, skips single-digit
tokens), not a mathematically perfect one, but enough to catch a model
inventing a materially different number. Any mismatch discards the
generated summary in favor of the deterministic template.

**Privacy note:** the prompt (stage 1) and a small, already-authorized
data sample - aggregates + up to 20 sample rows, which can include
customer/invoice data (stage 2) - are sent to Google's external Gemini
API (no confirmed EU data residency). This is a deliberate,
product-owner-approved tradeoff for this feature, not an oversight - see
`Luna.BusinessLogic.GeminiGateway`'s class header.

## Pricing engine (Iteratie A, K1-K5) (`/web/pricing/bereken`)
Pure read-only pricing service - does NOT write to `offlijn`/`bonlijn` or
any other table. 1:1 port of the legacy `Include/Prijs.i` procedures
(`CprijsI`/`GprijsI`/`AprijsI`) plus the promotie (`actie`) override
confirmed against 4 independent legacy call sites. See
`Luna.BusinessLogic.PricingEngineBE`'s class header for the full
orchestration, the exact legacy source verified against
(`\\LHDC01\TESTLUNA$\LunaV12\Include\Prijs.i`), and the documented,
deliberate simplifications vs. the legacy procedures (sw-uitverkoop
always TRUE, iplGroep always FALSE, sw-LedConfig replaced by "does an
art_profiel record exist", and the `kortingLocked` simplification).

| Method | Path                     | Purpose |
|--------|--------------------------|---------|
| POST   | `/web/pricing/bereken`   | Body `{"artnr", "klnr", "aantal", "typeKorting", "documentKorting"}` - computes vprijs/aprijs/korting/promotie for one artnr/klnr/aantal/typeKorting combination. |

**Request body:**
```json
{
  "artnr": "ART-001",
  "klnr": 10165,
  "aantal": 3,
  "typeKorting": "K1",
  "documentKorting": 0
}
```
`typeKorting` must be one of `K1`-`K5`. `documentKorting` is only relevant
for `K3`/`K4`/`K5` (K3 ignores it - see `BepaalKorting`; K4/K5 pass it
straight through). The architect design doc's optional `context` field
adds nothing to the calculation and is deliberately not read by this
handler.

**Response 200:**
```json
{
  "artnr": "ART-001", "klnr": 10165, "aantal": 3,
  "vprijs": 84.2, "aprijs": 42.1, "korting": 0,
  "kortingLocked": false, "promotieActief": false,
  "nettoPrijsToegepast": false, "uitverkoopToegepast": false
}
```

**Errors** (same `{"error":{"message","code"}}` envelope as the other
handlers):
- `400` - `typeKorting` not one of `K1`-`K5` (raised in
  `PricingEngineBE:BerekenPrijs`).
- `400` - `klnr`/`aantal`/`artnr` missing or non-numeric where required
  (checked in `PricingHandler`, the thin parsing layer).
- `404` - `artnr` not found in `artikel`.
- `500` - fallback for anything unexpected (no ABL stack trace ever
  reaches the client).

Confirmed live against `MarcTest` 2026-09-20: K1 discount-lookup happy
path, K3 (always 0, documentKorting ignored), K4/K5 (documentKorting
passthrough), unknown `typeKorting` (400), unknown `artnr` (404), and
missing/non-numeric `klnr`/`aantal` (400) - see `Backend/bruno/Pricing/`
for the exact requests/assertions.

**Not yet exercised live in this environment** (no matching test data
found in `LunaNew` at the time of writing - flagging for backend-tester
to set up/locate before signing off on full coverage): a `korting` row
that actually matches one of the 15 hierarchy steps (so `korting > 0` on
the response), an `art_profiel` row for the test artikel (to exercise the
profielgroep-based steps b/g/l), an `art_netto` exact-match row
(`nettoPrijsToegepast: true`), an `artikel.uitverkoop = TRUE` row with a
non-zero `uit-prijs`/`korting` (`uitverkoopToegepast: true` and the
korting early-return), a composite (`artikel.soort = TRUE`) article with
`artlijn` rows (BOM recomputation path in both `BepaalVerkoopprijs` and
`BepaalAankoopprijs`), and an `actie` row with `vdatum <= TODAY <= tdatum`
and a non-zero `vprijs` (`promotieActief: true`, `kortingLocked: true`).
