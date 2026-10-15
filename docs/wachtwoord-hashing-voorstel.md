# Voorstel: wachtwoord-hashing voor `gebruiker.Password`

Status: **VOORSTEL - niets hiervan is uitgevoerd.** De tabel `gebruiker` wordt
gedeeld met de legacy-applicatie; elke stap hieronder moet eerst met de
eigenaar worden afgestemd.

## 1. Huidige situatie
- `AuthBE:Login` vergelijkt `gebruiker.Password` in plaintext met het
  ingevoerde wachtwoord (zie TODO in `AuthBE.cls`, stap 3).
- Elk met de database verbonden systeem (legacy-app, backups, DBA's) kan alle
  wachtwoorden lezen. Wachtwoorden die hier in gebruik zijn, zijn
  waarschijnlijk ook elders in gebruik.
- De legacy-applicatie leest/schrijft dezelfde kolom. Zolang zij plaintext
  verwacht, kan de kolom niet zomaar vervangen worden door hashes.

## 2. Algoritme
- **PBKDF2-HMAC-SHA-256**, minimaal 600.000 iteraties (OWASP-richtlijn),
  16 bytes willekeurige salt per gebruiker, 32 bytes afgeleide sleutel.
  Reden: OpenEdge ABL heeft dit ingebouwd (`GENERATE-PBE-SALT`,
  `GENERATE-PBE-KEY` met `PBE-HASH-ALGORITHM`/`PBE-KEY-ROUNDS`), zonder
  extra bibliotheken of native code. Argon2id/bcrypt zijn beter maar vragen
  externe componenten; kan later via het versieprefix (zie hieronder).
  Nog te verifieren op de gebruikte OpenEdge-versie: ondersteuning van
  SHA-256 als PBE-hash en de doorlooptijd van 600k rondes (doel: < 300 ms).
- Opslagformaat in een tekstveld, met versieprefix zodat het algoritme later
  kan wijzigen:
  `$pbkdf2-sha256$<rondes>$<salt-hex>$<hash-hex>` (ca. 120 tekens).
- Optioneel een "pepper": HMAC over het wachtwoord met een geheim uit een
  OS-omgevingsvariabele (niet in de database), zodat een gelekte tabel op
  zichzelf niet volstaat. Verlies van de pepper = alle wachtwoorden
  onbruikbaar; dus alleen met een beheerd back-upproces.
- Vergelijking: beide hashes als vaste-lengte hex vergelijken. ABL heeft geen
  constant-time vergelijking; het risico is beperkt door de inlogbeperking
  (B3) en de vaste lengte, maar blijft vermeld.

## 3. Voorwaarden (beslissingen van de eigenaar)
1. **Veldlengte**: controleer het formaat van `gebruiker.Password`. Een hash
   van ca. 120 tekens past mogelijk niet. Een grotere kolom of een nieuwe
   kolom is een schemawijziging in de gedeelde database.
2. **Legacy-applicatie**: kan zij hashes verifieren? Zo nee, dan zijn er twee
   routes:
   - **A (aanbevolen): nieuwe kolom** `PasswordHash` naast `Password`.
     Luna verifieert tegen `PasswordHash`; de legacy-app blijft op `Password`
     werken. Nadeel: plaintext blijft bestaan tot de legacy-app is aangepast
     of uitgefaseerd, en wachtwoordwijzigingen moeten naar beide kolommen.
   - **B: legacy-app aanpassen** om hashes te verifieren en te schrijven,
     daarna `Password` vervangen/leegmaken. Beste eindresultaat, grootste
     afstemming.
3. Wie wijzigt wachtwoorden na de migratie, en via welk scherm
   (een reset-flow bestaat nog niet).

## 4. Migratie (na akkoord)
Fase 0 - Voorbereiding
- Volledige back-up van de database; de plaintext-waarden NIET in een
  gewone export bewaren (versleuteld, beperkte toegang, vaste bewaartermijn).
- Schemawijziging (route A: kolom `PasswordHash`) door de eigenaar.
- Feature-flag in Luna, bv. OS-variabele `AUTH_PASSWORD_MODE` met waarden
  `plain` (huidig gedrag, standaard) / `dual` / `hash`.

Fase 1 - Dual-verify (`dual`), code in `AuthBE`
- Login: bestaat `PasswordHash` -> verifieer die; anders vergelijk plaintext.
- Bij een geslaagde login zonder hash: bereken en schrijf `PasswordHash`
  ("lazy migration"), plaintext blijft ongemoeid. Geen bulk-update, geen
  downtime, en een fout raakt alleen die ene gebruiker.
- De inlogbeperking (B3) blijft gewoon van kracht.

Fase 2 - Bulk (optioneel)
- Offline script (net als `SeedTestPasswords`: `-Confirm`-guard, eerst alleen
  tegen een test-/staging-kopie) dat `PasswordHash` vult voor gebruikers die
  nog niet ingelogd hebben. Per rij een eigen transactie, idempotent (rijen
  met hash overslaan), met telling en logging zonder wachtwoorden.

Fase 3 - Afdwingen (`hash`)
- Pas wanneer (a) alle actieve gebruikers een hash hebben en (b) de
  legacy-app niet meer van `Password` afhangt: `AUTH_PASSWORD_MODE=hash` en
  de plaintext-kolom leegmaken of verwijderen (apart besluit, niet
  terugdraaibaar zonder back-up).
- Gebruikers die na X maanden nooit inlogden: reset via beheerder.

## 5. Rollback
- Fase 1-2 zijn volledig terug te draaien: `AUTH_PASSWORD_MODE=plain` zetten
  (herstart PASOE); plaintext is nooit aangeraakt. De kolom `PasswordHash`
  kan blijven staan of door de eigenaar worden geleegd.
- Fase 3 (plaintext verwijderd): rollback = terugzetten uit de beveiligde
  back-up van fase 0 en `AUTH_PASSWORD_MODE=plain`. Daarom: plaintext pas
  verwijderen na een afgesproken observatieperiode.
- Elke fase heeft een stopvoorwaarde: foutpercentage van logins, klachten
  van gebruikers, afwijkingen in de legacy-app.

## 6. Test- en opvolgpunten
- Test van hash/verify (bekende vectoren, verkeerd wachtwoord, onbekend
  prefix, lege waarde) in een tijdelijk .p, zoals voor B3.
- Gelijktijdige login via legacy-app en Luna op dezelfde rij testen.
- Seed-scripts (`SeedTestPasswords`) moeten daarna hashes schrijven.
- Los hiervan: `authenticationToken.token` staat ook leesbaar in de database
  (een gelekte tabel = bruikbare sessies); hashing van tokens is een
  aparte, goedkope vervolgstap.
