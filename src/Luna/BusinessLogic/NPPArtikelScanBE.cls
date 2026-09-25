/*------------------------------------------------------------------------
    File        : NPPArtikelScanBE.cls
    Purpose     : Business Entity for the NPP "Artikelscan" lookup - given
                  a raw scanned value (artnr, "nummer-aantal" dash form,
                  barcode, or subcode), resolves it to a single article
                  (or reports not_found / multiple candidates). 1:1 port
                  of the read-side resolution logic in
                  \\LHDC01\TESTLUNA$\LunaV12\CheckBarcode.p (verified
                  directly against that source - see method comments
                  below for line-level notes and one deliberate, documented
                  divergence from the original design draft).
    Errors      : Progress.Lang.AppError("Onbekend barcode-formaat":u, 400)
                  when a scan contains a dash but either side of the
                  first dash fails to parse as INTEGER/DECIMAL - this is
                  validation the legacy CheckBarcode.p lacks (it would
                  either silently skip the nummer-lookup branch on a bad
                  left side, or blow up unhandled on a bad right side
                  since its DECIMAL() cast there has no NO-ERROR). Not
                  found / multiple candidates are NOT errors - ResolveScan
                  returns normally with status "not_found"/"multiple".
    Divergence  : The original design draft assumed that when the
                  "nummer-aantal" dash form parses but no artikel.nummer
                  matches, the barcode/subcode fallback (step 3) searches
                  on the WHOLE original scan string. Verified against
                  CheckBarcode.p line-by-line and that is NOT what the
                  legacy code does: at line 27 (ws-scan = STRING(ws-nummer))
                  the working scan variable is overwritten with just the
                  left-of-dash numeric part BEFORE the nummer FIND at line
                  28, and if that FIND fails, the fallback FOR EACH loops
                  at lines 44/52 run against that already-overwritten
                  ws-scan - i.e. against the left-of-dash numeric string,
                  not the original raw scan with the dash still in it.
                  This BE replicates the true legacy behaviour (fallback
                  uses the left-of-dash numeric string) rather than the
                  draft's assumption. Flagging explicitly per the "fix the
                  design doc, don't let it drift" rule - the architect's
                  design doc for this endpoint should be updated to match.
    Author(s)   : Devin
    Created     : 2026-09-18
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.NPPArtikelScanBE:

    /* Dedup temp-table for the barcode/subcode candidate search (step 3),
       keyed on artnr - mirrors the legacy s-art temp-table in
       CheckBarcode.p / artscan.i. */
    DEFINE TEMP-TABLE ttCandidate NO-UNDO
        FIELD artnr        AS CHARACTER
        FIELD omschrijving AS CHARACTER
        INDEX p-artnr IS UNIQUE artnr.

    /*------------------------------------------------------------------------------
        Purpose: Builds the "article" JsonObject for a resolved artikel
                 buffer, per the /npp/artikelscan API contract. pdAantal
                 is added only when this resolution came from the
                 "nummer-aantal" dash form (pass ? otherwise so the key
                 is omitted entirely, never sent as 0/null).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject BuildArticleJson( INPUT pdAantal AS DECIMAL ):

        DEFINE VARIABLE oArticle AS JsonObject NO-UNDO.

        oArticle = NEW JsonObject().
        oArticle:Add("artnr":u, artikel.artnr).
        oArticle:Add("nummer":u, artikel.nummer).
        oArticle:Add("xref":u, artikel.x-ref).
        oArticle:Add("omschrijving":u, artikel.omschr-n).
        oArticle:Add("barcode":u, artikel.barcode).
        oArticle:Add("pickingkode":u, artikel.pickingkode).
        oArticle:Add("pickingkleur":u, artikel.pickingkleur).

        IF pdAantal NE ? THEN
            oArticle:Add("aantal":u, pdAantal).

        RETURN oArticle.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Step 3 of the resolution - builds the deduplicated
                 candidate set (ttCandidate) for pcSearchScan via a direct
                 artikel.barcode match (artikel-x04) UNION with
                 art-subcodes.barcode matches (art-subcodes-x1, resolved
                 to their owning artikel via art-subcodes.artnr). Mirrors
                 the s-art building loops at the bottom of CheckBarcode.p.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID VulCandidates( INPUT pcSearchScan AS CHARACTER ):

        EMPTY TEMP-TABLE ttCandidate.

        FOR EACH artikel NO-LOCK
            WHERE artikel.barcode EQ pcSearchScan
            USE-INDEX artikel-x04:

            IF NOT CAN-FIND(FIRST ttCandidate WHERE ttCandidate.artnr EQ artikel.artnr) THEN
            DO:
                CREATE ttCandidate.
                ASSIGN
                    ttCandidate.artnr        = artikel.artnr
                    ttCandidate.omschrijving = artikel.omschr-n
                    .
            END.

        END.

        FOR EACH art-subcodes NO-LOCK
            WHERE art-subcodes.barcode EQ pcSearchScan
            USE-INDEX art-subcodes-x1:

            IF NOT CAN-FIND(FIRST ttCandidate WHERE ttCandidate.artnr EQ art-subcodes.artnr) THEN
            DO:
                FIND FIRST artikel WHERE artikel.artnr EQ art-subcodes.artnr
                    NO-LOCK USE-INDEX artikel-x01 NO-ERROR.

                CREATE ttCandidate.
                ASSIGN
                    ttCandidate.artnr        = art-subcodes.artnr
                    ttCandidate.omschrijving = IF AVAILABLE artikel THEN artikel.omschr-n ELSE "":u
                    .
            END.

        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Main entry point - resolves pcScan to a single article
                 (or not_found / multiple), per the /npp/artikelscan API
                 contract. See the class header for the exact
                 step-by-step logic, verified against CheckBarcode.p.
        Errors : AppError 400 ("Onbekend barcode-formaat":u) when the scan
                 contains a dash but either side of the first dash fails
                 to parse as INTEGER/DECIMAL. not_found / multiple are NOT
                 errors - they're returned as a normal 200 "status".
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject ResolveScan( INPUT pcScan AS CHARACTER, INPUT pcExpectedArtnr AS CHARACTER ):

        DEFINE VARIABLE cScan           AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iDashPos        AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cLeft           AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cRight          AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iNummer         AS INTEGER    NO-UNDO.
        DEFINE VARIABLE dAantalRaw      AS DECIMAL    NO-UNDO.
        DEFINE VARIABLE dAantal         AS DECIMAL    NO-UNDO.
        DEFINE VARIABLE cSearchScan     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cStatus         AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oResult         AS JsonObject NO-UNDO.
        DEFINE VARIABLE oArticle        AS JsonObject NO-UNDO.
        DEFINE VARIABLE oNullArticle    AS JsonObject NO-UNDO. /* stays unknown (?) - used to add a JSON null for "article" */
        DEFINE VARIABLE oCandidates     AS JsonArray  NO-UNDO.
        DEFINE VARIABLE oCandidate      AS JsonObject NO-UNDO.
        DEFINE VARIABLE lResolved       AS LOGICAL    NO-UNDO INITIAL FALSE.
        DEFINE VARIABLE cResolvedArtnr  AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iCandidateCount AS INTEGER    NO-UNDO.

        cScan       = TRIM(pcScan).
        cSearchScan = cScan.
        dAantal     = ?.

        /* Step 1: direct artnr match. */
        FIND FIRST artikel WHERE artikel.artnr EQ cScan
            NO-LOCK USE-INDEX artikel-x01 NO-ERROR.

        IF AVAILABLE artikel THEN
        DO:
            lResolved      = TRUE.
            cResolvedArtnr = artikel.artnr.
            oArticle       = BuildArticleJson(?).
        END.
        ELSE
        DO:
            iDashPos = INDEX(cScan, "-":u).

            IF iDashPos NE 0 THEN
            DO:
                ASSIGN
                    cLeft  = SUBSTRING(cScan, 1, iDashPos - 1)
                    cRight = SUBSTRING(cScan, iDashPos + 1)
                    .

                iNummer    = INTEGER(cLeft) NO-ERROR.
                dAantalRaw = DECIMAL(cRight) NO-ERROR.

                IF iNummer EQ ? OR dAantalRaw EQ ? THEN
                    UNDO, THROW NEW Progress.Lang.AppError("Onbekend barcode-formaat":u, 400).

                /* Step 2: "nummer-aantal" dash form. Fallback (step 3, if
                   no match) searches on the left-of-dash numeric string,
                   not the original raw scan - see the class header
                   "Divergence" note, this replicates true CheckBarcode.p
                   behaviour (ws-scan is overwritten before the fallback
                   loops run). */
                cSearchScan = STRING(iNummer).

                FIND FIRST artikel WHERE artikel.nummer EQ iNummer
                    NO-LOCK USE-INDEX artikel-x09 NO-ERROR.

                IF AVAILABLE artikel THEN
                DO:
                    lResolved      = TRUE.
                    cResolvedArtnr = artikel.artnr.
                    dAantal        = dAantalRaw / 1000.
                    oArticle       = BuildArticleJson(dAantal).
                END.

            END.
        END.

        IF lResolved THEN
        DO:
            cStatus = "resolved":u.
        END.
        ELSE
        DO:
            /* Step 3: barcode / subcode candidate search on cSearchScan. */
            VulCandidates(cSearchScan).

            iCandidateCount = 0.
            FOR EACH ttCandidate NO-LOCK:
                iCandidateCount = iCandidateCount + 1.
            END.

            IF iCandidateCount EQ 0 THEN
                cStatus = "not_found":u.
            ELSE IF iCandidateCount EQ 1 THEN
            DO:
                FIND FIRST ttCandidate NO-LOCK NO-ERROR.
                FIND FIRST artikel WHERE artikel.artnr EQ ttCandidate.artnr
                    NO-LOCK USE-INDEX artikel-x01 NO-ERROR.

                IF AVAILABLE artikel THEN
                DO:
                    lResolved      = TRUE.
                    cResolvedArtnr = artikel.artnr.
                    oArticle       = BuildArticleJson(?).
                    cStatus        = "resolved":u.
                END.
                ELSE
                    cStatus = "not_found":u.
            END.
            ELSE
                cStatus = "multiple":u.
        END.

        oResult = NEW JsonObject().
        oResult:Add("status":u, cStatus).
        oResult:Add("scan":u, pcScan).

        IF lResolved THEN
            oResult:Add("article":u, oArticle).
        ELSE
            oResult:Add("article":u, oNullArticle).

        oResult:Add("empty":u, NOT lResolved).

        IF cStatus EQ "multiple":u THEN
        DO:
            oCandidates = NEW JsonArray().
            FOR EACH ttCandidate NO-LOCK BY ttCandidate.artnr:
                oCandidate = NEW JsonObject().
                oCandidate:Add("artnr":u, ttCandidate.artnr).
                oCandidate:Add("omschrijving":u, ttCandidate.omschrijving).
                oCandidates:Add(oCandidate).
            END.
            oResult:Add("candidates":u, oCandidates).
        END.

        IF TRIM(pcExpectedArtnr) NE "":u THEN
            oResult:Add("match":u, (cStatus EQ "resolved":u AND cResolvedArtnr EQ pcExpectedArtnr)).

        RETURN oResult.

    END METHOD.

END CLASS.
