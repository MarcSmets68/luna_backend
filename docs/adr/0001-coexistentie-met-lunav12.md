# ADR-0001: Coexistentie met LunaV12 op dezelfde database

- **Status**: aanvaard
- **Datum**: 2026-11-18

## Context

Luna web vervangt LunaV12. Een big-bang-overgang is te risicovol voor een ERP dat dagelijks
gebruikt wordt. Beide applicaties kunnen dezelfde OpenEdge-database `lunanew` gebruiken.

## Besluit

- Strangler-aanpak: module per module overnemen (migratiefasen 0–3, zie `docs/README.md`).
- LunaV12 en Luna web draaien tegelijk op dezelfde database en **mogen beide schrijven**.
- LunaV12-code wordt niet gewijzigd; het is de functionele specificatie.
- Schrijvende code volgt de regels in `docs/coexistentie.md`.

## Gevolgen

- Elke schrijfactie moet nummering, locks en neveneffecten van V12 exact respecteren.
- Schemawijzigingen zijn enkel additief zolang V12 draait.
- Module-analyse van V12 is een verplichte stap vóór schrijvende features.
