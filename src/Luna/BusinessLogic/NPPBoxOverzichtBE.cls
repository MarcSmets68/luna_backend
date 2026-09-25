/*------------------------------------------------------------------------
    File        : NPPBoxOverzichtBE.cls
    Purpose     : Business Entity for the NPP "Boxoverzicht" scan lookup -
                  given a raw scanned box label (e.g. "B12345-1" or
                  "12345-1"), returns the bon header (bonnr/groepnr/klant),
                  a status remark (opmerking), and the aggregated article
                  list (summed bonlijn.gereserv per artnr) for that
                  bon/groep combination. 1:1 port of the read-side logic in
                  \\LHDC01\TESTLUNA$\LunaV12\NPP\NPPBoxView.w
                  (valid-scan / toon-order / vul-temptable procedures).
    Errors      : Progress.Lang.AppError("Onbekend boxlabel":u, 400) for a
                  malformed scan value; AppError("Bon niet gevonden":u, 404)
                  when the parsed bonnr doesn't exist. An empty (zero
                  matching bonlijn rows) box is NOT an error - GetBoxOverzicht
                  returns normally with "empty": true and an empty
                  "articles" array.
    Author(s)   : Devin
    Created     : 2026-09-17
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.

CLASS Luna.BusinessLogic.NPPBoxOverzichtBE:

    /* Grouping temp-table: one row per distinct output artnr, aantal is
       the running sum of bonlijn.gereserv across all matching bonlijn
       rows that resolve to that artnr (mirrors tmp-bonlijn in the legacy
       NPPBoxView.w, plus a barcode column the new UI contract adds). */
    DEFINE TEMP-TABLE ttArtikel NO-UNDO
        FIELD artnr        AS CHARACTER
        FIELD omschrijving AS CHARACTER
        FIELD aantal       AS DECIMAL
        FIELD barcode      AS CHARACTER
        INDEX p-artnr IS UNIQUE artnr.

    /*------------------------------------------------------------------------------
        Purpose: Parses a raw scanned box label into a bonnr/groepnr pair.
                 Shape: optional leading "B"/"b", exactly one dash, both
                 sides must parse as INTEGER - e.g. "B12345-1" or
                 "12345-1". Mirrors the valid-scan() FUNCTION in the legacy
                 NPPBoxView.w (the leading "B" is purely cosmetic on the
                 printed label - the digits are what matter).
        Errors : Progress.Lang.AppError("Onbekend boxlabel":u, 400) on any
                 parse failure.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ParseScan(
        INPUT pcScan AS CHARACTER, OUTPUT piBonnr AS INTEGER, OUTPUT piGroepnr AS INTEGER ):

        DEFINE VARIABLE cScan  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cLeft  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRight AS CHARACTER NO-UNDO.

        cScan = TRIM(pcScan).

        IF cScan BEGINS "B":u OR cScan BEGINS "b":u THEN
            cScan = SUBSTRING(cScan, 2).

        IF NUM-ENTRIES(cScan, "-":u) NE 2 THEN
            UNDO, THROW NEW Progress.Lang.AppError("Onbekend boxlabel":u, 400).

        ASSIGN
            cLeft  = ENTRY(1, cScan, "-":u)
            cRight = ENTRY(2, cScan, "-":u)
            .

        piBonnr   = INTEGER(cLeft) NO-ERROR.
        piGroepnr = INTEGER(cRight) NO-ERROR.

        IF piBonnr EQ ? OR piGroepnr EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError("Onbekend boxlabel":u, 400).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Builds the aggregated article list (ttArtikel) for the
                 given bonnr/groepnr, applying the exact same
                 include/exclude filter as vul-temptable in the legacy
                 NPPBoxView.w (verified against that source): only
                 bonlijn rows that are NOT subtotaal, NOT kolomtitel, NOT
                 infolijn, NOT montage, have gereserv > 0, and ARE
                 swEffectief, using bonlijn-x11. Grouped/summed by
                 resolved output artnr (artikel.x-ref when available and
                 non-blank, else the raw bonlijn.artnr).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID VulArtikelen( INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER ):

        DEFINE VARIABLE cArtnr        AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cOmschrijving AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cBarcode      AS CHARACTER NO-UNDO.

        EMPTY TEMP-TABLE ttArtikel.

        FOR EACH bonlijn NO-LOCK
            WHERE bonlijn.bonnr       EQ piBonnr
              AND bonlijn.groepnr     EQ piGroepnr
              AND bonlijn.subtotaal   EQ FALSE
              AND bonlijn.kolomtitel  EQ FALSE
              AND bonlijn.infolijn    EQ FALSE
              AND bonlijn.montage     EQ FALSE
              AND bonlijn.gereserv    GT 0
              AND bonlijn.swEffectief EQ TRUE
            USE-INDEX bonlijn-x11:

            FIND FIRST artikel OF bonlijn NO-LOCK NO-ERROR.

            ASSIGN
                cArtnr        = IF AVAILABLE artikel AND artikel.x-ref NE "":u THEN artikel.x-ref ELSE bonlijn.artnr
                cOmschrijving = IF AVAILABLE artikel AND artikel.omschr-n NE "":u THEN artikel.omschr-n ELSE bonlijn.omschr
                cBarcode      = IF AVAILABLE artikel THEN artikel.barcode ELSE "":u
                .

            FIND FIRST ttArtikel WHERE ttArtikel.artnr EQ cArtnr NO-ERROR.
            IF NOT AVAILABLE ttArtikel THEN
            DO:
                CREATE ttArtikel.
                ASSIGN
                    ttArtikel.artnr        = cArtnr
                    ttArtikel.omschrijving = cOmschrijving
                    ttArtikel.barcode      = cBarcode
                    .
            END.

            ttArtikel.aantal = ttArtikel.aantal + bonlijn.gereserv.

        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Main entry point - parses pcScan, looks up the bon and
                 its status remark, aggregates the matching bonlijn rows
                 into an article list, and returns the full JSON result
                 per the /npp/boxoverzicht API contract.
        Errors : AppError 400 ("Onbekend boxlabel":u) for a malformed
                 scan; AppError 404 ("Bon niet gevonden":u) when the
                 parsed bonnr doesn't exist. An empty article list is not
                 an error - see the "empty" flag in the returned JSON.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject GetBoxOverzicht( INPUT pcScan AS CHARACTER ):

        DEFINE VARIABLE piBonnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE piGroepnr  AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cOpmerking AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oResult    AS JsonObject NO-UNDO.
        DEFINE VARIABLE oArticles  AS JsonArray  NO-UNDO.
        DEFINE VARIABLE oArticle   AS JsonObject NO-UNDO.
        DEFINE VARIABLE lEmpty     AS LOGICAL    NO-UNDO.

        ParseScan(pcScan, OUTPUT piBonnr, OUTPUT piGroepnr).

        FIND FIRST bon WHERE bon.bonnr EQ piBonnr NO-LOCK NO-ERROR.
        IF NOT AVAILABLE bon THEN
            UNDO, THROW NEW Progress.Lang.AppError("Bon niet gevonden":u, 404).

        FIND FIRST bon_led NO-LOCK
            WHERE bon_led.bonnr    EQ piBonnr
              AND bon_led.groepnr  EQ piGroepnr
              AND bon_led.led_lijn EQ 0
              AND bon_led.lijnnr   EQ 90 NO-ERROR.

        cOpmerking = IF AVAILABLE bon_led AND bon_led.opm NE "":u THEN bon_led.opm ELSE "niets":u.

        VulArtikelen(piBonnr, piGroepnr).

        oArticles = NEW JsonArray().

        FOR EACH ttArtikel NO-LOCK BY ttArtikel.artnr:
            oArticle = NEW JsonObject().
            oArticle:Add("artnr":u, ttArtikel.artnr).
            oArticle:Add("omschrijving":u, ttArtikel.omschrijving).
            oArticle:Add("aantal":u, ttArtikel.aantal).
            oArticle:Add("barcode":u, ttArtikel.barcode).
            oArticles:Add(oArticle).
        END.

        lEmpty = (oArticles:LENGTH EQ 0).

        oResult = NEW JsonObject().
        oResult:Add("bonnr":u, piBonnr).
        oResult:Add("groepnr":u, piGroepnr).
        oResult:Add("klant":u, bon.naam).
        oResult:Add("opmerking":u, cOpmerking).
        oResult:Add("empty":u, lEmpty).
        oResult:Add("articles":u, oArticles).

        RETURN oResult.

    END METHOD.

END CLASS.
