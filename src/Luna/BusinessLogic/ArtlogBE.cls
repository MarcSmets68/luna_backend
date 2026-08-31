/*------------------------------------------------------------------------
    File        : ArtlogBE.cls
    Purpose     : Business Entity for the paginated `artlog` (stock
                  movement history) tab on the artikel detail page (FR-5).
                  Deliberately a separate class from Luna.BusinessLogic.
                  ArtikelBE - this is a paginated read over `artlog`, not
                  `artikel` CRUD, with its own paging/filter logic (see
                  docs/architecture/voorraad-fase1-ontwerp.md §1.5/§2.3).
    Field map (JSON key -> artlog column):
                  artnr       -> artnr
                  lijnnr      -> lijnnr
                  datum       -> datum
                  uur         -> uur           (CHARACTER X(8), confirmed
                                                 against docs/database-
                                                 analysis.md - matches the
                                                 ontwerp's assumption, no
                                                 correction needed)
                  beweging    -> beweging      (BR-3: ruwe code, ongewijzigd)
                  aantal      -> aantal
                  stock (json)-> stockNa       (intern hernoemd naar stockNa
                                                 om verwarring met
                                                 artikel.stock (logical) te
                                                 vermijden - JSON-key blijft
                                                 "stock" conform FR-5-tabel)
                  docnr       -> docnr         (CHARACTER X(12), confirmed)
                  omschr      -> omschr
                  kllev       -> kllev         (INTEGER, confirmed)
                  naam        -> naam
                  aprijs      -> aprijs
                  munt        -> munt
                  koers       -> koers         (DECIMAL, confirmed)
                  opm         -> opm
                  refLev      -> ref-lev
                  id          -> id            (intern tt-veldnaam
                                                 "gebruikerId" - een tt-veld
                                                 letterlijk "userId" noemen
                                                 breekt de ABL-compiler op
                                                 deze temp-table met een
                                                 cryptische "Could not
                                                 understand"-parsefout,
                                                 vermoedelijk omdat het als
                                                 afkorting van de ingebouwde
                                                 USERID()-functie herkend
                                                 wordt in deze FIELD-context;
                                                 de JSON-key blijft "id"
                                                 conform het contract)
                  swControle  -> swControle
                  cdatum      -> cdatum
    OD-2 (sortering, NIET geverifieerd tegen productiedata - zie
    architectuurdocument §5 OD-2/open vraag): gesorteerd op
    `artlog.artnr BY artlog.lijnnr DESCENDING` (gebruikt artlog-x1 volledig,
    geen aparte sort-pass) in plaats van `datum DESCENDING`, met de aanname
    dat `lijnnr` monotoon oploopt met de tijd binnen één `artnr`. Dit MOET
    steekproefsgewijs gevalideerd worden door backend-tester/Marc (bv.
    `artnr = 'x' ORDER BY lijnnr` en visueel checken of `datum` meestijgt)
    voor dit als definitief gedrag bevestigd wordt. Als dit niet klopt: val
    terug op in-memory sort op `datum` na de indexed artnr-filter (kleine
    subset per artikel, goedkoop).
    Syntax      : Called from Luna.Web.ArtikelHandler (GET
                  /web/artikel/{artnr}/artlog)
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads
                  (read-only feature, no writes in Fase 1).
    Author(s)   : Devin
    Created     : 2026-08-21
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.ArtlogBE:

    DEFINE TEMP-TABLE ttArtlog NO-UNDO SERIALIZE-NAME "items":u
        FIELD artnr       AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD lijnnr      AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD datum       AS DATE      SERIALIZE-NAME "datum":u
        FIELD uur         AS CHARACTER SERIALIZE-NAME "uur":u
        FIELD beweging    AS CHARACTER SERIALIZE-NAME "beweging":u
        FIELD aantal      AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD stockNa     AS DECIMAL   SERIALIZE-NAME "stock":u
        FIELD docnr       AS CHARACTER SERIALIZE-NAME "docnr":u
        FIELD omschr      AS CHARACTER SERIALIZE-NAME "omschr":u
        FIELD kllev       AS INTEGER   SERIALIZE-NAME "kllev":u
        FIELD naam        AS CHARACTER SERIALIZE-NAME "naam":u
        FIELD aprijs      AS DECIMAL   SERIALIZE-NAME "aprijs":u
        FIELD munt        AS CHARACTER SERIALIZE-NAME "munt":u
        FIELD koers       AS DECIMAL   SERIALIZE-NAME "koers":u
        FIELD opm         AS CHARACTER SERIALIZE-NAME "opm":u
        FIELD refLeverancier AS CHARACTER SERIALIZE-NAME "refLev":u
        FIELD gebruikerId AS CHARACTER SERIALIZE-NAME "id":u
        FIELD swControle  AS LOGICAL   SERIALIZE-NAME "swControle":u
        FIELD cdatum      AS DATE      SERIALIZE-NAME "cdatum":u
        INDEX idx-artnr-lijnnr IS PRIMARY artnr lijnnr DESCENDING.

    /*------------------------------------------------------------------------------
        Purpose: Copies the full field set from an `artlog` buffer into a
                 ttArtlog row.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbArtlog FOR artlog, BUFFER pbTt FOR ttArtlog ):

        ASSIGN
            pbTt.artnr      = pbArtlog.artnr
            pbTt.lijnnr     = pbArtlog.lijnnr
            pbTt.datum      = pbArtlog.datum
            pbTt.uur        = pbArtlog.uur
            pbTt.beweging   = pbArtlog.beweging
            pbTt.aantal     = pbArtlog.aantal
            pbTt.stockNa    = pbArtlog.stock
            pbTt.docnr      = pbArtlog.docnr
            pbTt.omschr     = pbArtlog.omschr
            pbTt.kllev      = pbArtlog.kllev
            pbTt.naam       = pbArtlog.naam
            pbTt.aprijs     = pbArtlog.aprijs
            pbTt.munt       = pbArtlog.munt
            pbTt.koers      = pbArtlog.koers
            pbTt.opm        = pbArtlog.opm
            pbTt.refLeverancier = pbArtlog.ref-lev
            pbTt.gebruikerId = pbArtlog.id
            pbTt.swControle = pbArtlog.swControle
            pbTt.cdatum     = pbArtlog.cdatum
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of artlog rows for pcArtnr, optionally
                 filtered by datum range and/or beweging code (BR-3: raw,
                 unmapped).
        Notes  : NO-LOCK read-only. artlog-x1 (artnr, lijnnr) is a unique
                 index, so filtering on artnr is an indexed range scan - see
                 class header for the sort-order design decision (OD-2).
                 Same "stop after page+1" hasMore pattern as
                 ArtikelBE:GetArtikelen - no exact count over the 538K-row
                 table.
        Errors : AppError 404 - pcArtnr does not exist in `artikel` (checked
                 here, not in the WebHandler, per "Business Entity = alle
                 logica").
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetArtlog(
        INPUT  pcArtnr     AS CHARACTER,
        INPUT  piPage      AS INTEGER,
        INPUT  piPageSize  AS INTEGER,
        INPUT  pdDatumVan  AS DATE,
        INPUT  pdDatumTot  AS DATE,
        INPUT  pcBeweging  AS CHARACTER,
        OUTPUT plHasMore   AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttArtlog.

        FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.
        IF NOT AVAILABLE artikel THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Artikel &1 not found":u, pcArtnr), 404).

        ASSIGN
            pcBeweging = TRIM(pcBeweging)
            iSkip      = (piPage - 1) * piPageSize
            iSeen      = 0
            iTaken     = 0
            plHasMore  = FALSE
            .

        FOR EACH artlog NO-LOCK
            WHERE artlog.artnr EQ pcArtnr
              AND (pdDatumVan EQ ? OR artlog.datum GE pdDatumVan)
              AND (pdDatumTot EQ ? OR artlog.datum LE pdDatumTot)
              AND (pcBeweging EQ "":u OR artlog.beweging EQ pcBeweging)
            BY artlog.artnr BY artlog.lijnnr DESCENDING:

            iSeen = iSeen + 1.

            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttArtlog.
            CopyToTt( BUFFER artlog, BUFFER ttArtlog ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttArtlog:HANDLE.

    END METHOD.

END CLASS.
