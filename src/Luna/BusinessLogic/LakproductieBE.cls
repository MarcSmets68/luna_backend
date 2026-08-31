/*------------------------------------------------------------------------
    File        : LakproductieBE.cls
    Purpose     : Business Entity for the "Lakproduktie" overview - a
                  reporting/planning list of every artikel-line that still
                  needs to go through external coating (lak/anodizing),
                  gathered from 3 sources, discriminated by the `bron`
                  field on the single flat result temp-table:
                    - "lopende-orders": open klantorder-lijnen (bonlijn)
                      with an outstanding te-leveren quantity.
                    - "lopende-productielijnen": production-line detail
                      records (bonlijn_productie) for those same orders.
                    - "min-max-voorraad": stock-level artikels that have
                      dropped below their minimum voorraad (min-max
                      re-order advice), independent of any specific order.
    Business rule (confirmed with Marc, 2026-08-17 - full rework):
                  - Replaces the previous (2026-08-10/13) "not yet ordered
                    lak/anodizing lines" interpretation entirely. This is a
                    1:1 port of the legacy 4GL export tool
                    N:\LunaV12\ExportLakProductie.w (procedures
                    lopende-orders / lopende-productielijnen /
                    berekening-voorraad+min-max-voorraad), plus its helpers
                    N:\LunaV12\GetKleur.p (ResolveKleur() below) and
                    N:\LunaV12\Update\GetTree.p (superseded by
                    Luna.BusinessLogic.LakproductieVerkoopService's
                    ResolveBrutArtnr(), which fixes a dead-code bug in the
                    legacy walk - see that class's header for details).
                  - Every row carries every field in ttLakproductieLine;
                    fields that don't apply to a row's `bron` are left as
                    the ABL unknown value (?) so they serialize as JSON
                    null (not 0/"") - except a handful of character/
                    logical fields that legacy always gives a concrete
                    value for regardless of source (kleursoort/kleurkode/
                    afwerking/techniek/groepeerKleur: "" when undetermined;
                    voorbewerkingNodig/kleurOnbepaald: always TRUE/FALSE,
                    never unknown).
                  - Rolling sales figures (verkoop1/3/6/9/12Maand) are
                    computed ONCE up front, shared by all 3 sources, via
                    Luna.BusinessLogic.LakproductieVerkoopService -see that
                    class for the full rules (base pass over recent
                    bonlijn history, brut-artikel chain crediting,
                    composite-article decomposition).
                  - Deadline / maatBevestigd / kleurOnbepaald semantics
                    (sources a + b only, ResolveDeadlineAndMaat() below):
                    ported directly from the legacy .w's swLed / non-swLed
                    branches (lines ~491-534 for lopende-orders, ~680-712
                    for lopende-productielijnen). Notably:
                      - Non-swLed lines: maatBevestigd is left unknown (?)
                        - legacy's pcMaat = "NVT" - and, for source a only,
                          kleurOnbepaald is forced TRUE (legacy's ELSE
                          branch literally sets swKleurOnbepaald = TRUE,
                          not FALSE - verified against the .w source, not
                          assumed).
                      - Source b (lopende-productielijnen) never computes
                        kleurOnbepaald at all - its swLed branch only does
                        the deadline + maatBevestigd bon_led lookups, not
                        the third (led_lijn=1/lijnnr=1) one that source a
                        does. kleurOnbepaald is therefore always FALSE for
                        every "lopende-productielijnen" row, regardless of
                        swLed - confirmed by re-reading the .w, not
                        inferred.
                  - Kleur resolution differs by source - re-verified against
                    the .w line-by-line rather than relying on a summary:
                      - Source a (lopende-orders): if
                        artikel.led-kenmerk = "SIKTA", the kleur fields stay
                        "" (legacy does NOT call GetKleur.p in that case,
                        unlike an earlier draft of this rework which assumed
                        SiktaKleurKodes[1] was always used - corrected here
                        after re-reading ExportLakProductie.w lines 618-636).
                        Otherwise, ResolveKleur() is called with
                        bonlijn.SiktaKleurKodes[1] when it is filled in.
                      - Source b (lopende-productielijnen): when
                        artikel.led-kenmerk = "SIKTA", a nested
                        Inbouw/Opbouw branch (keyed off the PARENT
                        bonlijn's own artnr and SiktaKleurKodes - not
                        bonlijn_productie's) picks which SiktaKleurKodes
                        index (1/2/3/4/5) to resolve, based on substrings
                        of the production-line's OWN artikel omschrijving
                        (FIX/TILT/HINGE/SKIRT/COAT) - ported exactly,
                        including what looks like a legacy quirk (reading
                        bonlijn.artnr, the parent line's artnr, as the
                        selector instead of bonlijn_productie.artnr). If no
                        branch matches, the kleur fields stay "" (no
                        default to index 1). When led-kenmerk <> "SIKTA",
                        same as source a: SiktaKleurKodes[1] on the PARENT
                        bonlijn when filled in.
                      - Source c (min-max-voorraad): never calls
                        ResolveKleur() - there is no order-line context to
                        source a SiktaKleurKodes array from for a
                        standalone artikel, so kleur fields are always "".
                  - voorbewerkingNodig for min-max-voorraad rows is
                    hardcoded FALSE, NOT artikel.swVoorbewerking - this
                    matches the legacy export literally hardcoding "Nee"
                    for this source (line ~1053) and was intentionally not
                    "fixed", per Marc.
                  - groepeerKleur is carried over from the pre-2026-08-17
                    BE (was BuildGroepeerKleurLabel(), fed by the old
                    text-enrichment EnrichKleurInfo() output) but now fed
                    by the new ResolveKleur()/GetKleur.p-derived fields
                    instead - same "techniek · kleurkode · afwerking"
                    label, falling back to the raw behandeling
                    (artikel.led-coating) code when nothing could be
                    derived.
                  - gereserveerdVoorraad (artikel.gereserveerd) is
                    RENAMED from the prior iteration's `gereserveerd` field
                    to disambiguate it from the new line-level
                    `lijnGereserveerd` (bonlijn.gereserv /
                    bonlijn_productie.gereserv) - these are two unrelated
                    numbers (stock-level vs order-line-level reservation).
    Business rule (confirmed with Marc, 2026-08-17 - hide fully-reserved
                  lines; extended 2026-08-18 - also hide already-ordered
                  lines):
                  - Lines whose computed status is "Gereserveerd" (fully
                    covered by existing stock reservation - see
                    ResolveStatus()) are dropped from the overview
                    entirely, for both source a (lopende-orders) and
                    source b (lopende-productielijnen) - checked right
                    after the status is resolved, before the rest of that
                    line's fields are looked up, so the (relatively
                    expensive) kleur/leverancier/order lookups are skipped
                    for lines that get discarded anyway. A "Deels
                    gereserveerd" line still needs the remainder treated,
                    so it stays. Source c (min-max-voorraad) has no status
                    concept and is unaffected.
                  - Lines whose computed status is "Besteld" (already
                    ordered from the leverancier) are dropped from the
                    overview the same way - lakproductie only needs to
                    show articles that still require action, and an
                    already-placed order is no longer actionable there.
                    Same scope as above: sources a/b only, checked
                    alongside the "Gereserveerd" check.
    Business rule (confirmed with Marc, 2026-08-17 - kleur uit
                  omschrijving / genormaliseerde groepering):
                  - Identical colors must group together on the frontend
                    even when written differently (e.g. RAL 9005 zwart
                    showing up as 4+ different behandeling-code spellings
                    across artikelen) - a live sample showed the majority
                    of lines (192 of 203) had no kleur at all because
                    ResolveKleur() only works from bonlijn.SiktaKleurKodes,
                    which is frequently empty or deliberately skipped
                    (SIKTA exception). ResolveKleurUitOmschrijving() (see
                    its own header for the full algorithm) is a new
                    fallback, applied to ALL 3 sources whenever
                    ResolveKleur() left kleursoort/kleurkode empty,
                    including SIKTA-affected lines - it extracts
                    techniek/kleursoort/kleurkode/afwerking from free text
                    (omschrijving first, artikel.led-coating/behandeling
                    second), confirmed against a live sample of real
                    omschrijving/behandeling text during this rework.
                  - Techniek (ANO vs. LAK-family) is always resolved
                    first and is the hard boundary for grouping/
                    canonicalization - a kale kleurnaam like "ZWART" is
                    only rewritten to its RAL-equivalent (RAL 9005 for
                    ZWART, RAL 9016 for WIT) when the techniek is already
                    LAK-family; ANO keeps the bare kleurnaam and is NEVER
                    converted to a RAL number, since ANO-zwart and
                    LAK-RAL9005-zwart are physically different treatments
                    that must never end up in the same groepeerKleur
                    group (explicitly confirmed with Marc: "zwart kan ook
                    ANO zijn, opletten om de 2 uit elkaar te houden").
                  - BuildGroepeerKleurLabel() no longer blindly falls back
                    to the raw behandeling code for every unresolved line:
                    "(#COLOR)" placeholders, "Special Custom"/SC, and
                    plain "Geborsteld"/"Borstelen" (no lak/anodizing at
                    all) each get their own recognizable label instead -
                    see that method's header for the exact rules.
    Business rule (confirmed with Marc, 2026-08-24 - Special Production
                  exception):
                  - Artikel NOMALED.SPECIAL PRODUCTION (verzamelartikel
                    zonder led-alu/led-coating - led-kenmerk "-----",
                    led-type "Toebehoren") is een placeholder, geen
                    echt te coaten profiel, maar moet toch in de
                    lakproduktie-lijst verschijnen in een eigen vaste
                    groep "Special Production" (source a,
                    lopende-orders, only - er bestaan geen
                    bonlijn_productie-records voor dit artnr).
                  - Twee afwijkingen t.o.v. de normale lopende-orders-
                    flow, allemaal exclusief voor dit ene artnr (via
                    cSpecialProductionArtnr), elders ongewijzigd:
                    1. De artikel-join-conditie (artikel.led-alu NE "")
                       sluit dit artikel normaal uit (led-alu is leeg)
                       - uitgebreid met een OR-uitzondering op artnr.
                    2. Kleur-resolutie (ResolveKleur /
                       ResolveKleurUitOmschrijving) wordt voor dit
                       artnr helemaal overgeslagen - groepeerKleur
                       wordt hard op "Special Production"
                       (cSpecialProductionGroep) gezet, kleursoort/
                       kleurkode/afwerking/techniek blijven "".
                  - Revised same day (confirmed with Marc): the
                    "Gereserveerd"/"Besteld"-drop-regel (zie hierboven,
                    2026-08-17/18) is NIET uitgezonderd voor dit artnr -
                    ze geldt hier net als voor elk ander artikel, zodat
                    enkel nog-openstaande ("Nog te bestellen"/"Deels
                    gereserveerd") Special Production-regels verschijnen.
                    Een eerdere versie van deze regel (dezelfde dag)
                    zonderde dit artnr ook van die drop uit - dat is
                    hiermee teruggedraaid.
    Syntax      : Called from Luna.Web.LakproductieHandler (GET /lakproduktie)
    Description : Owns all DB access for this feature - no direct DB
                  access is allowed from the WebHandler layer. NO-LOCK
                  reads only - this is a read-only overview.
    Author(s)   : Devin
    Created     : 2026-08-10
    Reworked    : 2026-08-17
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Luna.BusinessLogic.LakproductieVerkoopService.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LakproductieBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so the API response reads as {"items": [...]}. One
       flat temp-table for all 3 sources, discriminated by `bron`. */
    DEFINE TEMP-TABLE ttLakproductieLine NO-UNDO SERIALIZE-NAME "items":u
        FIELD bron                 AS CHARACTER SERIALIZE-NAME "bron":u
        FIELD artnr                AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschrijving         AS CHARACTER SERIALIZE-NAME "omschrijving":u
        FIELD ledAlu               AS CHARACTER SERIALIZE-NAME "ledAlu":u
        FIELD behandeling          AS CHARACTER SERIALIZE-NAME "behandeling":u
        FIELD kleursoort           AS CHARACTER SERIALIZE-NAME "kleursoort":u
        FIELD kleurkode            AS CHARACTER SERIALIZE-NAME "kleurkode":u
        FIELD afwerking            AS CHARACTER SERIALIZE-NAME "afwerking":u
        FIELD techniek             AS CHARACTER SERIALIZE-NAME "techniek":u
        FIELD groepeerKleur        AS CHARACTER SERIALIZE-NAME "groepeerKleur":u
        FIELD typeAfwerking        AS CHARACTER SERIALIZE-NAME "typeAfwerking":u
        FIELD ledType              AS CHARACTER SERIALIZE-NAME "ledType":u
        FIELD ledKenmerk           AS CHARACTER SERIALIZE-NAME "ledKenmerk":u
        FIELD lakLevnr             AS INTEGER   SERIALIZE-NAME "lakLevnr":u
        FIELD lakNaam              AS CHARACTER SERIALIZE-NAME "lakNaam":u
        FIELD voorraad             AS DECIMAL   SERIALIZE-NAME "voorraad":u
        FIELD gereserveerdVoorraad AS DECIMAL   SERIALIZE-NAME "gereserveerdVoorraad":u
        FIELD extVoorraad          AS DECIMAL   SERIALIZE-NAME "extVoorraad":u
        FIELD extGereserveerd      AS DECIMAL   SERIALIZE-NAME "extGereserveerd":u
        FIELD voorbewerkingNodig   AS LOGICAL   SERIALIZE-NAME "voorbewerkingNodig":u
        FIELD premontageDatum      AS DATE      SERIALIZE-NAME "premontageDatum":u
        FIELD verkoop1Maand        AS DECIMAL   SERIALIZE-NAME "verkoop1Maand":u
        FIELD verkoop3Maand        AS DECIMAL   SERIALIZE-NAME "verkoop3Maand":u
        FIELD verkoop6Maand        AS DECIMAL   SERIALIZE-NAME "verkoop6Maand":u
        FIELD verkoop9Maand        AS DECIMAL   SERIALIZE-NAME "verkoop9Maand":u
        FIELD verkoop12Maand       AS DECIMAL   SERIALIZE-NAME "verkoop12Maand":u
        FIELD bonnr                AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD klant                AS CHARACTER SERIALIZE-NAME "klant":u
        FIELD lijnnr               AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD prodLijnnr           AS INTEGER   SERIALIZE-NAME "prodLijnnr":u
        FIELD groepnr              AS INTEGER   SERIALIZE-NAME "groepnr":u
        FIELD subgroepnr           AS INTEGER   SERIALIZE-NAME "subgroepnr":u
        FIELD aantal               AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD lijnGereserveerd     AS DECIMAL   SERIALIZE-NAME "lijnGereserveerd":u
        FIELD lijnBesteld          AS DECIMAL   SERIALIZE-NAME "lijnBesteld":u
        FIELD lijnStatus           AS CHARACTER SERIALIZE-NAME "status":u
        FIELD deadline             AS DATE      SERIALIZE-NAME "deadline":u
        FIELD ordnr                AS INTEGER   SERIALIZE-NAME "ordnr":u
        FIELD orderLevnr           AS INTEGER   SERIALIZE-NAME "orderLevnr":u
        FIELD orderNaam            AS CHARACTER SERIALIZE-NAME "orderNaam":u
        FIELD orderDatum           AS DATE      SERIALIZE-NAME "orderDatum":u
        FIELD maatBevestigd        AS LOGICAL   SERIALIZE-NAME "maatBevestigd":u
        FIELD kleurOnbepaald       AS LOGICAL   SERIALIZE-NAME "kleurOnbepaald":u
        FIELD bestelAdvies         AS DECIMAL   SERIALIZE-NAME "bestelAdvies":u
        FIELD verpakking           AS DECIMAL   SERIALIZE-NAME "verpakking":u.

    DEFINE PRIVATE VARIABLE cSpecialProductionArtnr AS CHARACTER NO-UNDO
        INITIAL "NOMALED.SPECIAL PRODUCTION":u.
    DEFINE PRIVATE VARIABLE cSpecialProductionGroep AS CHARACTER NO-UNDO
        INITIAL "Special Production":u.

    /*------------------------------------------------------------------------------
        Purpose: Orchestrator - builds all 3 sources into one flat
                 ttLakproductieLine result set.
        Notes  : NO-LOCK reads only throughout.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetOpenLakproductieItems():

        DEFINE VARIABLE oVerkoopService AS LakproductieVerkoopService NO-UNDO.
        DEFINE VARIABLE hVerkoop        AS HANDLE                     NO-UNDO.
        DEFINE VARIABLE hVerkoopBuf     AS HANDLE                     NO-UNDO.

        EMPTY TEMP-TABLE ttLakproductieLine.

        /* Rolling sales figures - computed once, shared by all 3 sources
           below. Consumed through a dynamic buffer since ttVerkoop is
           defined in a different class. */
        oVerkoopService = NEW LakproductieVerkoopService().
        hVerkoop = oVerkoopService:BerekenVerkoopCijfers().
        CREATE BUFFER hVerkoopBuf FOR TABLE hVerkoop.

        BuildLopendeOrders(hVerkoopBuf).
        BuildLopendeProductielijnen(hVerkoopBuf).
        BuildMinMaxVoorraad(hVerkoopBuf).

        DELETE OBJECT hVerkoopBuf.

        RETURN TEMP-TABLE ttLakproductieLine:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Source (a) "lopende-orders" - ports legacy procedure
                 lopende-orders (ExportLakProductie.w). Every open
                 klantorder-lijn (bonlijn) with a non-zero te-leveren
                 quantity, for an artikel that has a led-alu (i.e. is a
                 LED aluminium profile needing coating).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BuildLopendeOrders( INPUT hVerkoopBuf AS HANDLE ):

        DEFINE VARIABLE cKleursoort     AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cKleurkode      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cAfwerking      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cTechniek       AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dDeadline       AS DATE      NO-UNDO.
        DEFINE VARIABLE lMaatBevestigd  AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE lKleurOnbepaald AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE dPremontage     AS DATE      NO-UNDO.
        DEFINE VARIABLE iLakLevnr       AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cLakNaam        AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iOrdnr          AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iOrderLevnr     AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cOrderNaam      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dOrderDatum     AS DATE      NO-UNDO.
        DEFINE VARIABLE dV1             AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dV3             AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dV6             AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dV9             AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dV12            AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE cStatus         AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lIsSpecialProduction AS LOGICAL   NO-UNDO.

        FOR EACH bonlijn NO-LOCK
            WHERE bonlijn.te-leveren NE 0
              AND bonlijn.artnr      NE "":u
              AND bonlijn.kolomtitel EQ FALSE
              AND bonlijn.infolijn   EQ FALSE
              AND bonlijn.subtotaal  EQ FALSE,
            FIRST bon NO-LOCK
                WHERE bon.bonnr = bonlijn.bonnr,
            FIRST artikel NO-LOCK
                WHERE artikel.artnr = bonlijn.artnr
                  AND (artikel.led-alu NE "":u
                       OR artikel.artnr = cSpecialProductionArtnr):

            /* Business rule (confirmed with Marc, 2026-08-17/18): lines
               that are already FULLY reserved (status "Gereserveerd") or
               already ordered from the leverancier (status "Besteld") no
               longer need external coating action and are dropped from
               this overview entirely - a partially-reserved line ("Deels
               gereserveerd") still needs the remainder treated, so it
               stays. This is evaluated up front, before the more
               expensive kleur/leverancier/order lookups below, to skip
               that work for lines we're going to discard anyway. */
            cStatus = ResolveStatus(bonlijn.gereserv, bonlijn.te-leveren, bonlijn.besteld).
            lIsSpecialProduction = (bonlijn.artnr EQ cSpecialProductionArtnr).

            /* Business rule (confirmed with Marc, 2026-08-24, revised same day):
               the Gereserveerd/Besteld drop above DOES apply to
               NOMALED.SPECIAL PRODUCTION lines too, same as every other
               artikel - only lines that are still fully "Nog te bestellen"
               (or "Deels gereserveerd") should surface for this artikel;
               a fully reserved or already-ordered Special Production line
               is no longer actionable, exactly like any other line. The
               earlier same-day rule that exempted this artnr from this
               specific drop was superseded by this correction - the only
               remaining exceptions for this artnr are the led-alu join
               condition below and the fixed groepeerKleur override
               further down; status filtering is NOT one of them. */
            IF cStatus EQ "Gereserveerd":u OR cStatus EQ "Besteld":u THEN NEXT.

            ResolveDeadlineAndMaat(
                bonlijn.bonnr, bonlijn.groepnr, bonlijn.swLed, bon.lev-dat, bon.datum, TRUE,
                OUTPUT dDeadline, OUTPUT lMaatBevestigd, OUTPUT lKleurOnbepaald).

            dPremontage = ResolvePremontageDatum(artikel.swVoorbewerking, bonlijn.bonnr, bonlijn.groepnr).

            ASSIGN cKleursoort = "":u cKleurkode = "":u cAfwerking = "":u cTechniek = "":u.

            IF NOT lIsSpecialProduction THEN DO:
                IF artikel.led-kenmerk NE "SIKTA":u AND bonlijn.SiktaKleurKodes[1] NE "":u THEN
                    ResolveKleur(
                        bonlijn.SiktaKleurKodes[1],
                        OUTPUT cKleursoort, OUTPUT cKleurkode, OUTPUT cAfwerking, OUTPUT cTechniek).

                /* Business rule (confirmed with Marc, 2026-08-17 - kleur uit
                   omschrijving): when the structured SiktaKleurKodes-based
                   resolution above left both kleursoort and kleurkode empty
                   (SIKTA exception, or simply no SiktaKleurKodes filled in),
                   fall back to free-text extraction from omschrijving/
                   behandeling - see ResolveKleurUitOmschrijving() header. */
                IF cKleursoort EQ "":u AND cKleurkode EQ "":u THEN
                    ResolveKleurUitOmschrijving(
                        bonlijn.omschr, artikel.led-coating, artikel.typeAfwerking,
                        OUTPUT cKleursoort, OUTPUT cKleurkode, OUTPUT cAfwerking, OUTPUT cTechniek).
            END.
            /* Business rule (confirmed with Marc, 2026-08-24 - Special Production
               exception): this artikel has no led-alu, no led-coating, and no
               SiktaKleurKodes to resolve a real kleur from - rather than let it
               fall through to ResolveKleurUitOmschrijving() (which would try to
               derive a kleur from free text never meant to describe a coating),
               kleur resolution is skipped entirely for this artnr; groepeerKleur
               is hard-set below (after CREATE ttLakproductieLine, since that's
               the earliest point the field exists) instead of being derived. */

            ResolveLakLeverancier(artikel.led-coating, OUTPUT iLakLevnr, OUTPUT cLakNaam).

            IF bonlijn.besteld NE 0 THEN
                ResolveOrderInfo(
                    bonlijn.bonnr, bonlijn.lijnnr, ?,
                    OUTPUT iOrdnr, OUTPUT iOrderLevnr, OUTPUT cOrderNaam, OUTPUT dOrderDatum).
            ELSE
                ASSIGN iOrdnr = ? iOrderLevnr = ? cOrderNaam = ? dOrderDatum = ?.

            ApplyVerkoop(hVerkoopBuf, bonlijn.artnr, OUTPUT dV1, OUTPUT dV3, OUTPUT dV6, OUTPUT dV9, OUTPUT dV12).

            CREATE ttLakproductieLine.
            ASSIGN
                ttLakproductieLine.bron                 = "lopende-orders":u
                ttLakproductieLine.artnr                = bonlijn.artnr
                ttLakproductieLine.omschrijving         = bonlijn.omschr
                ttLakproductieLine.ledAlu               = artikel.led-alu
                ttLakproductieLine.behandeling          = artikel.led-coating
                ttLakproductieLine.kleursoort           = cKleursoort
                ttLakproductieLine.kleurkode            = cKleurkode
                ttLakproductieLine.afwerking            = cAfwerking
                ttLakproductieLine.techniek             = cTechniek
                ttLakproductieLine.typeAfwerking        = artikel.typeAfwerking
                ttLakproductieLine.ledType              = artikel.led-type
                ttLakproductieLine.ledKenmerk           = artikel.led-kenmerk
                ttLakproductieLine.lakLevnr             = iLakLevnr
                ttLakproductieLine.lakNaam              = cLakNaam
                ttLakproductieLine.voorraad             = artikel.aantal
                ttLakproductieLine.gereserveerdVoorraad = artikel.gereserveerd
                ttLakproductieLine.extVoorraad          = artikel.x-aantal
                ttLakproductieLine.extGereserveerd      = artikel.x-gereserveerd
                ttLakproductieLine.voorbewerkingNodig   = artikel.swVoorbewerking
                ttLakproductieLine.premontageDatum      = dPremontage
                ttLakproductieLine.verkoop1Maand        = dV1
                ttLakproductieLine.verkoop3Maand        = dV3
                ttLakproductieLine.verkoop6Maand        = dV6
                ttLakproductieLine.verkoop9Maand        = dV9
                ttLakproductieLine.verkoop12Maand       = dV12
                ttLakproductieLine.bonnr                = bon.bonnr
                ttLakproductieLine.klant                = bon.naam
                ttLakproductieLine.lijnnr               = bonlijn.lijnnr
                ttLakproductieLine.prodLijnnr           = ?
                ttLakproductieLine.groepnr              = bonlijn.groepnr
                ttLakproductieLine.subgroepnr           = bonlijn.subgroepnr
                ttLakproductieLine.aantal               = bonlijn.te-leveren
                ttLakproductieLine.lijnGereserveerd     = bonlijn.gereserv
                ttLakproductieLine.lijnBesteld          = bonlijn.besteld
                ttLakproductieLine.lijnStatus            = cStatus
                ttLakproductieLine.deadline             = dDeadline
                ttLakproductieLine.ordnr                = iOrdnr
                ttLakproductieLine.orderLevnr           = iOrderLevnr
                ttLakproductieLine.orderNaam            = cOrderNaam
                ttLakproductieLine.orderDatum           = dOrderDatum
                ttLakproductieLine.maatBevestigd        = lMaatBevestigd
                ttLakproductieLine.kleurOnbepaald       = lKleurOnbepaald
                ttLakproductieLine.bestelAdvies         = ?
                ttLakproductieLine.verpakking           = artikel.verpakking
                .
            ttLakproductieLine.groepeerKleur = BuildGroepeerKleurLabel(
                ttLakproductieLine.behandeling, ttLakproductieLine.omschrijving, artikel.typeAfwerking,
                cTechniek, cKleursoort, cKleurkode, cAfwerking).

            IF lIsSpecialProduction THEN
                ttLakproductieLine.groepeerKleur = cSpecialProductionGroep.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Source (b) "lopende-productielijnen" - ports legacy
                 procedure lopende-productielijnen (ExportLakProductie.w).
                 One row per bonlijn_productie (production-line detail)
                 record, joined back to its parent bonlijn/bon for
                 customer/deadline context.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BuildLopendeProductielijnen( INPUT hVerkoopBuf AS HANDLE ):

        DEFINE VARIABLE cArtikelOm      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cKleursoort     AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cKleurkode      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cAfwerking      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cTechniek       AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dDeadline       AS DATE      NO-UNDO.
        DEFINE VARIABLE lMaatBevestigd  AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE lKleurOnbepaald AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE dPremontage     AS DATE      NO-UNDO.
        DEFINE VARIABLE iLakLevnr       AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cLakNaam        AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iOrdnr          AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iOrderLevnr     AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cOrderNaam      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dOrderDatum     AS DATE      NO-UNDO.
        DEFINE VARIABLE dV1             AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dV3             AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dV6             AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dV9             AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dV12            AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE cStatus         AS CHARACTER NO-UNDO.

        DEFINE BUFFER bfArtikelOm FOR artikel.

        FOR EACH bonlijn_productie NO-LOCK,
            FIRST artikel NO-LOCK
                WHERE artikel.artnr   = bonlijn_productie.artnr
                  AND artikel.led-alu NE "":u,
            FIRST bonlijn NO-LOCK
                WHERE bonlijn.bonnr  = bonlijn_productie.bonnr
                  AND bonlijn.lijnnr = bonlijn_productie.blijnnr,
            FIRST bon NO-LOCK
                WHERE bon.bonnr = bonlijn_productie.bonnr:

            /* Business rule (confirmed with Marc, 2026-08-17): see the
               identical check in BuildLopendeOrders() - fully-reserved
               ("Gereserveerd") lines are dropped from this overview, as
               are already-ordered ("Besteld") lines (2026-08-18, see
               class header). */
            cStatus = ResolveStatus(bonlijn_productie.gereserv, bonlijn_productie.aantal, bonlijn_productie.besteld).
            IF cStatus EQ "Gereserveerd":u OR cStatus EQ "Besteld":u THEN NEXT.

            ResolveDeadlineAndMaat(
                bonlijn.bonnr, bonlijn.groepnr, bonlijn.swLed, bon.lev-dat, bon.datum, FALSE,
                OUTPUT dDeadline, OUTPUT lMaatBevestigd, OUTPUT lKleurOnbepaald).

            dPremontage = ResolvePremontageDatum(artikel.swVoorbewerking, bonlijn.bonnr, bonlijn.groepnr).

            FIND FIRST bfArtikelOm NO-LOCK WHERE bfArtikelOm.artnr = bonlijn_productie.artnr NO-ERROR.
            cArtikelOm = (IF AVAILABLE bfArtikelOm THEN bfArtikelOm.omschr-n ELSE "":u).

            /* --- Kleur - source-b-specific SIKTA Inbouw/Opbouw selection,
                   ported exactly from ExportLakProductie.w lines ~804-874,
                   including its use of the PARENT bonlijn's own artnr/
                   SiktaKleurKodes as the selector (not bonlijn_productie's). --- */
            ASSIGN cKleursoort = "":u cKleurkode = "":u cAfwerking = "":u cTechniek = "":u.

            IF artikel.led-kenmerk EQ "SIKTA":u THEN DO:
                IF INDEX(bonlijn.artnr, "80":u, 11) GT 0 THEN DO:
                    IF SUBSTRING(bonlijn.artnr, 4, 1) EQ "F":u OR SUBSTRING(bonlijn.artnr, 4, 1) EQ "T":u THEN DO:
                        /* --- Inbouw: Inner Ring / Outer Ring --- */
                        IF INDEX(cArtikelOm, "FIX":u) GT 0 AND bonlijn.SiktaKleurKodes[4] NE "":u THEN
                            ResolveKleur(
                                bonlijn.SiktaKleurKodes[4],
                                OUTPUT cKleursoort, OUTPUT cKleurkode, OUTPUT cAfwerking, OUTPUT cTechniek).
                        ELSE IF INDEX(cArtikelOm, "TILT":u) GT 0 AND bonlijn.SiktaKleurKodes[5] NE "":u THEN
                            ResolveKleur(
                                bonlijn.SiktaKleurKodes[5],
                                OUTPUT cKleursoort, OUTPUT cKleurkode, OUTPUT cAfwerking, OUTPUT cTechniek).
                    END.
                    ELSE IF SUBSTRING(bonlijn.artnr, 4, 1) EQ "M":u OR SUBSTRING(bonlijn.artnr, 4, 1) EQ "J":u THEN DO:
                        /* --- Opbouw: Hinge / Skirt / Coat --- */
                        IF INDEX(cArtikelOm, "HINGE":u) GT 0 AND bonlijn.SiktaKleurKodes[1] NE "":u THEN
                            ResolveKleur(
                                bonlijn.SiktaKleurKodes[1],
                                OUTPUT cKleursoort, OUTPUT cKleurkode, OUTPUT cAfwerking, OUTPUT cTechniek).
                        ELSE IF INDEX(cArtikelOm, "SKIRT":u) GT 0 AND bonlijn.SiktaKleurKodes[2] NE "":u THEN
                            ResolveKleur(
                                bonlijn.SiktaKleurKodes[2],
                                OUTPUT cKleursoort, OUTPUT cKleurkode, OUTPUT cAfwerking, OUTPUT cTechniek).
                        ELSE IF INDEX(cArtikelOm, "COAT":u) GT 0 AND bonlijn.SiktaKleurKodes[3] NE "":u THEN
                            ResolveKleur(
                                bonlijn.SiktaKleurKodes[3],
                                OUTPUT cKleursoort, OUTPUT cKleurkode, OUTPUT cAfwerking, OUTPUT cTechniek).
                    END.
                    /* else: neither Inbouw nor Opbouw substring matched - kleur stays "". */
                END.
                /* else: INDEX(bonlijn.artnr,"80",11) not found - kleur stays "". */
            END.
            ELSE DO:
                IF bonlijn.SiktaKleurKodes[1] NE "":u THEN
                    ResolveKleur(
                        bonlijn.SiktaKleurKodes[1],
                        OUTPUT cKleursoort, OUTPUT cKleurkode, OUTPUT cAfwerking, OUTPUT cTechniek).
            END.

            /* Business rule (confirmed with Marc, 2026-08-17 - kleur uit
               omschrijving): see the identical fallback in
               BuildLopendeOrders() - applies here too whenever none of
               the SIKTA Inbouw/Opbouw branches above (or the plain
               SiktaKleurKodes[1] lookup) resolved anything. */
            IF cKleursoort EQ "":u AND cKleurkode EQ "":u THEN
                ResolveKleurUitOmschrijving(
                    cArtikelOm, artikel.led-coating, artikel.typeAfwerking,
                    OUTPUT cKleursoort, OUTPUT cKleurkode, OUTPUT cAfwerking, OUTPUT cTechniek).

            ResolveLakLeverancier(artikel.led-coating, OUTPUT iLakLevnr, OUTPUT cLakNaam).

            IF bonlijn_productie.besteld NE 0 THEN
                ResolveOrderInfo(
                    bonlijn_productie.bonnr, bonlijn_productie.blijnnr, bonlijn_productie.lijnnr,
                    OUTPUT iOrdnr, OUTPUT iOrderLevnr, OUTPUT cOrderNaam, OUTPUT dOrderDatum).
            ELSE
                ASSIGN iOrdnr = ? iOrderLevnr = ? cOrderNaam = ? dOrderDatum = ?.

            ApplyVerkoop(hVerkoopBuf, bonlijn_productie.artnr, OUTPUT dV1, OUTPUT dV3, OUTPUT dV6, OUTPUT dV9, OUTPUT dV12).

            CREATE ttLakproductieLine.
            ASSIGN
                ttLakproductieLine.bron                 = "lopende-productielijnen":u
                ttLakproductieLine.artnr                = bonlijn_productie.artnr
                ttLakproductieLine.omschrijving         = cArtikelOm
                ttLakproductieLine.ledAlu               = artikel.led-alu
                ttLakproductieLine.behandeling          = artikel.led-coating
                ttLakproductieLine.kleursoort           = cKleursoort
                ttLakproductieLine.kleurkode            = cKleurkode
                ttLakproductieLine.afwerking            = cAfwerking
                ttLakproductieLine.techniek             = cTechniek
                ttLakproductieLine.typeAfwerking        = artikel.typeAfwerking
                ttLakproductieLine.ledType              = artikel.led-type
                ttLakproductieLine.ledKenmerk           = artikel.led-kenmerk
                ttLakproductieLine.lakLevnr             = iLakLevnr
                ttLakproductieLine.lakNaam              = cLakNaam
                ttLakproductieLine.voorraad             = artikel.aantal
                ttLakproductieLine.gereserveerdVoorraad = artikel.gereserveerd
                ttLakproductieLine.extVoorraad          = artikel.x-aantal
                ttLakproductieLine.extGereserveerd      = artikel.x-gereserveerd
                ttLakproductieLine.voorbewerkingNodig   = artikel.swVoorbewerking
                ttLakproductieLine.premontageDatum      = dPremontage
                ttLakproductieLine.verkoop1Maand        = dV1
                ttLakproductieLine.verkoop3Maand        = dV3
                ttLakproductieLine.verkoop6Maand        = dV6
                ttLakproductieLine.verkoop9Maand        = dV9
                ttLakproductieLine.verkoop12Maand       = dV12
                ttLakproductieLine.bonnr                = bon.bonnr
                ttLakproductieLine.klant                = bon.naam
                ttLakproductieLine.lijnnr               = bonlijn.lijnnr
                ttLakproductieLine.prodLijnnr           = bonlijn_productie.lijnnr
                ttLakproductieLine.groepnr              = bonlijn.groepnr
                ttLakproductieLine.subgroepnr           = bonlijn.subgroepnr
                ttLakproductieLine.aantal               = bonlijn_productie.aantal
                ttLakproductieLine.lijnGereserveerd     = bonlijn_productie.gereserv
                ttLakproductieLine.lijnBesteld          = bonlijn_productie.besteld
                ttLakproductieLine.lijnStatus            = cStatus
                ttLakproductieLine.deadline             = dDeadline
                ttLakproductieLine.ordnr                = iOrdnr
                ttLakproductieLine.orderLevnr           = iOrderLevnr
                ttLakproductieLine.orderNaam            = cOrderNaam
                ttLakproductieLine.orderDatum           = dOrderDatum
                ttLakproductieLine.maatBevestigd        = lMaatBevestigd
                ttLakproductieLine.kleurOnbepaald        = FALSE
                ttLakproductieLine.bestelAdvies         = ?
                ttLakproductieLine.verpakking           = artikel.verpakking
                .
            ttLakproductieLine.groepeerKleur = BuildGroepeerKleurLabel(
                ttLakproductieLine.behandeling, ttLakproductieLine.omschrijving, artikel.typeAfwerking,
                cTechniek, cKleursoort, cKleurkode, cAfwerking).
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Source (c) "min-max-voorraad" - ports legacy procedures
                 berekening-voorraad + min-max-voorraad (combined into one
                 pass here - no intermediate tblArtikel staging table
                 needed). Every stock-managed artikel with a led-alu whose
                 projected stock (on-hand + external + already-ordered-to-
                 be-delivered) has dropped below its minimum voorraad.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BuildMinMaxVoorraad( INPUT hVerkoopBuf AS HANDLE ):

        DEFINE VARIABLE dBesteldLv AS DECIMAL NO-UNDO.
        DEFINE VARIABLE iLakLevnr  AS INTEGER NO-UNDO.
        DEFINE VARIABLE cLakNaam   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dV1        AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dV3        AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dV6        AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dV9        AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dV12       AS DECIMAL NO-UNDO.
        DEFINE VARIABLE cKleursoort AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cKleurkode  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cAfwerking  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cTechniek   AS CHARACTER NO-UNDO.

        FOR EACH artikel NO-LOCK
            WHERE artikel.led-alu NE "":u
              AND artikel.stock   EQ TRUE:

            dBesteldLv = 0.
            FOR EACH ordlijn NO-LOCK
                WHERE ordlijn.artnr      = artikel.artnr
                  AND ordlijn.te-leveren NE 0:
                dBesteldLv = dBesteldLv + ordlijn.te-leveren.
            END.

            IF (artikel.aantal + artikel.x-aantal + dBesteldLv) LT artikel.minv THEN DO:

                ResolveLakLeverancier(artikel.led-coating, OUTPUT iLakLevnr, OUTPUT cLakNaam).
                ApplyVerkoop(hVerkoopBuf, artikel.artnr, OUTPUT dV1, OUTPUT dV3, OUTPUT dV6, OUTPUT dV9, OUTPUT dV12).

                /* Business rule (confirmed with Marc, 2026-08-17 - kleur
                   uit omschrijving): unlike sources a/b, this source has
                   no bonlijn/SiktaKleurKodes context at all (a standalone
                   artikel, not an order line) - so the free-text fallback
                   is the ONLY kleur source here, not a fallback after
                   ResolveKleur(). */
                ResolveKleurUitOmschrijving(
                    artikel.omschr-n, artikel.led-coating, artikel.typeAfwerking,
                    OUTPUT cKleursoort, OUTPUT cKleurkode, OUTPUT cAfwerking, OUTPUT cTechniek).

                CREATE ttLakproductieLine.
                ASSIGN
                    ttLakproductieLine.bron                 = "min-max-voorraad":u
                    ttLakproductieLine.artnr                = artikel.artnr
                    ttLakproductieLine.omschrijving         = artikel.omschr-n
                    ttLakproductieLine.ledAlu               = artikel.led-alu
                    ttLakproductieLine.behandeling          = artikel.led-coating
                    ttLakproductieLine.kleursoort           = cKleursoort
                    ttLakproductieLine.kleurkode            = cKleurkode
                    ttLakproductieLine.afwerking            = cAfwerking
                    ttLakproductieLine.techniek             = cTechniek
                    ttLakproductieLine.typeAfwerking        = artikel.typeAfwerking
                    ttLakproductieLine.ledType              = artikel.led-type
                    ttLakproductieLine.ledKenmerk           = artikel.led-kenmerk
                    ttLakproductieLine.lakLevnr             = iLakLevnr
                    ttLakproductieLine.lakNaam              = cLakNaam
                    ttLakproductieLine.voorraad             = artikel.aantal
                    ttLakproductieLine.gereserveerdVoorraad = artikel.gereserveerd
                    ttLakproductieLine.extVoorraad          = artikel.x-aantal
                    ttLakproductieLine.extGereserveerd      = artikel.x-gereserveerd
                    ttLakproductieLine.voorbewerkingNodig   = FALSE
                    ttLakproductieLine.premontageDatum      = ?
                    ttLakproductieLine.verkoop1Maand        = dV1
                    ttLakproductieLine.verkoop3Maand        = dV3
                    ttLakproductieLine.verkoop6Maand        = dV6
                    ttLakproductieLine.verkoop9Maand        = dV9
                    ttLakproductieLine.verkoop12Maand       = dV12
                    ttLakproductieLine.bonnr                = ?
                    ttLakproductieLine.klant                = ?
                    ttLakproductieLine.lijnnr               = ?
                    ttLakproductieLine.prodLijnnr           = ?
                    ttLakproductieLine.groepnr              = ?
                    ttLakproductieLine.subgroepnr           = ?
                    ttLakproductieLine.aantal               = ?
                    ttLakproductieLine.lijnGereserveerd     = ?
                    ttLakproductieLine.lijnBesteld          = ?
                    ttLakproductieLine.lijnStatus            = ?
                    ttLakproductieLine.deadline             = ?
                    ttLakproductieLine.ordnr                = ?
                    ttLakproductieLine.orderLevnr           = ?
                    ttLakproductieLine.orderNaam            = ?
                    ttLakproductieLine.orderDatum           = ?
                    ttLakproductieLine.maatBevestigd        = ?
                    ttLakproductieLine.kleurOnbepaald       = FALSE
                    ttLakproductieLine.bestelAdvies         = artikel.maxv - (artikel.aantal + artikel.x-aantal + dBesteldLv)
                    ttLakproductieLine.verpakking           = artikel.verpakking
                    .
                ttLakproductieLine.groepeerKleur = BuildGroepeerKleurLabel(
                    ttLakproductieLine.behandeling, ttLakproductieLine.omschrijving, artikel.typeAfwerking,
                    cTechniek, cKleursoort, cKleurkode, cAfwerking).
            END.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Looks up pcArtnr's rolling sales totals in the dynamic
                 ttVerkoop buffer built by LakproductieVerkoopService,
                 returning 0 for every bucket when the artnr has no
                 recent sales history.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyVerkoop(
        INPUT  hVerkoopBuf AS HANDLE,
        INPUT  pcArtnr     AS CHARACTER,
        OUTPUT pdV1        AS DECIMAL,
        OUTPUT pdV3        AS DECIMAL,
        OUTPUT pdV6        AS DECIMAL,
        OUTPUT pdV9        AS DECIMAL,
        OUTPUT pdV12       AS DECIMAL ):

        ASSIGN pdV1 = 0 pdV3 = 0 pdV6 = 0 pdV9 = 0 pdV12 = 0.

        hVerkoopBuf:FIND-FIRST("WHERE artnr = ":u + QUOTER(pcArtnr)) NO-ERROR.

        IF hVerkoopBuf:AVAILABLE THEN
            ASSIGN
                pdV1  = DECIMAL(hVerkoopBuf:BUFFER-FIELD("v1":u):BUFFER-VALUE)
                pdV3  = DECIMAL(hVerkoopBuf:BUFFER-FIELD("v3":u):BUFFER-VALUE)
                pdV6  = DECIMAL(hVerkoopBuf:BUFFER-FIELD("v6":u):BUFFER-VALUE)
                pdV9  = DECIMAL(hVerkoopBuf:BUFFER-FIELD("v9":u):BUFFER-VALUE)
                pdV12 = DECIMAL(hVerkoopBuf:BUFFER-FIELD("v12":u):BUFFER-VALUE).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: The 4-state status shared by sources a/b - ported directly
                 from ExportLakProductie.w's inline status logic (identical
                 in both lopende-orders and lopende-productielijnen).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER ResolveStatus(
        INPUT pdGereserv          AS DECIMAL,
        INPUT pdAantalOrTeLeveren AS DECIMAL,
        INPUT pdBesteld           AS DECIMAL ):

        IF pdGereserv NE 0 THEN DO:
            IF pdGereserv NE pdAantalOrTeLeveren THEN
                RETURN "Deels gereserveerd":u.
            ELSE
                RETURN "Gereserveerd":u.
        END.
        ELSE IF pdBesteld NE 0 THEN
            RETURN "Besteld":u.

        RETURN "Nog te bestellen":u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deadline / maatBevestigd / kleurOnbepaald resolver shared
                 by sources a/b - ported from ExportLakProductie.w's
                 swLed / non-swLed branches (identical bon_led lookups in
                 both lopende-orders and lopende-productielijnen, except
                 that lopende-productielijnen never computes
                 kleurOnbepaald - controlled here via
                 plComputeKleurOnbepaald, TRUE for source a, FALSE for
                 source b).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ResolveDeadlineAndMaat(
        INPUT  piBonnr                AS INTEGER,
        INPUT  piGroepnr              AS INTEGER,
        INPUT  plSwLed                AS LOGICAL,
        INPUT  pdBonLevDat            AS DATE,
        INPUT  pdBonDatum             AS DATE,
        INPUT  plComputeKleurOnbepaald AS LOGICAL,
        OUTPUT pdDeadline             AS DATE,
        OUTPUT plMaatBevestigd        AS LOGICAL,
        OUTPUT plKleurOnbepaald       AS LOGICAL ):

        DEFINE BUFFER bfBonLed FOR bon_led.

        ASSIGN pdDeadline = ? plMaatBevestigd = ? plKleurOnbepaald = FALSE.

        IF plSwLed THEN DO:

            FIND FIRST bfBonLed NO-LOCK
                WHERE bfBonLed.bonnr    = piBonnr
                  AND bfBonLed.groepnr  = piGroepnr
                  AND bfBonLed.led_lijn = 0
                  AND bfBonLed.lijnnr   = 30 NO-ERROR.
            IF AVAILABLE bfBonLed THEN
                pdDeadline = bfBonLed.datum.
            ELSE IF pdBonLevDat NE ? THEN
                pdDeadline = pdBonLevDat.
            ELSE
                pdDeadline = pdBonDatum.

            FIND FIRST bfBonLed NO-LOCK
                WHERE bfBonLed.bonnr    = piBonnr
                  AND bfBonLed.groepnr  = piGroepnr
                  AND bfBonLed.led_lijn = 0
                  AND bfBonLed.lijnnr   = 31 NO-ERROR.
            IF AVAILABLE bfBonLed AND bfBonLed.switch1 THEN
                plMaatBevestigd = TRUE.
            ELSE
                plMaatBevestigd = FALSE.

            IF plComputeKleurOnbepaald THEN DO:
                FIND FIRST bfBonLed NO-LOCK
                    WHERE bfBonLed.bonnr    = piBonnr
                      AND bfBonLed.groepnr  = piGroepnr
                      AND bfBonLed.led_lijn = 1
                      AND bfBonLed.lijnnr   = 1 NO-ERROR.
                IF AVAILABLE bfBonLed AND bfBonLed.switch1 THEN
                    plKleurOnbepaald = TRUE.
                ELSE
                    plKleurOnbepaald = FALSE.
            END.

        END.
        ELSE DO:

            IF pdBonLevDat NE ? THEN
                pdDeadline = pdBonLevDat.
            ELSE
                pdDeadline = pdBonDatum.

            plMaatBevestigd = ?.

            /* Legacy's non-swLed ELSE branch literally sets
               swKleurOnbepaald = TRUE for source a (pcMaat = "NVT") - not
               FALSE. Source b never reaches here with
               plComputeKleurOnbepaald = TRUE, so this only matters for
               source a. */
            IF plComputeKleurOnbepaald THEN
                plKleurOnbepaald = TRUE.
            ELSE
                plKleurOnbepaald = FALSE.

        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: premontageDatum resolver shared by sources a/b - ported
                 from ExportLakProductie.w's identical
                 swVoorbewerking/bfBonlijn.montage block in both
                 lopende-orders and lopende-productielijnen.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DATE ResolvePremontageDatum(
        INPUT plSwVoorbewerking AS LOGICAL,
        INPUT piBonnr           AS INTEGER,
        INPUT piGroepnr         AS INTEGER ):

        DEFINE BUFFER bfBonlijnMontage FOR bonlijn.

        IF NOT plSwVoorbewerking THEN
            RETURN ?.

        FIND FIRST bfBonlijnMontage NO-LOCK
            WHERE bfBonlijnMontage.bonnr   = piBonnr
              AND bfBonlijnMontage.groepnr = piGroepnr
              AND bfBonlijnMontage.montage NO-ERROR.

        IF AVAILABLE bfBonlijnMontage AND bfBonlijnMontage.premontage-datum NE ? THEN
            RETURN bfBonlijnMontage.premontage-datum.

        RETURN ?.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Resolves the coating supplier (levnr/naam) via the
                 artikel pointed to by a led-coating value - shared by all
                 3 sources (each passes its own row's artikel.led-coating).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ResolveLakLeverancier(
        INPUT  pcLedCoatingArtnr AS CHARACTER,
        OUTPUT piLakLevnr        AS INTEGER,
        OUTPUT pcLakNaam         AS CHARACTER ):

        DEFINE BUFFER bfArtikelLak FOR artikel.

        ASSIGN piLakLevnr = 0 pcLakNaam = "":u.

        FIND FIRST bfArtikelLak NO-LOCK WHERE bfArtikelLak.artnr = pcLedCoatingArtnr NO-ERROR.
        IF AVAILABLE bfArtikelLak THEN DO:
            FIND FIRST lever NO-LOCK WHERE lever.levnr = bfArtikelLak.levnr NO-ERROR.
            IF AVAILABLE lever THEN
                ASSIGN piLakLevnr = lever.levnr pcLakNaam = lever.naam.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Purchase-order info (ordnr/orderLevnr/orderNaam/orderDatum)
                 shared by sources a/b - looked up via ordlijn, only ever
                 called when the caller's own besteld field is non-zero.
                 piVolgnr = ? (unknown) means "don't filter on volgnr"
                 (source a); a real value filters on it too (source b).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ResolveOrderInfo(
        INPUT  piBonnr      AS INTEGER,
        INPUT  piBlijnnr    AS INTEGER,
        INPUT  piVolgnr     AS INTEGER,
        OUTPUT piOrdnr      AS INTEGER,
        OUTPUT piOrderLevnr AS INTEGER,
        OUTPUT pcOrderNaam  AS CHARACTER,
        OUTPUT pdOrderDatum AS DATE ):

        DEFINE BUFFER bfOrdlijn FOR ordlijn.

        ASSIGN piOrdnr = ? piOrderLevnr = ? pcOrderNaam = ? pdOrderDatum = ?.

        IF piVolgnr EQ ? THEN
            FIND FIRST bfOrdlijn NO-LOCK
                WHERE bfOrdlijn.bonnr   = piBonnr
                  AND bfOrdlijn.blijnnr = piBlijnnr NO-ERROR.
        ELSE
            FIND FIRST bfOrdlijn NO-LOCK
                WHERE bfOrdlijn.bonnr   = piBonnr
                  AND bfOrdlijn.blijnnr = piBlijnnr
                  AND bfOrdlijn.volgnr  = piVolgnr NO-ERROR.

        IF AVAILABLE bfOrdlijn THEN DO:
            FIND FIRST order NO-LOCK WHERE order.ordnr = bfOrdlijn.ordnr NO-ERROR.
            IF AVAILABLE order THEN
                ASSIGN
                    piOrdnr      = order.ordnr
                    piOrderLevnr = order.levnr
                    pcOrderNaam  = order.naam
                    pdOrderDatum = order.datum.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: 1:1 port of N:\LunaV12\GetKleur.p - splits a
                 ";"-delimited SiktaKleurKodes entry
                 (kleursoort;kleurkode;afwerking;techniek) into the 4
                 output fields, resolving techniek/afwerking/kleurkode
                 against the led_laktechniek/led_kleurafwerking/led_SC/
                 led_SP/led_VeroMetal reference tables exactly as the
                 legacy .p does. All 4 outputs are "" when pcKleurKodes
                 doesn't split into exactly 4 entries.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ResolveKleur(
        INPUT  pcKleurKodes AS CHARACTER,
        OUTPUT pcKleursoort AS CHARACTER,
        OUTPUT pcKleurkode  AS CHARACTER,
        OUTPUT pcAfwerking  AS CHARACTER,
        OUTPUT pcTechniek   AS CHARACTER ):

        DEFINE BUFFER bfLedLaktechniek    FOR led_laktechniek.
        DEFINE BUFFER bfLedKleurafwerking FOR led_kleurafwerking.
        DEFINE BUFFER bfLedSc             FOR led_SC.
        DEFINE BUFFER bfLedSp             FOR led_SP.
        DEFINE BUFFER bfLedVeroMetal      FOR led_VeroMetal.

        IF NUM-ENTRIES(pcKleurKodes, ";":u) EQ 4 THEN DO:

            ASSIGN
                pcKleursoort = ENTRY(1, pcKleurKodes, ";":u)
                pcKleurkode  = ENTRY(2, pcKleurKodes, ";":u)
                pcAfwerking  = ENTRY(3, pcKleurKodes, ";":u)
                pcTechniek   = ENTRY(4, pcKleurKodes, ";":u).

            FIND FIRST bfLedLaktechniek NO-LOCK WHERE bfLedLaktechniek.kode = pcTechniek NO-ERROR.
            IF AVAILABLE bfLedLaktechniek THEN
                pcTechniek = (IF bfLedLaktechniek.kode EQ "NVT":u THEN "":u ELSE bfLedLaktechniek.omschr).

            CASE pcKleursoort:
                WHEN "NCS":u THEN DO:
                    IF pcAfwerking EQ "X":u THEN
                        pcAfwerking = "":u.
                    ELSE DO:
                        FIND FIRST bfLedKleurafwerking NO-LOCK
                            WHERE bfLedKleurafwerking.kleursoort = "NCS":u
                              AND bfLedKleurafwerking.kode       = pcAfwerking NO-ERROR.
                        IF AVAILABLE bfLedKleurafwerking THEN
                            pcAfwerking = bfLedKleurafwerking.omschr.
                    END.
                END.
                WHEN "RAL":u THEN DO:
                    IF pcAfwerking EQ "X":u THEN
                        pcAfwerking = "":u.
                    ELSE DO:
                        FIND FIRST bfLedKleurafwerking NO-LOCK
                            WHERE bfLedKleurafwerking.kleursoort = "RAL":u
                              AND bfLedKleurafwerking.kode       = pcAfwerking NO-ERROR.
                        IF AVAILABLE bfLedKleurafwerking THEN
                            pcAfwerking = bfLedKleurafwerking.omschr.
                    END.
                END.
                WHEN "SC":u THEN DO:
                    FIND FIRST bfLedSc NO-LOCK WHERE bfLedSc.sc = pcKleurkode NO-ERROR.
                    IF AVAILABLE bfLedSc THEN
                        pcKleurkode = bfLedSc.omschrijving.

                    IF pcAfwerking EQ "X":u THEN
                        pcAfwerking = "":u.
                    ELSE DO:
                        FIND FIRST bfLedKleurafwerking NO-LOCK
                            WHERE bfLedKleurafwerking.kleursoort = "SC":u
                              AND bfLedKleurafwerking.kode       = pcAfwerking NO-ERROR.
                        IF AVAILABLE bfLedKleurafwerking THEN
                            pcAfwerking = bfLedKleurafwerking.omschr.
                    END.
                END.
                WHEN "SP":u THEN DO:
                    FIND FIRST bfLedSp NO-LOCK WHERE bfLedSp.kode = pcKleurkode NO-ERROR.
                    IF AVAILABLE bfLedSp THEN
                        pcKleurkode = bfLedSp.omschrijving.

                    IF pcAfwerking EQ "X":u THEN
                        pcAfwerking = "":u.
                    ELSE DO:
                        FIND FIRST bfLedKleurafwerking NO-LOCK
                            WHERE bfLedKleurafwerking.kleursoort = "SP":u
                              AND bfLedKleurafwerking.kode       = pcAfwerking NO-ERROR.
                        IF AVAILABLE bfLedKleurafwerking THEN
                            pcAfwerking = bfLedKleurafwerking.omschr.
                    END.
                END.
                WHEN "VM":u THEN DO:
                    FIND FIRST bfLedVeroMetal NO-LOCK WHERE bfLedVeroMetal.kode = pcKleurkode NO-ERROR.
                    IF AVAILABLE bfLedVeroMetal THEN
                        pcKleurkode = bfLedVeroMetal.omschrijving.

                    IF pcAfwerking EQ "X":u THEN
                        pcAfwerking = "":u.
                    ELSE DO:
                        FIND FIRST bfLedKleurafwerking NO-LOCK
                            WHERE bfLedKleurafwerking.kleursoort = "VM":u
                              AND bfLedKleurafwerking.kode       = pcAfwerking NO-ERROR.
                        IF AVAILABLE bfLedKleurafwerking THEN
                            pcAfwerking = bfLedKleurafwerking.omschr.
                    END.
                END.
            END CASE.

        END.
        ELSE
            ASSIGN
                pcKleursoort = "":u
                pcKleurkode  = "":u
                pcAfwerking  = "":u
                pcTechniek   = "":u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Builds the short, human-readable "techniek · kleurkode ·
                 afwerking" label used for frontend grouping (e.g.
                 "ANO · TITANIUM" or "LAK · RAL 9005 · Structuurlak").
        Business rule (confirmed with Marc, 2026-08-17 - kleur uit
                 omschrijving): when neither a techniek nor a kleurkode
                 could be derived at all (neither by ResolveKleur() nor by
                 the ResolveKleurUitOmschrijving() fallback), this no
                 longer blindly falls back to the raw behandeling
                 (artikel.led-coating) code for every case - three
                 genuinely "no fixed color" categories get their own
                 recognizable label instead, so they read as intentional
                 categories rather than a parsing gap:
                   - omschrijving contains the literal "(#COLOR)"
                     placeholder (customer/order-specific color not yet
                     chosen) -> "Kleur nog te bepalen".
                   - omschrijving mentions "SPECIAL CUSTOM", or
                     behandeling has a "SC" dot-segment (led_kleursoort
                     "SC" = Special Custom, a decorative/custom finish
                     with no fixed RAL/NCS equivalent) -> "Special Custom".
                   - typeAfwerking = "Borstelen" (raw brushed aluminium,
                     no lak/anodizing at all - swVoorbewerking-style
                     mechanical finish only) -> "Geen kleur (geborsteld)".
                 Anything else still falls back to the raw behandeling
                 code, unchanged from before.
        Business rule (confirmed with Marc, 2026-08-17 - ANO afwerking
                 negeren voor groepering): afwerking (Mat/Satijn/Glans/
                 Structuur) never splits an ANO group - all ANO items of
                 the same kleurkode belong in one group regardless of
                 surface finish (e.g. "ANO · TITANIUM" covers both matte
                 and satin-finish titanium). Only LAK-family groups
                 (Poedercoating/Natlak) are still split by afwerking. The
                 afwerking value itself is unaffected and still returned/
                 stored on the row as normal - only the grouping label
                 ignores it for ANO.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER BuildGroepeerKleurLabel(
        INPUT pcBehandeling   AS CHARACTER,
        INPUT pcOmschrijving  AS CHARACTER,
        INPUT pcTypeAfwerking AS CHARACTER,
        INPUT pcTechniek      AS CHARACTER,
        INPUT pcKleursoort    AS CHARACTER,
        INPUT pcKleurkode     AS CHARACTER,
        INPUT pcAfwerking     AS CHARACTER ):

        DEFINE VARIABLE cLabel    AS CHARACTER NO-UNDO INITIAL "":u.
        DEFINE VARIABLE cUpperOms AS CHARACTER NO-UNDO.

        IF pcTechniek EQ "":u AND pcKleurkode EQ "":u THEN DO:

            cUpperOms = CAPS(pcOmschrijving).

            IF INDEX(cUpperOms, "(#COLOR)":u) GT 0 THEN
                RETURN "Kleur nog te bepalen":u.

            IF INDEX(cUpperOms, "SPECIAL CUSTOM":u) GT 0
                OR ContainsSegment(CAPS(pcBehandeling), "SC":u) THEN
                RETURN "Special Custom":u.

            IF pcTypeAfwerking EQ "Borstelen":u THEN
                RETURN "Geen kleur (geborsteld)":u.

            RETURN pcBehandeling.
        END.

        IF pcTechniek GT "":u THEN
            cLabel = pcTechniek.

        IF pcKleurkode GT "":u THEN DO:
            IF cLabel GT "":u THEN
                cLabel = cLabel + " ":u + CHR(183) + " ":u.
            IF pcKleursoort EQ "RAL":u THEN
                cLabel = cLabel + "RAL ":u + pcKleurkode.
            ELSE
                cLabel = cLabel + pcKleurkode.
        END.

        /* Business rule (confirmed with Marc, 2026-08-17): afwerking
           (Mat/Satijn/Glans/Structuur) never splits an ANO group - all
           ANO items of the same kleurkode belong together regardless of
           their surface finish. Only LAK-family groups (Poedercoating/
           Natlak) are split by afwerking. */
        IF pcAfwerking GT "":u AND pcTechniek NE "ANO":u THEN DO:
            IF cLabel GT "":u THEN
                cLabel = cLabel + " ":u + CHR(183) + " ":u.
            cLabel = cLabel + pcAfwerking.
        END.

        RETURN cLabel.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Fallback kleur-derivation from free text (omschrijving,
                 with behandeling/artikel.led-coating as a secondary
                 source) - used whenever the structured SiktaKleurKodes-
                 based ResolveKleur() left both kleursoort and kleurkode
                 empty, for ANY of the 3 sources and regardless of why
                 (SIKTA exception, no matching Inbouw/Opbouw branch, or
                 source c which never has SiktaKleurKodes context at all).
        Business rule (confirmed with Marc, 2026-08-17):
                 - Techniek: artikel.typeAfwerking ("ANO"/"LAK") is the
                   most reliable structured signal and is checked first;
                   free-text technique words are only consulted when
                   typeAfwerking is neither of those (blank/"-----"/
                   "Borstelen"). "Natlak"/"Poedercoating"/"structuurlak"/
                   "coatex"/"gelakt"/"LAKKEN" all indicate the LAK family;
                   "ANO"/"geanodiseerd" indicates ANO. Techniek is always
                   resolved BEFORE kleurkode below, because the ZWART/WIT
                   canonicalization step needs to know it first.
                 - Kleurkode: a 4-digit RAL code (from "RAL 9005"/
                   "ral9016"/... in omschrijving, or a bare 4-digit dot-
                   segment in behandeling) wins when present - most
                   precise/unambiguous. Otherwise a named color word
                   (ZWART/WIT/GOUD/BRONS/TITANIUM/GRIJS + EN synonyms
                   BLACK/WHITE/GOLD/BRONZE/GREY/GRAY, NATUREL treated as
                   GRIJS) in omschrijving, then in behandeling, then the
                   AB/ABRO/AG/AT anodizing-abbreviation dot-segments in
                   behandeling (same 4 abbreviations the old, since-
                   removed EnrichKleurInfo() used, verified against real
                   behandeling data during this rework).
                 - Canonicalisatie (why "zwart kan ook ANO zijn" matters,
                   per Marc): a kale kleurnaam is ONLY rewritten to its
                   RAL-equivalent when the techniek is already established
                   as LAK-family (Poedercoating/Natlak) - "ZWART" ->
                   kleursoort RAL/kleurkode "9005", "WIT" -> RAL/"9016".
                   For ANO, the kleurnaam is left as-is (never turned into
                   a RAL number) - ANO-zwart and LAK-RAL9005-zwart are
                   physically different treatments and must never be
                   merged into the same groepeerKleur group. This is the
                   ONLY canonicalization needed: ResolveKleur()'s own
                   SiktaKleurKodes-driven output never produces a bare
                   color name in the first place (it always yields a
                   RAL/NCS/SC/SP/VM code), so nothing there needs
                   re-normalizing.
                 - Afwerking: "structuur"/"structuurlak"/"stuctuurlak"
                   (typo variant confirmed in real data) -> "Structuur";
                   "mat"/"matt" -> "Mat"; "glans" -> "Glans"; "satijn"/
                   "sat" -> "Satijn" (led_kleurafwerking's own 4 real
                   values, confirmed via a live reference-table dump
                   during this rework - GL/MT/SA/ST for NCS and RAL).
                 - All-or-nothing: if no kleurkode could be found at all,
                   every output is cleared back to "" (including a
                   typeAfwerking-derived techniek) - a bare "Poedercoating"
                   or "ANO" label with no actual color would group
                   unrelated colors together, which is exactly what this
                   whole feature is meant to prevent.
                 - Deliberately left unresolved (all outputs stay ""):
                   the "(#COLOR)" placeholder, "Special Custom"/"SC", and
                   plain "Geborsteld"/"Borstelen" rows never contain a RAL
                   code or color word, so they naturally fall through to
                   here - BuildGroepeerKleurLabel() gives those their own
                   recognizable label instead of a raw behandeling
                   fallback (see that method's header).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ResolveKleurUitOmschrijving(
        INPUT  pcOmschrijving  AS CHARACTER,
        INPUT  pcBehandeling   AS CHARACTER,
        INPUT  pcTypeAfwerking AS CHARACTER,
        OUTPUT pcKleursoort    AS CHARACTER,
        OUTPUT pcKleurkode     AS CHARACTER,
        OUTPUT pcAfwerking     AS CHARACTER,
        OUTPUT pcTechniek      AS CHARACTER ):

        DEFINE VARIABLE cUpperOms AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cUpperBeh AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRal      AS CHARACTER NO-UNDO.

        ASSIGN
            pcKleursoort = "":u
            pcKleurkode  = "":u
            pcAfwerking  = "":u
            pcTechniek   = "":u
            cUpperOms    = CAPS(pcOmschrijving)
            cUpperBeh    = CAPS(pcBehandeling).

        /* --- 1. Techniek - typeAfwerking first (most reliable), then
               free text. --- */
        IF pcTypeAfwerking EQ "ANO":u THEN
            pcTechniek = "ANO":u.
        ELSE IF pcTypeAfwerking EQ "LAK":u THEN
            pcTechniek = "Poedercoating":u.

        IF pcTechniek EQ "":u THEN DO:
            IF ContainsWord(cUpperOms, "GEANODISEERD":u) OR ContainsWord(cUpperOms, "ANO":u) THEN
                pcTechniek = "ANO":u.
            ELSE IF ContainsWord(cUpperOms, "NATLAK":u) THEN
                pcTechniek = "Natlak":u.
            ELSE IF ContainsWord(cUpperOms, "STRUCTUURLAK":u) OR ContainsWord(cUpperOms, "STUCTUURLAK":u)
                OR ContainsWord(cUpperOms, "POEDERCOATING":u) OR ContainsWord(cUpperOms, "GELAKT":u)
                OR ContainsSegment(cUpperBeh, "COATEX":u) OR ContainsSegment(cUpperBeh, "LAKKEN":u) THEN
                pcTechniek = "Poedercoating":u.
        END.
        ELSE IF pcTechniek EQ "Poedercoating":u AND ContainsWord(cUpperOms, "NATLAK":u) THEN
            /* typeAfwerking says LAK, but the description is explicit
               about it being natlak (liquid paint) rather than
               poedercoating (powder coat) - both are "LAK-family" for
               grouping/canonicalization purposes, this only refines the
               displayed label. */
            pcTechniek = "Natlak":u.

        /* --- 2. Kleurkode - RAL digits win over named colors. --- */
        cRal = ExtractRalCode(cUpperOms).
        IF cRal EQ "":u THEN
            cRal = ExtractRalCode(cUpperBeh).

        IF cRal NE "":u THEN
            ASSIGN pcKleursoort = "RAL":u pcKleurkode = cRal.
        ELSE
            pcKleurkode = ExtractKleurnaam(cUpperOms, cUpperBeh).

        /* --- 3. Canonicalisatie - alleen binnen de LAK-familie mag een
               kale kleurnaam naar zijn RAL-equivalent omgezet worden, dus
               techniek moet hier al vaststaan (stap 1). Bij ANO blijft de
               kleurnaam zelf staan. --- */
        IF pcKleursoort EQ "":u AND (pcTechniek EQ "Poedercoating":u OR pcTechniek EQ "Natlak":u) THEN DO:
            IF pcKleurkode EQ "ZWART":u THEN
                ASSIGN pcKleursoort = "RAL":u pcKleurkode = "9005":u.
            ELSE IF pcKleurkode EQ "WIT":u THEN
                ASSIGN pcKleursoort = "RAL":u pcKleurkode = "9016":u.
        END.

        /* --- 4. Afwerking - led_kleurafwerking's own 4 real values. --- */
        IF ContainsWord(cUpperOms, "STRUCTUUR":u) OR ContainsWord(cUpperOms, "STRUCTUURLAK":u)
            OR ContainsWord(cUpperOms, "STUCTUURLAK":u) THEN
            pcAfwerking = "Structuur":u.
        ELSE IF ContainsWord(cUpperOms, "MAT":u) OR ContainsWord(cUpperOms, "MATT":u) THEN
            pcAfwerking = "Mat":u.
        ELSE IF ContainsWord(cUpperOms, "GLANS":u) THEN
            pcAfwerking = "Glans":u.
        ELSE IF ContainsWord(cUpperOms, "SATIJN":u) OR ContainsWord(cUpperOms, "SAT":u) THEN
            pcAfwerking = "Satijn":u.

        /* --- 5. All-or-nothing: no color found at all -> clear
               everything, including a typeAfwerking-derived techniek
               (see method header for why). --- */
        IF pcKleurkode EQ "":u THEN
            ASSIGN pcKleursoort = "":u pcTechniek = "":u pcAfwerking = "":u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Case-insensitive whole-word search, tokenizing pcText on
                 spaces and trimming surrounding punctuation from each
                 token before comparing - used for keyword matching in
                 omschrijving (a normal sentence) so that e.g. "MAT" never
                 accidentally matches inside "MATERIAAL" or "AUTOMATISCH",
                 and a trailing "GRIJS)"/"schroeven)." still matches
                 "GRIJS"/"schroeven". Caller passes already-CAPS'd text.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL ContainsWord(
        INPUT pcUpperText AS CHARACTER,
        INPUT pcWoord     AS CHARACTER ):

        DEFINE VARIABLE iEntry AS INTEGER NO-UNDO.

        DO iEntry = 1 TO NUM-ENTRIES(pcUpperText, " ":u):
            IF TRIM(ENTRY(iEntry, pcUpperText, " ":u), ",.()":u) EQ pcWoord THEN
                RETURN TRUE.
        END.

        RETURN FALSE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Exact dot-segment search - used for behandeling
                 (artikel.led-coating), which is always a "."-delimited
                 code (e.g. "WIL.B-PROF-35.9005.COATEX") rather than a
                 sentence, so segment-exact matching is used instead of
                 ContainsWord()'s space-tokenizing (this is also what
                 keeps the short AB/ABRO/AG/AT anodizing abbreviations
                 safe to match - a plain substring search on those would
                 risk false hits inside unrelated codes). Caller passes
                 already-CAPS'd text.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL ContainsSegment(
        INPUT pcUpperText AS CHARACTER,
        INPUT pcSegment   AS CHARACTER ):

        DEFINE VARIABLE iEntry AS INTEGER NO-UNDO.

        DO iEntry = 1 TO NUM-ENTRIES(pcUpperText, ".":u):
            IF ENTRY(iEntry, pcUpperText, ".":u) EQ pcSegment THEN
                RETURN TRUE.
        END.

        RETURN FALSE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Finds a 4-digit RAL code anywhere in pcUpperText, whether
                 written as "RAL 9005", "RAL9005" (no space) or "ral 9005"
                 (caller passes already-CAPS'd text, so case is not a
                 concern here). Requires exactly 4 trailing digits right
                 after "RAL" (ignoring one optional space), so a word that
                 merely contains "RAL" as a substring (e.g. "CENTRAAL")
                 can never produce a false match - it just won't have 4
                 digits following it.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER ExtractRalCode( INPUT pcUpperText AS CHARACTER ):

        DEFINE VARIABLE iPos    AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cRest   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cDigits AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cChar   AS CHARACTER NO-UNDO.

        iPos = INDEX(pcUpperText, "RAL":u).
        IF iPos EQ 0 THEN
            RETURN "":u.

        cRest = TRIM(SUBSTRING(pcUpperText, iPos + 3, 6)).

        DO WHILE LENGTH(cDigits) LT 4 AND LENGTH(cDigits) LT LENGTH(cRest):
            cChar = SUBSTRING(cRest, LENGTH(cDigits) + 1, 1).
            IF cChar GE "0":u AND cChar LE "9":u THEN
                cDigits = cDigits + cChar.
            ELSE
                LEAVE.
        END.

        IF LENGTH(cDigits) EQ 4 THEN
            RETURN cDigits.

        RETURN "":u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Finds a named color (Dutch canonical form, EN synonyms
                 normalized to it) in omschrijving first, then behandeling
                 as plain words, then behandeling's AB/ABRO/AG/AT
                 anodizing-abbreviation dot-segments as a last resort.
                 "NATUREL" is treated as GRIJS (natural/raw aluminium
                 tone) - an assumption, flagged for Marc to correct if
                 wrong. Returns "" when nothing matches.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER ExtractKleurnaam(
        INPUT pcUpperOms AS CHARACTER,
        INPUT pcUpperBeh AS CHARACTER ):

        DEFINE VARIABLE cKleur AS CHARACTER NO-UNDO.

        cKleur = ExtractKleurnaamUitWoorden(pcUpperOms).
        IF cKleur EQ "":u THEN
            cKleur = ExtractKleurnaamUitWoorden(pcUpperBeh).
        IF cKleur EQ "":u THEN
            cKleur = ExtractAnoAfkorting(pcUpperBeh).

        RETURN cKleur.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Whole-word color-name scan (Dutch + EN synonyms) shared
                 by omschrijving and behandeling - see ExtractKleurnaam().
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER ExtractKleurnaamUitWoorden( INPUT pcUpperText AS CHARACTER ):

        IF ContainsWord(pcUpperText, "ZWART":u) OR ContainsWord(pcUpperText, "BLACK":u) THEN
            RETURN "ZWART":u.
        IF ContainsWord(pcUpperText, "WIT":u) OR ContainsWord(pcUpperText, "WHITE":u) THEN
            RETURN "WIT":u.
        IF ContainsWord(pcUpperText, "TITANIUM":u) THEN
            RETURN "TITANIUM":u.
        IF ContainsWord(pcUpperText, "BRONS":u) OR ContainsWord(pcUpperText, "BRONZE":u) THEN
            RETURN "BRONS":u.
        IF ContainsWord(pcUpperText, "GOUD":u) OR ContainsWord(pcUpperText, "GOLD":u) THEN
            RETURN "GOUD":u.
        IF ContainsWord(pcUpperText, "GRIJS":u) OR ContainsWord(pcUpperText, "GREY":u)
            OR ContainsWord(pcUpperText, "GRAY":u) OR ContainsWord(pcUpperText, "NATUREL":u) THEN
            RETURN "GRIJS":u.
        IF ContainsWord(pcUpperText, "ZILVER":u) OR ContainsWord(pcUpperText, "SILVER":u) THEN
            RETURN "ZILVER":u.
        IF ContainsWord(pcUpperText, "ROOD":u) OR ContainsWord(pcUpperText, "RED":u) THEN
            RETURN "ROOD":u.
        IF ContainsWord(pcUpperText, "BLAUW":u) OR ContainsWord(pcUpperText, "BLUE":u) THEN
            RETURN "BLAUW":u.
        IF ContainsWord(pcUpperText, "GROEN":u) OR ContainsWord(pcUpperText, "GREEN":u) THEN
            RETURN "GROEN":u.
        IF ContainsWord(pcUpperText, "GEEL":u) OR ContainsWord(pcUpperText, "YELLOW":u) THEN
            RETURN "GEEL":u.
        IF ContainsWord(pcUpperText, "ORANJE":u) OR ContainsWord(pcUpperText, "ORANGE":u) THEN
            RETURN "ORANJE":u.
        IF ContainsWord(pcUpperText, "BRUIN":u) OR ContainsWord(pcUpperText, "BROWN":u) THEN
            RETURN "BRUIN":u.

        RETURN "":u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: The 4 short anodizing-abbreviation dot-segments (verified
                 against real behandeling data during this rework, same
                 4 abbreviations the old, since-removed EnrichKleurInfo()
                 used pre-2026-08-17): AB=Zwart, ABRO=Brons, AG=Goud,
                 AT=Titanium. Only matched as a whole dot-delimited
                 segment (see ContainsSegment()), never as a raw
                 substring.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER ExtractAnoAfkorting( INPUT pcUpperBehandeling AS CHARACTER ):

        DEFINE VARIABLE iEntry AS INTEGER NO-UNDO.
        DEFINE VARIABLE cSeg   AS CHARACTER NO-UNDO.

        DO iEntry = 1 TO NUM-ENTRIES(pcUpperBehandeling, ".":u):
            cSeg = ENTRY(iEntry, pcUpperBehandeling, ".":u).
            CASE cSeg:
                WHEN "AB":u THEN
                    RETURN "ZWART":u.
                WHEN "ABRO":u THEN
                    RETURN "BRONS":u.
                WHEN "AG":u THEN
                    RETURN "GOUD":u.
                WHEN "AT":u THEN
                    RETURN "TITANIUM":u.
            END CASE.
        END.

        RETURN "":u.

    END METHOD.

END CLASS.
