# ADR-0003: Business Entities bouwen JSON zonder verplichte ProDataSets

- **Status**: aanvaard
- **Datum**: 2026-11-18

## Context

De oorspronkelijke regel was "DB-toegang in Business Entities via ProDataSets". In de praktijk
gebruiken 7 van de 55 BE-klassen een DATASET; de meeste bouwen rechtstreeks `JsonObject`s of
gebruiken temp-tables.

## Besluit

- De regel "handlers dun, logica en DB-toegang in BE's" blijft.
- BE's mogen kiezen: `JsonObject`/`JsonArray`, temp-tables of ProDataSets. ProDataSets zijn
  aanbevolen voor geneste schrijfoperaties (header + lijnen in één transactie).
- Responsvorm (veldnamen, nesting) ligt vast in het Bruno-contract, niet in de interne structuur.

## Gevolgen

- Geen refactor van bestaande BE's nodig om aan de regel te voldoen.
- README-regel aangepast.
