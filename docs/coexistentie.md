# Coexistentie met LunaV12

LunaV12 en Luna web werken **tegelijk** op dezelfde database `lunanew` en **beide schrijven**
(strangler-aanpak: module per module overnemen). Een schrijfactie uit Luna web moet voor
LunaV12 niet te onderscheiden zijn van een schrijfactie uit V12 zelf.

Deze regels gelden voor elke PR met label `writes-db`.

## 1. Nummering

- Gebruik **exact dezelfde bron** als V12 om nummers toe te kennen (DB-sequence, tellerveld in
  `syspara`/een tellertabel, of `MAX()+1`). Zoek dit per entiteit uit in de module-analyse en
  noteer het in `modules/<module>.md` onder "Nummering".
- Ken een nummer toe binnen dezelfde transactie als de create, met dezelfde lock-volgorde als V12,
  zodat V12 en Luna web elkaar niet hetzelfde nummer geven.
- `MAX()+1` zonder lock is **niet** toegestaan, ook al doet V12 het zo: gebruik dan een
  exclusive lock op het laatste record of stap over op een sequence (eerst ADR).

## 2. Neveneffecten

Alles wat V12 bijwerkt bij een save, moet Luna web ook bijwerken. Typische voorbeelden:

- tellers/totalen op parent-records (bv. `klant.besteld`, `bonlijn.besteld`)
- voorraadvelden en `artlog`-bewegingen
- statusvelden (`stempel`, afgehaald/gefactureerd-vlaggen)
- historiek-/logtabellen (`ActionLog.i` in V12)
- e-mails of exportbestanden die V12 bij de actie aanmaakt (beslissen: meenemen of bewust niet)

Noteer per schrijfactie in de module-doc: **V12-programma + regel(s)** → **Luna BE-methode**.

## 3. Schema

- Enkel **additieve** wijzigingen (nieuwe tabel/veld/index). Nooit hernoemen, verwijderen of
  type/format wijzigen zolang V12 de tabel gebruikt.
- Nieuwe verplichte velden krijgen een initial value die V12 correct laat werken.
- Elke schemawijziging: ADR + nieuwe dump in `schema/` + `.df`-delta in de PR.
- Schema-triggers (bv. `artikel-triggers.df` in V12) gelden ook voor PASOE: controleer dat de
  trigger-procedures in de PROPATH van PASOE staan, anders draaien ze niet.

## 4. Transacties en locks

- Reads: `NO-LOCK`.
- Writes: `EXCLUSIVE-LOCK` enkel binnen een expliciet, kort `DO TRANSACTION`-blok.
- Nooit wachten op een lock vanuit een webrequest: `NO-WAIT` + `LOCKED`-check → HTTP **409**
  met een duidelijke melding ("record in gebruik door …").
- Geen user-interactie of externe calls (mail, Gemini, bestanden) binnen een transactie.

## 5. Testen

- CI (MarcDev) en manueel testen (MarcTest) delen nu `LunaNew`. Zodra schrijvende endpoints
  geautomatiseerd getest worden: aparte DB-kopie voor CI.
- Pariteitscheck per schrijfactie: zelfde scenario in V12 en Luna web, daarna de betrokken
  records vergelijken (veld per veld, inclusief neveneffecten).

## Checklist (kopie in PR-template)

- [ ] Nummering via dezelfde bron/lock als V12 (gedocumenteerd in module-doc)
- [ ] Alle V12-neveneffecten nagebouwd of bewust weggelaten (gedocumenteerd)
- [ ] Enkel additieve schemawijzigingen (+ ADR)
- [ ] Korte transactie, `NO-WAIT` → 409 bij lock
- [ ] Pariteitscheck V12 ↔ Luna web uitgevoerd
