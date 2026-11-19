# Databaseschema `lunanew`

LunaV12 bevat geen volledige schemadump, enkel incrementele scripts
(`T:\LunaV12\Conversie\Delta-*.df`, ±190 tabellen samen). Hier hoort de **volledige** definitie.

## Dump maken (handmatig, eenmalig en na elke schemawijziging)

Gebruik een **kopie** — nooit de bestanden in `T:\LunaV12` zelf openen.

1. Verbind met de test-DB `LunaNew` (zelfde verbinding als PASOE, read-only volstaat) of met een
   kopie van `T:\LunaV12\Leeg\LunaNew.db`.
2. Data Dictionary → *Admin → Dump Data and Definitions → Data Definitions (.df)* → *ALL* tabellen.
3. Bewaar als `docs/schema/lunanew.df` en commit (diff toont schemawijzigingen).

Batch-alternatief:

```
_progres -b -db LunaNew <verbindingsparameters> -p prodict/dump_df.p -param "ALL,docs/schema/lunanew.df,"
```

## Tabelnotities

Leg per tabel betekenis van niet-evidente velden vast in `docs/modules/<module>.md`
(onder "Tabellen"), niet hier.
