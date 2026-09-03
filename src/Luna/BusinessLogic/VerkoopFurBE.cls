/*------------------------------------------------------------------------
    File        : VerkoopFurBE.cls
    Purpose     : Business Entity for the "Verkoop FUR" rapportage overview
                  - lists Nomaled dealers (klant.swNomaled = TRUE) that
                  ordered a "FUR spot" article (bonlijn.artnr BEGINS
                  "NOMALED.FUR") in the rolling 12-months window
                  (TODAY - 365 .. TODAY, both bounds inclusive).
    Business rules (per docs/architecture/verkoop-fur-ontwerp.md, Marc-
                  confirmed):
                  - Query strategy is indexed-artnr-first: FOR EACH bonlijn
                    NO-LOCK WHERE bonlijn.artnr BEGINS "NOMALED.FUR" (uses
                    bonlijn-x2/x3), excluding structural lines (subtotaal/
                    kolomtitel/infolijn), then FIND bon (indexed PK lookup)
                    and FIND klant (indexed PK lookup) to narrow further.
                    bon.datum has no dedicated index but is only evaluated
                    against the already-narrowed bonlijn.artnr candidate
                    set, so this is not a full-table-scan risk (see design
                    doc for the full rationale).
                  - bon.type <> "ORDERBEVESTIGING" is excluded (Marc
                    decision #1).
                  - Cancelled-order heuristic (Marc decision #2, accepted
                    risk): bon.b-bedrag ("bedrag" in the API/design doc,
                    the actual DB column is b-bedrag - see docs/backend/
                    bon.md field map) = 0 is excluded. annul-bon always
                    zeroes bedrag as part of the cancel flow, and stempel
                    falls back to "O" (indistinguishable from a
                    never-confirmed open order), so bedrag = 0 is the only
                    remaining observable residue of a cancel action.
                  - klant.swNomaled = FALSE or missing klant row -> excluded
                    (dealer scope + can't confirm swNomaled without the row).
                  - Only the primary bon.klnr is attributed - klnr2/klnr3
                    are NOT considered (no confirmed legacy meaning, would
                    double-count one order across dealer rows).
                  - naam is klant.naam, live/current - not a point-in-time
                    bon.naam snapshot.
                  - aantalFurOrders = COUNT(DISTINCT bonnr) - counts orders,
                    not lines (Edge Case #1). totaalAantalStuks =
                    SUM(bonlijn.aantal) over ALL matching lines, ungrouped
                    by bonnr. laatsteBesteldatum = MAX(bon.datum).
                  - Result sorted BY totaalAantalStuks DESCENDING (Marc-
                    confirmed, overrides the architect's original
                    laatsteBesteldatum suggestion - see design doc Open
                    flags #3).
                  - Read-only. NO-LOCK reads throughout - no writes
                    anywhere in this feature.
    Syntax      : Called from Luna.Web.RapportageHandler (GET /rapportage/verkoop-fur)
    Description : Owns all DB access for this feature - no direct DB
                  access is allowed from the WebHandler layer.
    Author(s)   : Devin
    Created     : 2026-09-03
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.VerkoopFurBE:

    /* Public/serialized result. One flat temp-table, no nested
       ProDataSet relations needed - same pattern as LakproductieBE's
       ttLakproductieLine (one platte serialisatie). */
    /* Primary index sorts BY totaalAantalStuks DESCENDING directly, so
       the default traversal order used when this table's HANDLE is
       passed straight to WRITE-JSON (no explicit query) already matches
       the required response ordering (Marc-confirmed, design doc Open
       flags #3) without needing a second sort pass. idx-klnr is a
       secondary lookup index only, not used for output ordering. */
    DEFINE TEMP-TABLE ttVerkoopFurDealer NO-UNDO SERIALIZE-NAME "items":u
        FIELD klnr               AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD naam                AS CHARACTER SERIALIZE-NAME "naam":u
        FIELD aantalFurOrders     AS INTEGER   SERIALIZE-NAME "aantalFurOrders":u
        FIELD totaalAantalStuks   AS DECIMAL   SERIALIZE-NAME "totaalAantalStuks":u
        FIELD laatsteBesteldatum  AS DATE      SERIALIZE-NAME "laatsteBesteldatum":u
        INDEX idx-sort IS PRIMARY totaalAantalStuks DESCENDING
        INDEX idx-klnr klnr.

    /* Internal working temp-table, NOT serialized - lives only inside
       this class during the calculation. One row per matching bonlijn. */
    DEFINE TEMP-TABLE ttMatchLine NO-UNDO
        FIELD bonnr  AS INTEGER
        FIELD klnr   AS INTEGER
        FIELD naam   AS CHARACTER
        FIELD aantal AS DECIMAL
        FIELD datum  AS DATE
        INDEX idx-klnr-bonnr klnr bonnr.

    DEFINE PRIVATE VARIABLE cFurArtnrPrefix AS CHARACTER NO-UNDO INITIAL "NOMALED.FUR":u.
    DEFINE PRIVATE VARIABLE cOrderType      AS CHARACTER NO-UNDO INITIAL "ORDERBEVESTIGING":u.

    /* Soft guard only (per design doc) - logs a warning if exceeded, does
       NOT truncate the result. This report must stay complete. */
    DEFINE PRIVATE VARIABLE iMatchLineWarnCap AS INTEGER NO-UNDO INITIAL 50000.

    /*------------------------------------------------------------------------------
        Purpose: Builds the Verkoop FUR dealer overview for the rolling
                 12-months window (TODAY - 365 .. TODAY, inclusive).
        Notes  : NO-LOCK reads only. Read-only feature, no writes anywhere.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetVerkoopFurOverzicht( OUTPUT pdPeriodeVan AS DATE, OUTPUT pdPeriodeTot AS DATE ):

        DEFINE VARIABLE iMatchLineCount AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttVerkoopFurDealer.
        EMPTY TEMP-TABLE ttMatchLine.

        ASSIGN
            pdPeriodeVan = TODAY - 365
            pdPeriodeTot = TODAY.

        /* Step 1: indexed artnr-prefix scan, narrowing to bon/klant per
           match. See class header for the full rationale. */
        FOR EACH bonlijn NO-LOCK
            WHERE bonlijn.artnr    BEGINS cFurArtnrPrefix
              AND bonlijn.subtotaal  EQ FALSE
              AND bonlijn.kolomtitel EQ FALSE
              AND bonlijn.infolijn   EQ FALSE:

            FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ bonlijn.bonnr NO-ERROR.
            IF NOT AVAILABLE bon THEN NEXT.

            IF bon.type NE cOrderType THEN NEXT.
            IF bon.datum LT pdPeriodeVan OR bon.datum GT pdPeriodeTot THEN NEXT.
            IF bon.b-bedrag EQ 0 THEN NEXT.

            FIND FIRST klant NO-LOCK WHERE klant.klnr EQ bon.klnr NO-ERROR.
            IF NOT AVAILABLE klant THEN NEXT.
            IF klant.swNomaled EQ FALSE THEN NEXT.

            CREATE ttMatchLine.
            ASSIGN
                ttMatchLine.bonnr  = bon.bonnr
                ttMatchLine.klnr   = klant.klnr
                ttMatchLine.naam   = klant.naam
                ttMatchLine.aantal = bonlijn.aantal
                ttMatchLine.datum  = bon.datum.

        END.

        iMatchLineCount = 0.
        FOR EACH ttMatchLine NO-LOCK:
            iMatchLineCount = iMatchLineCount + 1.
        END.
        IF iMatchLineCount GT iMatchLineWarnCap THEN
            MESSAGE SUBSTITUTE("VerkoopFurBE: ttMatchLine has &1 rows, exceeding the soft &2-row guard - " +
                "full result is still returned, no truncation (see design doc).":u,
                iMatchLineCount, iMatchLineWarnCap)
                VIEW-AS ALERT-BOX INFO.

        /* Step 2: in-memory aggregation per klnr, small result set. */
        AggregateByKlant().

        RETURN TEMP-TABLE ttVerkoopFurDealer:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Aggregates ttMatchLine into ttVerkoopFurDealer, one row
                 per klnr, then sorts BY totaalAantalStuks DESCENDING.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID AggregateByKlant():

        DEFINE VARIABLE iAantalFurOrders    AS INTEGER   NO-UNDO.
        DEFINE VARIABLE dTotaalAantalStuks  AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dLaatsteBesteldatum AS DATE      NO-UNDO.
        DEFINE VARIABLE cNaam               AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iLastBonnr          AS INTEGER   NO-UNDO.

        FOR EACH ttMatchLine NO-LOCK BREAK BY ttMatchLine.klnr BY ttMatchLine.bonnr:

            IF FIRST-OF(ttMatchLine.klnr) THEN
                ASSIGN
                    iAantalFurOrders    = 0
                    dTotaalAantalStuks  = 0
                    dLaatsteBesteldatum = ?
                    cNaam               = ttMatchLine.naam
                    iLastBonnr          = 0.

            /* COUNT(DISTINCT bonnr) - relies on the BY ttMatchLine.bonnr
               sub-sort so each distinct bonnr for this klnr is only
               counted once, on its first row. */
            IF ttMatchLine.bonnr NE iLastBonnr THEN
                ASSIGN
                    iAantalFurOrders = iAantalFurOrders + 1
                    iLastBonnr       = ttMatchLine.bonnr.

            dTotaalAantalStuks = dTotaalAantalStuks + ttMatchLine.aantal.

            IF dLaatsteBesteldatum EQ ? OR ttMatchLine.datum GT dLaatsteBesteldatum THEN
                dLaatsteBesteldatum = ttMatchLine.datum.

            IF LAST-OF(ttMatchLine.klnr) THEN
            DO:
                CREATE ttVerkoopFurDealer.
                ASSIGN
                    ttVerkoopFurDealer.klnr              = ttMatchLine.klnr
                    ttVerkoopFurDealer.naam              = cNaam
                    ttVerkoopFurDealer.aantalFurOrders    = iAantalFurOrders
                    ttVerkoopFurDealer.totaalAantalStuks  = dTotaalAantalStuks
                    ttVerkoopFurDealer.laatsteBesteldatum = dLaatsteBesteldatum.
            END.

        END.

        /* No explicit sort step needed here - ttVerkoopFurDealer's
           PRIMARY index is defined BY totaalAantalStuks DESCENDING (see
           the temp-table definition above), so the default traversal
           order already matches the required response ordering. */

    END METHOD.

END CLASS.
