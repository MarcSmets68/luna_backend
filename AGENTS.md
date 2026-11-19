# Luna Backend — Agent-instructies

**Laatste update: 2026-11-18**

Instructies voor elke agent (Claude Code, Devin) en mens die in deze repo werkt.
`CLAUDE.md` importeert dit bestand. De technische referentie per endpoint staat in
[README.md](README.md); projectbrede afspraken staan in [docs/](docs/README.md).

---

## Context in één alinea

Luna web is de opvolger van het legacy ERP **LunaV12** (`T:\LunaV12`, procedurele ABL/AppBuilder).
Beide applicaties draaien **tegelijk op dezelfde OpenEdge-database** (`lunanew`) en **beide schrijven**.
LunaV12 is enkel referentie: **nooit iets wijzigen in `T:\LunaV12` of `\\LHDC01\TESTLUNA$\LunaV12`**.
Frontend: aparte repo `luna_frontend` (Next.js), praat met deze backend via `/web/*` (PASOE WebHandlers).

## Architectuurregels

1. **WebHandlers blijven dun**: routing, parsing, response shaping. Geen DB-toegang, geen business rules.
2. **Business logic en DB-toegang in Business Entities** (`Luna.BusinessLogic.<Entiteit>BE`).
   BE's mogen `JsonObject` of temp-tables gebruiken; ProDataSets zijn niet verplicht
   (zie [ADR-0003](docs/adr/0003-be-response-vorm.md)).
3. **Coexistentie met LunaV12** — elke schrijvende wijziging volgt [docs/coexistentie.md](docs/coexistentie.md):
   zelfde nummering, zelfde neveneffecten, korte transacties, enkel additieve schemawijzigingen.
4. **Auth**: `X-Auth-Token` header, gecontroleerd via `AuthGuard:Check` (niet `Authorization:`).
5. **Fouten**: `{"error":{"message":"...","code":"..."}}` met passende HTTP-status
   (400 validatie, 404 niet gevonden, 409 conflict/lock, 401 auth).
6. **Contract = Bruno**: elk endpoint heeft een request in `bruno/<Domein>/` met een
   representatieve respons in de docs-sectie. Frontend-types volgen dit contract.

## Definition of done (per PR)

- [ ] `scripts/compile.ps1` compileert zonder fouten.
- [ ] PASOE (MarcTest) herstart en `GET /web/test` → `databaseConnected:true`.
- [ ] Bruno-request(s) toegevoegd/bijgewerkt en groen.
- [ ] Nieuwe handler-mapping toegevoegd aan **beide** PASOE-instanties en in README.
- [ ] Label `writes-db`? → coexistentie-checklist uit de PR-template doorlopen.
- [ ] README (endpoint-sectie) en, indien van toepassing, `docs/modules/<module>.md` bijgewerkt.
- [ ] PR verwijst naar het issue (`Closes #N`).

## Werkwijze

- Werk komt uit het GitHub Project **Luna ERP** (issues in deze repo of `luna_frontend`).
- Branch: `feature/<issue#>-<slug>`, `fix/...`, `chore/...` (Devin: `devin/...` mag) vanaf `development`.
- Commits: Conventional Commits met scope, bv. `feat(pakbon): afhalen boekt voorraad (#42)`.
- PR naar `development`; `main` = productie, enkel via PR vanuit `development`.
- Feature over beide lagen: **backend-PR eerst**, frontend-PR verwijst ernaar.
- Module-pipeline: analyse (LunaV12) → contract (Bruno) → BE/handler → frontend → pariteitscheck → docs.
  Zie [docs/README.md](docs/README.md#module-pipeline).

## Legacy-analyse (LunaV12)

- Feature-inventaris: `T:\LunaV12\Menu.w` (hoofdmenu) en `T:\LunaV12\NPP\Menu2.w` (shop-floor),
  samengevat in [docs/legacy-inventaris.md](docs/legacy-inventaris.md).
- Codeorganisatie V12: root = hoofdschermen, `Update/` = onderhoud/LED-parameters, `Zoek/` = zoekdialogen,
  `Lijst/` = rapporten/etiketten, `Include/` = gedeelde includes (`Prijs.i`, `LedVar.i`, …), `NPP/` = shop-floor.
- Schema: enkel delta's in `Conversie\Delta-*.df`; volledige dump hoort in `docs/schema/` (zie daar).
- Leg bevindingen vast in `docs/modules/<module>.md` — nooit enkel in een chat of PR-beschrijving.

## Omgevingen

| Instantie | Poorten | Gebruik |
|---|---|---|
| MarcTest | 8080 / 8443 | Manueel testen, frontend-dev |
| MarcDev | 8081 / 8444 | CI-doel (self-hosted runner `pasoe-windows`) |

Beide gebruiken DB `LunaNew`. Env-vars via `scripts/luna-env.local` (gitignored):
`AUTH_ENFORCE`, `DEV_ENDPOINTS_ENABLED`, `AUTH_EVERYONE_ADMIN`, `GEMINI_API_KEY`.

## Bekende schuld (zie issues met label `type:chore`)

- Wachtwoorden in plaintext (`AuthBE.cls`) — **blocker** vóór publieke toegang (tunnel/Vercel).
- Geen gedeelde handler-basisklasse (28× `WriteJsonResponse`/`WriteErrorResponse`).
- Drie handlers doen eigen tokencontrole i.p.v. `AuthGuard`.
- Geen ABLUnit-tests; CI = compile + smoke.
