# Luna — projectdocumentatie

Projectbrede kennis voor backend én frontend. De backend-repo is de thuisbasis omdat
de backend de database en de business rules bezit.

| Document | Inhoud |
|---|---|
| [coexistentie.md](coexistentie.md) | Regels voor schrijven naast LunaV12 op dezelfde DB |
| [legacy-inventaris.md](legacy-inventaris.md) | LunaV12-menu → programma → module → migratiestatus |
| [adr/](adr/) | Architecture Decision Records |
| [modules/](modules/) | Analyse per module (V12-programma's, tabellen, regels, status) |
| [schema/](schema/) | Volledige DB-definitie (`.df`) + tabelnotities |
| [wachtwoord-hashing-voorstel.md](wachtwoord-hashing-voorstel.md) | Voorstel wachtwoord-hashing (nog niet geïmplementeerd) |

## Module-pipeline

Elke module (of feature) loopt door dezelfde stappen. Elke stap is een sub-issue van de
module-epic in het GitHub Project **Luna ERP**.

1. **Analyse** — LunaV12-programma's lezen (read-only) → `modules/<module>.md`:
   tabellen, velden, nummering, locks, neveneffecten, schermen/menu-items, wat *niet* gemigreerd wordt.
2. **Contract** — Bruno-request(s) met voorbeeldrespons in `bruno/<Domein>/`.
3. **Backend** — BE + dunne handler, compile, Bruno groen.
4. **Frontend** — feature-slice in `luna_frontend`, enkel via `src/lib/api-client.ts`.
5. **Pariteit** — zelfde scenario in V12 en Luna web geeft hetzelfde DB-resultaat.
6. **Docs** — README/AGENTS.md (beide repos), UI-GUIDE.md, module-doc; Migratiefase op het bord bijwerken.

### Migratiefasen

| Fase | Betekenis |
|---|---|
| 0 | Niet gestart |
| 1 | Lezen — Luna web toont data, schrijven gebeurt in V12 |
| 2 | Schrijven — Luna web schrijft ook (coexistentie-regels van kracht) |
| 3 | V12 uitgefaseerd — gebruikers werken enkel nog in Luna web voor deze module |

## Ontbrekende documenten

Het README verwijst naar documenten die niet (meer) in de repo staan. Terugzetten of
verwijzing verwijderen:

- `docs/backend/coating-reference-data.md`
- `docs/backend/offerte.md`
- `docs/architecture/voorraad-fase1-ontwerp.md`
- `docs/architecture/verkoop-fur-ontwerp.md`
- `docs/architecture/login-auth-ontwerp.md`
