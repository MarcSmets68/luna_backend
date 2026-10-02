/*------------------------------------------------------------------------
    File        : ArtikelBE.cls
    Purpose     : Business Entity for the "artikel" (article/product master)
                  table - owns full CRUD access for a curated core subset of
                  fields (identification, description, pricing, stock,
                  supplier, classification). The `artikel` table has ~120
                  fields in total; only the commonly-used subset below is
                  exposed via the API for now.
    Field map (JSON key -> artikel column):
                  artnr            -> artnr             (PK, immutable)
                  omschrijvingNl   -> omschr-n
                  omschrijvingFr   -> omschr-f
                  merk             -> merk
                  groep            -> groep
                  barcode          -> barcode
                  munt             -> munt
                  btwKode          -> btw-kode
                  aankoopprijs     -> aprijs
                  verkoopprijs     -> vprijs
                  verkoopprijsIncl -> vprijs-in
                  voorraad         -> aantal
                  voorraadMin      -> minv
                  voorraadMax      -> maxv
                  stock            -> stock
                  geblokkeerd      -> blokkeren
                  leverancierNr    -> levnr
                  gewicht          -> gewicht
                  type             -> type
                  datum            -> datum
    Fase 1 (voorraad-verrijking, zie docs/architecture/voorraad-fase1-ontwerp.md):
                  voorraadExtern     -> x-aantal
                  gereserveerd       -> gereserveerd
                  gereserveerdExtern -> x-gereserveerd
                  beschikbaar        -> berekend: aantal - gereserveerd
                  beschikbaarExtern  -> berekend: x-aantal - x-gereserveerd
                  onderMinimumIntern -> berekend: stock=TRUE AND aantal < minv
                  onderMinimumExtern -> berekend: stock=TRUE AND x-aantal < x-minv
                  magazijn           -> magazijn            (list + detail, see CopyToTt)
                  voorraadMinExtern  -> x-minv
                  voorraadMaxExtern  -> x-maxv
                  swExtern           -> swExtern
                  swExProductie      -> swExProductie
                  isSamengesteld     -> berekend: EXISTS(FIRST artlijn WHERE artlijn.artnr = artikel.artnr)
    Syntax      : Called from Luna.Web.ArtikelHandler (GET/POST/PUT/DELETE
                  /web/artikel and /web/artikel/{artnr})
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes.
    Author(s)   : Devin
    Created     : 2026-08-10
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.ArtikelBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results (get/create/update) the WebHandler unwraps the
       first (and only) entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttArtikel NO-UNDO SERIALIZE-NAME "items":u
        FIELD artnr             AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschrijvingNl    AS CHARACTER SERIALIZE-NAME "omschrijvingNl":u
        FIELD omschrijvingFr    AS CHARACTER SERIALIZE-NAME "omschrijvingFr":u
        FIELD merk              AS CHARACTER SERIALIZE-NAME "merk":u
        FIELD groep              AS CHARACTER SERIALIZE-NAME "groep":u
        FIELD barcode            AS CHARACTER SERIALIZE-NAME "barcode":u
        FIELD munt               AS CHARACTER SERIALIZE-NAME "munt":u
        FIELD btwKode            AS CHARACTER SERIALIZE-NAME "btwKode":u
        FIELD aankoopprijs       AS DECIMAL   SERIALIZE-NAME "aankoopprijs":u
        FIELD verkoopprijs       AS DECIMAL   SERIALIZE-NAME "verkoopprijs":u
        FIELD verkoopprijsIncl   AS DECIMAL   SERIALIZE-NAME "verkoopprijsIncl":u
        FIELD voorraad           AS DECIMAL   SERIALIZE-NAME "voorraad":u
        FIELD voorraadMin        AS DECIMAL   SERIALIZE-NAME "voorraadMin":u
        FIELD voorraadMax        AS DECIMAL   SERIALIZE-NAME "voorraadMax":u
        FIELD stock              AS LOGICAL   SERIALIZE-NAME "stock":u
        FIELD geblokkeerd        AS LOGICAL   SERIALIZE-NAME "geblokkeerd":u
        FIELD leverancierNr      AS INTEGER   SERIALIZE-NAME "leverancierNr":u
        FIELD gewicht            AS DECIMAL   SERIALIZE-NAME "gewicht":u
        FIELD artikelType        AS CHARACTER SERIALIZE-NAME "type":u
        FIELD datum              AS DATE      SERIALIZE-NAME "datum":u
        /* --- Fase 1 voorraad-verrijking (zie docs/architecture/voorraad-fase1-ontwerp.md §2.1) --- */
        FIELD voorraadExtern     AS DECIMAL   SERIALIZE-NAME "voorraadExtern":u        /* x-aantal */
        FIELD gereserveerd       AS DECIMAL   SERIALIZE-NAME "gereserveerd":u          /* gereserveerd */
        FIELD gereserveerdExtern AS DECIMAL   SERIALIZE-NAME "gereserveerdExtern":u    /* x-gereserveerd */
        FIELD beschikbaar        AS DECIMAL   SERIALIZE-NAME "beschikbaar":u           /* berekend: voorraad - gereserveerd */
        FIELD beschikbaarExtern  AS DECIMAL   SERIALIZE-NAME "beschikbaarExtern":u     /* berekend: voorraadExtern - gereserveerdExtern */
        FIELD onderMinimumIntern AS LOGICAL   SERIALIZE-NAME "onderMinimumIntern":u    /* berekend, altijd FALSE als stock=FALSE */
        FIELD onderMinimumExtern AS LOGICAL   SERIALIZE-NAME "onderMinimumExtern":u    /* berekend, altijd FALSE als stock=FALSE */
        /* --- nieuw, gevuld op zowel lijst als detail (zie OD in ontwerp §2.1) --- */
        FIELD magazijn           AS CHARACTER SERIALIZE-NAME "magazijn":u
        FIELD voorraadMinExtern  AS DECIMAL   SERIALIZE-NAME "voorraadMinExtern":u     /* x-minv */
        FIELD voorraadMaxExtern  AS DECIMAL   SERIALIZE-NAME "voorraadMaxExtern":u     /* x-maxv */
        FIELD swExtern           AS LOGICAL   SERIALIZE-NAME "swExtern":u
        FIELD swExProductie      AS LOGICAL   SERIALIZE-NAME "swExProductie":u
        FIELD isSamengesteld     AS LOGICAL   SERIALIZE-NAME "isSamengesteld":u        /* EXISTS artlijn */
        INDEX idx-artnr IS PRIMARY artnr.

    /*------------------------------------------------------------------------------
        Purpose: Copies the core subset of fields from an `artikel` buffer into a
                 ttArtikel row, for use by every read/write method below.
        Notes  : Kept private - callers always go through GetArtikel(en)/Create/
                 Update so this mapping stays in one place.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbArtikel FOR artikel, BUFFER pbTt FOR ttArtikel ):

        ASSIGN
            pbTt.artnr            = pbArtikel.artnr
            pbTt.omschrijvingNl   = pbArtikel.omschr-n
            pbTt.omschrijvingFr   = pbArtikel.omschr-f
            pbTt.merk             = pbArtikel.merk
            pbTt.groep            = pbArtikel.groep
            pbTt.barcode          = pbArtikel.barcode
            pbTt.munt             = pbArtikel.munt
            pbTt.btwKode          = pbArtikel.btw-kode
            pbTt.aankoopprijs     = pbArtikel.aprijs
            pbTt.verkoopprijs     = pbArtikel.vprijs
            pbTt.verkoopprijsIncl = pbArtikel.vprijs-in
            pbTt.voorraad         = pbArtikel.aantal
            pbTt.voorraadMin      = pbArtikel.minv
            pbTt.voorraadMax      = pbArtikel.maxv
            pbTt.stock            = pbArtikel.stock
            pbTt.geblokkeerd      = pbArtikel.blokkeren
            pbTt.leverancierNr    = pbArtikel.levnr
            pbTt.gewicht          = pbArtikel.gewicht
            pbTt.artikelType      = pbArtikel.type
            pbTt.datum            = pbArtikel.datum
            /* --- Fase 1 voorraad-verrijking --- */
            pbTt.voorraadExtern     = pbArtikel.x-aantal
            pbTt.gereserveerd       = pbArtikel.gereserveerd
            pbTt.gereserveerdExtern = pbArtikel.x-gereserveerd
            pbTt.beschikbaar        = pbArtikel.aantal   - pbArtikel.gereserveerd
            pbTt.beschikbaarExtern  = pbArtikel.x-aantal - pbArtikel.x-gereserveerd
            /* FR-6/BR-1: "onder minimum" is altijd FALSE wanneer stock = FALSE,
               ongeacht de ruwe aantal/minv-waarden (die zijn dan betekenisloos). */
            pbTt.onderMinimumIntern = pbArtikel.stock AND (pbArtikel.aantal   LT pbArtikel.minv)
            pbTt.onderMinimumExtern = pbArtikel.stock AND (pbArtikel.x-aantal LT pbArtikel.x-minv)
            pbTt.magazijn           = pbArtikel.magazijn
            pbTt.voorraadMinExtern  = pbArtikel.x-minv
            pbTt.voorraadMaxExtern  = pbArtikel.x-maxv
            pbTt.swExtern           = pbArtikel.swExtern
            pbTt.swExProductie      = pbArtikel.swExProductie
            /* OD-3: EXISTS-check i.p.v. artikel.swMaster - zie requirements OV-2/
               design §1.3. Enkel uitgevoerd op de al-beperkte resultaatpagina/rij,
               niet op de volledige 1.8M-rij scan. */
            pbTt.isSamengesteld     = CAN-FIND(FIRST artlijn WHERE artlijn.artnr EQ pbArtikel.artnr)
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field present in the JSON request body onto the
                 given `artikel` buffer. Fields absent from the body are left
                 untouched, so this also works for partial updates. `artnr` is
                 never touched here - it is set once on create and is immutable.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbArtikel FOR artikel ):

        IF poBody:Has("omschrijvingNl":u)   THEN pbArtikel.omschr-n  = poBody:GetCharacter("omschrijvingNl":u).
        IF poBody:Has("omschrijvingFr":u)   THEN pbArtikel.omschr-f  = poBody:GetCharacter("omschrijvingFr":u).
        IF poBody:Has("merk":u)             THEN pbArtikel.merk      = poBody:GetCharacter("merk":u).
        IF poBody:Has("groep":u)            THEN pbArtikel.groep     = poBody:GetCharacter("groep":u).
        IF poBody:Has("barcode":u)          THEN pbArtikel.barcode   = poBody:GetCharacter("barcode":u).
        IF poBody:Has("munt":u)             THEN pbArtikel.munt      = poBody:GetCharacter("munt":u).
        IF poBody:Has("btwKode":u)          THEN pbArtikel.btw-kode  = poBody:GetCharacter("btwKode":u).
        IF poBody:Has("aankoopprijs":u)     THEN pbArtikel.aprijs    = poBody:GetDecimal("aankoopprijs":u).
        IF poBody:Has("verkoopprijs":u)     THEN pbArtikel.vprijs    = poBody:GetDecimal("verkoopprijs":u).
        IF poBody:Has("verkoopprijsIncl":u) THEN pbArtikel.vprijs-in = poBody:GetDecimal("verkoopprijsIncl":u).
        IF poBody:Has("voorraad":u)         THEN pbArtikel.aantal    = poBody:GetDecimal("voorraad":u).
        IF poBody:Has("voorraadMin":u)      THEN pbArtikel.minv      = poBody:GetDecimal("voorraadMin":u).
        IF poBody:Has("voorraadMax":u)      THEN pbArtikel.maxv      = poBody:GetDecimal("voorraadMax":u).
        IF poBody:Has("stock":u)            THEN pbArtikel.stock     = poBody:GetLogical("stock":u).
        IF poBody:Has("geblokkeerd":u)      THEN pbArtikel.blokkeren = poBody:GetLogical("geblokkeerd":u).
        IF poBody:Has("leverancierNr":u)    THEN pbArtikel.levnr     = poBody:GetInteger("leverancierNr":u).
        IF poBody:Has("gewicht":u)          THEN pbArtikel.gewicht   = poBody:GetDecimal("gewicht":u).
        IF poBody:Has("type":u)             THEN pbArtikel.type      = poBody:GetCharacter("type":u).
        IF poBody:Has("datum":u)            THEN pbArtikel.datum     = poBody:GetDate("datum":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: TRUE when pcTerm can safely be used as an x-ref CONTAINS word
                 phrase (pcTerm + "*"). Allowlist: letters, digits, '.', '-', '_',
                 starting with a letter/digit. Anything else (quotes, '*', '~',
                 '&', '|', '!', parentheses, spaces, '#', '%', ...) returns FALSE
                 and the caller falls back to x-ref BEGINS, because CONTAINS
                 raises a runtime syntax error (e.g. 4686) on such input.
                 Verified live: '.', '-' work inside terms (SIKTA.S40.C.21*,
                 D25-10*).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL IsSafeContainsTerm( INPUT pcTerm AS CHARACTER ):

        DEFINE VARIABLE i AS INTEGER   NO-UNDO.
        DEFINE VARIABLE c AS CHARACTER NO-UNDO.

        IF pcTerm EQ "":u OR pcTerm EQ ? THEN RETURN FALSE.

        DO i = 1 TO LENGTH(pcTerm):
            c = SUBSTRING(pcTerm, i, 1).
            IF (ASC(c) GE 48 AND ASC(c) LE 57)
               OR (ASC(c) GE 65 AND ASC(c) LE 90)
               OR (ASC(c) GE 97 AND ASC(c) LE 122) THEN NEXT.
            IF i GT 1 AND (c EQ ".":u OR c EQ "-":u OR c EQ "_":u) THEN NEXT.
            RETURN FALSE.
        END.

        RETURN TRUE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Shared per-row scan-cap + filter + paging + emit logic for both
                 legs of GetArtikelen (artnr leg and x-ref leg), so the two
                 can never diverge. See the GetArtikelen header for why every
                 check is evaluated per-row (not in the WHERE clause).
        Notes  : plSkipArtnrMatch = TRUE for the x-ref leg: rows whose artnr
                 BEGINS pcArtnr were already returned by the artnr leg and are
                 skipped (after being counted towards the scan cap).
                 plStop = TRUE tells the caller to LEAVE its loop (and skip any
                 later leg); plHasMore is set TRUE in that case.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ProcessRow(
        BUFFER pbArtikel          FOR artikel,
        INPUT  plSkipArtnrMatch   AS LOGICAL,
        INPUT  pcArtnr            AS CHARACTER,
        INPUT  pcOmschrijving     AS CHARACTER,
        INPUT  pcGroep            AS CHARACTER,
        INPUT  pcOnderMinimum     AS CHARACTER,
        INPUT  plExternInBewerking AS LOGICAL,
        INPUT  pcGeblokkeerd      AS CHARACTER,
        INPUT  piSkip             AS INTEGER,
        INPUT  piPageSize         AS INTEGER,
        INPUT  piMaxRowsScanned   AS INTEGER,
        INPUT-OUTPUT piRowsScanned AS INTEGER,
        INPUT-OUTPUT piSeen       AS INTEGER,
        INPUT-OUTPUT piTaken      AS INTEGER,
        OUTPUT plHasMore          AS LOGICAL,
        OUTPUT plStop             AS LOGICAL ):

        DEFINE VARIABLE lMatch AS LOGICAL NO-UNDO.

        ASSIGN
            plHasMore = FALSE
            plStop    = FALSE.

        /* Scan-depth safety cap - see the GetArtikelen header note.
           Counts every physical row examined (not just matches), so it
           bounds worst-case latency even when the filter matches
           nothing at all. Must run before any per-row condition below
           that can RETURN early, so every visited row counts. */
        piRowsScanned = piRowsScanned + 1.
        IF piRowsScanned GT piMaxRowsScanned THEN
        DO:
            ASSIGN plHasMore = TRUE
                   plStop    = TRUE.
            RETURN.
        END.

        /* x-ref leg dedup: artnr leg already returned this row. */
        IF plSkipArtnrMatch AND pbArtikel.artnr BEGINS pcArtnr THEN RETURN.

        /* 2026-08-27 (groep-fix): same reasoning as omschrijving below -
           when pcArtnr is blank, "groep EQ pcGroep" in the WHERE clause
           above used to let the query engine pre-filter non-matching
           rows before they ever reached the loop body/counter, so the
           scan-depth cap never triggered and this degraded into a full
           ~1.8M-row table scan (measured live at 13+s). Moved to a
           per-row IF/NEXT check, same pattern as omschrijving/
           onderMinimum, so every physically-visited row counts towards
           iMaxRowsScanned regardless of whether it matches groep. */
        IF pcGroep NE "":u AND pbArtikel.groep NE pcGroep THEN RETURN.

        IF pcOmschrijving NE "":u THEN
        DO:
            IF INDEX(UPPER(pbArtikel.omschr-n), pcOmschrijving) EQ 0
               AND INDEX(UPPER(pbArtikel.omschr-f), pcOmschrijving) EQ 0 THEN
                RETURN.
        END.

        /* BR-1: "onder minimum" always requires stock = TRUE - vermijdt
           betekenisloze vergelijkingen op niet-voorraadartikelen. */
        IF pcOnderMinimum NE "":u THEN
        DO:
            lMatch = pbArtikel.stock AND
                (   (pcOnderMinimum EQ "intern":u AND pbArtikel.aantal   LT pbArtikel.minv)
                 OR (pcOnderMinimum EQ "extern":u AND pbArtikel.x-aantal LT pbArtikel.x-minv)
                 OR (pcOnderMinimum EQ "beide":u  AND (pbArtikel.aantal   LT pbArtikel.minv
                                                     OR pbArtikel.x-aantal LT pbArtikel.x-minv))).
            IF NOT lMatch THEN RETURN.
        END.

        IF plExternInBewerking AND NOT (pbArtikel.x-gereserveerd GT 0) THEN RETURN.

        /* geblokkeerd-filter: "true" = enkel geblokkeerde artikelen,
           "false" = enkel niet-geblokkeerde, leeg = geen filter. Per-rij
           geëvalueerd zodat iRowsScanned elke bezochte rij telt. */
        IF pcGeblokkeerd EQ "true":u  AND NOT pbArtikel.blokkeren THEN RETURN.
        IF pcGeblokkeerd EQ "false":u AND pbArtikel.blokkeren     THEN RETURN.

        piSeen = piSeen + 1.

        IF piSeen LE piSkip THEN RETURN.

        IF piTaken GE piPageSize THEN
        DO:
            ASSIGN plHasMore = TRUE
                   plStop    = TRUE.
            RETURN.
        END.

        CREATE ttArtikel.
        CopyToTt( BUFFER pbArtikel, BUFFER ttArtikel ).
        piTaken = piTaken + 1.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of artikel rows, optionally filtered by artnr
                 (prefix match), omschrijving (substring match on NL/FR
                 description) and groep (exact match).
        Notes  : NO-LOCK read-only. piPage/piPageSize are expected to already be
                 validated/clamped by the caller (page >= 1, 1 <= pageSize <= 200).
                 `artikel` holds ~1.8M rows in production, so this deliberately
                 does NOT compute an exact total count (that requires a full
                 table scan and blows well past PASOE's requestWaitTimeout).
                 Instead it stops scanning as soon as it has one extra row
                 beyond the requested page and reports that via plHasMore.
                 Only the artnr (BEGINS) filter is folded into this FOR
                 EACH's WHERE clause and can use the artikel-x01 index to
                 range-scan/short-circuit early. groep (EQ) and
                 omschrijving (substring) are both evaluated per-row inside
                 the loop body instead (see the 2026-08-27 notes below) -
                 whenever artnr is blank, either filter alone would
                 otherwise force a full ~1.8M-row scan with no cap. Combine
                 with an artnr prefix where possible for the best latency.
                 2026-08-27: any filter combination that leaves artnr blank
                 (no index-range narrowing) and matches few/no rows - e.g. an
                 omschrijving substring nothing matches, whether from a
                 legitimate search or a mangled query-param value - used to
                 scan the full ~1.8M-row table looking for piPageSize+1
                 matches that never arrive, measured at 12-20s live. That's
                 reachable by any end user typing an obscure term into a
                 free-text filter, not just crafted input, so it's capped
                 independently of any query-param parsing fix (see
                 Luna.Web.Util.QueryParamHelper): the loop below now also
                 gives up, and reports plHasMore = TRUE (unknown, not
                 "definitely more"), after examining
                 iMaxRowsScanned candidate rows, regardless of how many (if
                 any) matched. The cap must count every row PHYSICALLY
                 VISITED, not every row that matched - the omschrijving
                 substring check therefore can't live in this FOR EACH's
                 WHERE clause (a WHERE condition is evaluated by the query
                 engine before a row ever reaches the loop body, so a
                 non-matching row would never increment the counter and the
                 cap could never trigger while the engine ground through
                 the whole table underneath it); it's evaluated per-row
                 below instead, same as onderMinimum/externInBewerking.
                 Measured live against this table at ~25K rows/sec
                 end-to-end (includes the per-row UPPER()/INDEX() calls),
                 so the 15,000-row cap bounds worst-case latency to
                 roughly 0.6s.
                 2026-08-28: the same issue applied to groep when artnr is
                 blank - "groep EQ pcGroep" in the WHERE clause let the
                 query engine pre-filter rows before the counter saw them,
                 so a groep-only filter (no artnr) degraded into an
                 unbounded full-table scan (measured live at 13+s). Moved
                 out to a per-row IF/NEXT check for the same reason as
                 omschrijving above; the artnr BEGINS condition is
                 untouched and still drives the index range when artnr is
                 supplied alongside groep.
                 x-ref ("4L-code", artikel.x-ref CHARACTER X(40)): the artnr
                 filter ALSO matches artikel.x-ref. No new query param -
                 folded into artnr (approved, see feature artikel-xref-search).
                 Implemented as two legs sharing the same per-row filters,
                 scan cap and paging state (ProcessRow): leg A = artnr BEGINS
                 (artikel-x01), leg B = x-ref CONTAINS "<artnr>*" on the
                 artikel-x13 WORD index (same as legacy ZkArtikel.w, so the
                 term may start at any word of x-ref); terms containing
                 CONTAINS-special characters fall back to x-ref BEGINS on
                 artikel-x10 (see IsSafeContainsTerm). Leg B only runs when
                 artnr is non-blank and leg A did not already stop; it skips
                 rows whose artnr already matches, so no duplicates. x-ref is
                 an internal match criterion and is never exposed in the JSON.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetArtikelen(
        INPUT  pcArtnr            AS CHARACTER,
        INPUT  pcOmschrijving     AS CHARACTER,
        INPUT  pcGroep            AS CHARACTER,
        INPUT  piPage             AS INTEGER,
        INPUT  piPageSize         AS INTEGER,
        INPUT  pcOnderMinimum     AS CHARACTER,
        INPUT  plExternInBewerking AS LOGICAL,
        INPUT  pcGeblokkeerd      AS CHARACTER,
        OUTPUT plHasMore          AS LOGICAL ):

        DEFINE VARIABLE iSkip          AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen          AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken         AS INTEGER NO-UNDO.
        DEFINE VARIABLE lMatch         AS LOGICAL NO-UNDO.
        DEFINE VARIABLE iRowsScanned   AS INTEGER NO-UNDO.
        DEFINE VARIABLE iMaxRowsScanned AS INTEGER NO-UNDO INITIAL 15000.
        DEFINE VARIABLE lStop          AS LOGICAL NO-UNDO.

        EMPTY TEMP-TABLE ttArtikel.

        ASSIGN
            pcArtnr        = UPPER(TRIM(pcArtnr))
            pcOmschrijving = UPPER(TRIM(pcOmschrijving))
            pcGroep        = TRIM(pcGroep)
            pcOnderMinimum = LC(TRIM(pcOnderMinimum))
            pcGeblokkeerd  = LC(TRIM(pcGeblokkeerd))
            iSkip          = (piPage - 1) * piPageSize
            iSeen          = 0
            iTaken         = 0
            iRowsScanned   = 0
            plHasMore      = FALSE
            lStop          = FALSE
            .

        IF pcOnderMinimum NE "":u AND LOOKUP(pcOnderMinimum, "intern,extern,beide":u) EQ 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Invalid onderMinimum &1, expected intern/extern/beide":u, pcOnderMinimum), 400).

        IF pcGeblokkeerd NE "":u AND LOOKUP(pcGeblokkeerd, "true,false":u) EQ 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Invalid geblokkeerd &1, expected true/false":u, pcGeblokkeerd), 400).

        /* artikel.artnr BEGINS pcArtnr - written as a single, un-OR'd BEGINS
           condition (not "pcArtnr EQ '' OR artikel.artnr BEGINS pcArtnr") so
           the query optimizer can use the artikel-x01 (unique) index for a
           range scan. "x BEGINS ''" is always TRUE in ABL, so this still
           behaves as "no filter" when pcArtnr is blank - but an OR'd
           condition on the indexed field defeats index-range optimization
           entirely and forces a full ~1.8M-row table scan, OR'd or not.
           The field is also left unwrapped (no UPPER()) for the same
           reason; CHARACTER fields/indexes are case-insensitive by default
           in this database, so this still matches case-insensitively.

           onderMinimum/externInBewerking (Fase 1, design §1.2.1) are
           evaluated per-row below (not folded into this FOR EACH's WHERE)
           because they involve computed comparisons across two fields -
           still the same early-exit-after-page+1 pattern, no extra table
           scan beyond what the design doc accepts as in-scope.

           2026-08-27: omschrijving used to be folded into this WHERE too
           (as an INDEX()-based substring match). That's wrong for the
           scan-depth cap below: a WHERE-clause condition is evaluated by
           the query engine for every candidate row BEFORE the row ever
           reaches the loop body, so a row that fails the omschrijving
           match never increments iRowsScanned - the cap could never
           trigger while the engine silently ground through the entire
           table underneath it. Moved out to a per-row IF/NEXT check
           (same pattern as onderMinimum) so every physically-visited row
           - matching or not - is counted and the cap actually bounds the
           scan.

           2026-08-28: groep (EQ) had the exact same problem and is now
           moved out for the same reason - "artikel.groep EQ pcGroep" used
           to sit in this WHERE clause, which is fine when pcArtnr also
           narrows the index range, but when pcArtnr is blank the engine
           silently scanned the full table pre-filtering on groep before
           any row reached iRowsScanned, so the cap never triggered
           (measured live at 13+s). It's evaluated per-row below instead. */
        /* Leg A: artnr prefix match (artikel-x01 range scan), unchanged. */
        FOR EACH artikel NO-LOCK
            WHERE artikel.artnr BEGINS pcArtnr
            BY artikel.artnr:

            ProcessRow( BUFFER artikel, FALSE, pcArtnr, pcOmschrijving, pcGroep,
                        pcOnderMinimum, plExternInBewerking, pcGeblokkeerd,
                        iSkip, piPageSize, iMaxRowsScanned,
                        INPUT-OUTPUT iRowsScanned, INPUT-OUTPUT iSeen, INPUT-OUTPUT iTaken,
                        OUTPUT plHasMore, OUTPUT lStop ).
            IF lStop THEN LEAVE.
        END.

        /* Leg B: x-ref ("4L-code") match - only when an artnr filter was given
           (a blank term would match every row) and leg A did not already stop
           on the shared scan cap / filled page. Matches like legacy
           ZkArtikel.w: x-ref CONTAINS '<input>*' (word index artikel-x13), so
           the term can start at any word of x-ref (SIKTA.S40.C.21 is found by
           SIKTA.S40.C.21, S40.C.21, S40, SIKTA, C.21, ...). Legacy does no
           escaping at all; CONTAINS syntax errors (e.g. '*' mid-word) are
           raised at runtime, so only a conservative character set is passed
           to CONTAINS (see IsSafeContainsTerm) and anything else falls back to
           the plain x-ref BEGINS index range (artikel-x10).
           Rows whose artnr already matches are skipped inside ProcessRow
           (leg A returned them), so each article appears at most once. Shares
           the counters with leg A so paging is one continuous sequence
           (artnr hits, then x-ref-only hits). */
        IF pcArtnr NE "":u AND NOT lStop THEN
        DO:
            IF IsSafeContainsTerm( pcArtnr ) THEN
            DO:
                FOR EACH artikel NO-LOCK
                    WHERE artikel.x-ref CONTAINS pcArtnr + "*":u:

                    ProcessRow( BUFFER artikel, TRUE, pcArtnr, pcOmschrijving, pcGroep,
                                pcOnderMinimum, plExternInBewerking, pcGeblokkeerd,
                                iSkip, piPageSize, iMaxRowsScanned,
                                INPUT-OUTPUT iRowsScanned, INPUT-OUTPUT iSeen, INPUT-OUTPUT iTaken,
                                OUTPUT plHasMore, OUTPUT lStop ).
                    IF lStop THEN LEAVE.
                END.
            END.
            ELSE
            DO:
                FOR EACH artikel NO-LOCK
                    WHERE artikel.x-ref BEGINS pcArtnr
                    BY artikel.x-ref
                    BY artikel.artnr:

                    ProcessRow( BUFFER artikel, TRUE, pcArtnr, pcOmschrijving, pcGroep,
                                pcOnderMinimum, plExternInBewerking, pcGeblokkeerd,
                                iSkip, piPageSize, iMaxRowsScanned,
                                INPUT-OUTPUT iRowsScanned, INPUT-OUTPUT iSeen, INPUT-OUTPUT iTaken,
                                OUTPUT plHasMore, OUTPUT lStop ).
                    IF lStop THEN LEAVE.
                END.
            END.
        END.

        RETURN TEMP-TABLE ttArtikel:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single artikel by artnr, or an empty ttArtikel if it
                 doesn't exist (the WebHandler turns that into a 404).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetArtikel( INPUT pcArtnr AS CHARACTER ):

        EMPTY TEMP-TABLE ttArtikel.

        FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.

        IF AVAILABLE artikel THEN
        DO:
            CREATE ttArtikel.
            CopyToTt( BUFFER artikel, BUFFER ttArtikel ).
        END.

        RETURN TEMP-TABLE ttArtikel:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new artikel. `artnr` is required in the body and must
                 not already exist.
        Errors : AppError code 400 - artnr missing/blank.
                 AppError code 409 - artnr already exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateArtikel( INPUT poBody AS JsonObject ):

        DEFINE VARIABLE cArtnr AS CHARACTER NO-UNDO.

        EMPTY TEMP-TABLE ttArtikel.

        IF NOT poBody:Has("artnr":u) OR TRIM(poBody:GetCharacter("artnr":u)) EQ "":u THEN
            UNDO, THROW NEW Progress.Lang.AppError("artnr is required":u, 400).

        cArtnr = TRIM(poBody:GetCharacter("artnr":u)).

        DO TRANSACTION:
            FIND FIRST artikel EXCLUSIVE-LOCK WHERE artikel.artnr EQ cArtnr NO-ERROR.
            IF AVAILABLE artikel THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Artikel &1 already exists":u, cArtnr), 409).

            CREATE artikel.
            ASSIGN artikel.artnr = cArtnr.

            ApplyFields( INPUT poBody, BUFFER artikel ).

            CREATE ttArtikel.
            CopyToTt( BUFFER artikel, BUFFER ttArtikel ).
        END.

        RETURN TEMP-TABLE ttArtikel:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing artikel. Only fields present in the JSON body
                 are changed (partial update); `artnr` itself is immutable.
        Errors : AppError code 404 - artnr not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateArtikel( INPUT pcArtnr AS CHARACTER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttArtikel.

        DO TRANSACTION:
            FIND FIRST artikel EXCLUSIVE-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.
            IF NOT AVAILABLE artikel THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Artikel &1 not found":u, pcArtnr), 404).

            ApplyFields( INPUT poBody, BUFFER artikel ).

            CREATE ttArtikel.
            CopyToTt( BUFFER artikel, BUFFER ttArtikel ).
        END.

        RETURN TEMP-TABLE ttArtikel:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes an artikel by artnr.
        Errors : AppError code 404 - artnr not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteArtikel( INPUT pcArtnr AS CHARACTER ):

        DO TRANSACTION:
            FIND FIRST artikel EXCLUSIVE-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.
            IF NOT AVAILABLE artikel THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Artikel &1 not found":u, pcArtnr), 404).

            DELETE artikel.
        END.

    END METHOD.

END CLASS.
