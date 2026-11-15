/*------------------------------------------------------------------------
    File        : VerkoopsanalyseBE.cls
    Purpose     : Business Entity for the "Verkoopsanalyse" report: omzet and
                  aantallen per month for selected dealers and selected
                  articles / artikelgroepen, last 12 closed months next to the
                  same 12 months one year earlier. Read-only: NO-LOCK reads
                  throughout, no writes anywhere.
    Syntax      : Called from Luna.Web.RapportageHandler
                  GET /rapportage/verkoopsanalyse?klnr=1,2&artikelen=A|B*
    Description : Owns all DB access + business rules for this report. See
                  the Bruno collection (bruno/Rapportage/Verkoopsanalyse) for
                  the contract. Frontend issue: luna_frontend #77.
                  Rules:
                  1. Periods: huidige periode = the 12 last CLOSED months
                     (first day of the month 12 months back .. last day of the
                     previous month); vorige periode = the same 12 months one
                     year earlier. Month bucket = bon.datum (authority).
                  2. Dealer scope: the requested klnrs (any existing klant), or
                     - when none are given - every klant with swNomaled = TRUE
                     (same set as GET /web/klant?nomaled=true, which feeds the
                     frontend dealer picker). Only the primary bon.klnr counts
                     (same as VerkoopFurBE).
                  3. Articles: one result row per requested entry, in request
                     order. Exact entries are resolved via artikel.artnr, then
                     artikel.x-ref (legacy rule, as OmzetanalyseDealersBE);
                     an unresolvable artnr is matched literally and simply
                     yields zeros. A trailing "*" = BEGINS match (artikelgroep).
                     No entries = all articles together (only "totaal").
                  4. aantal = SUM(bonlijn.aantal) of all real lines (no
                     subtotaal/kolomtitel/infolijn), los and productie alike.
                  5. omzet = exactly the OmzetanalyseDealersBE revenue rule, so
                     both reports agree: only bon.stempel <> "O" and artnr or
                     artikel.x-ref BEGINS "NOMALED."; discount = line korting,
                     else (groepnr <> 0) the subtotaal line's korting for the
                     same bonnr+groepnr, else bon.korting;
                     omzet = aantal * vprijs * (1 - korting / 100).
                  6. totaal never double-counts a line that matches more than
                     one requested row (e.g. "NOMA*" and "NOMALED.FUR01").
                  7. eenheid ("m"/"st"/null) comes from the unit markers in
                     led_lijstparameters (same source as the omzetanalyse);
                     articles that are not listed there get null.
                  Performance: with articles, one indexed bonlijn scan per
                  requested entry (bonlijn-x2, as OmzetanalyseDealersBE); without
                  articles, one bon-datum range scan (bonlijn-x17, as
                  LakproductieVerkoopService) - lines whose denormalized
                  bon-datum is unknown are not reached in that mode.
    Author(s)   : Claude
    Created     : 2026-11-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.VerkoopsanalyseBE:

    /* ===================== Public / serialized result ===================== */

    DEFINE TEMP-TABLE ttAnalyse NO-UNDO SERIALIZE-NAME "analyse":u
        FIELD analyseId        AS INTEGER SERIALIZE-HIDDEN
        FIELD periodeVan       AS DATE SERIALIZE-NAME "periodeVan":u
        FIELD periodeTot       AS DATE SERIALIZE-NAME "periodeTot":u
        FIELD vorigePeriodeVan AS DATE SERIALIZE-NAME "vorigePeriodeVan":u
        FIELD vorigePeriodeTot AS DATE SERIALIZE-NAME "vorigePeriodeTot":u
        INDEX idxPk IS PRIMARY analyseId.

    DEFINE TEMP-TABLE ttDealer NO-UNDO SERIALIZE-NAME "dealers":u
        FIELD analyseId AS INTEGER SERIALIZE-HIDDEN
        FIELD klnr      AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD naam      AS CHARACTER SERIALIZE-NAME "naam":u
        INDEX idxPk IS PRIMARY analyseId naam klnr.

    DEFINE TEMP-TABLE ttRij NO-UNDO SERIALIZE-NAME "rijen":u
        FIELD analyseId    AS INTEGER SERIALIZE-HIDDEN
        FIELD rijId        AS INTEGER SERIALIZE-HIDDEN
        FIELD artnr        AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschrijving AS CHARACTER SERIALIZE-NAME "omschrijving":u
        FIELD swBegins     AS LOGICAL   SERIALIZE-NAME "swBegins":u
        FIELD eenheid      AS CHARACTER SERIALIZE-NAME "eenheid":u
        INDEX idxPk IS PRIMARY analyseId rijId.

    DEFINE TEMP-TABLE ttRijMaand NO-UNDO SERIALIZE-NAME "maanden":u
        FIELD rijId           AS INTEGER SERIALIZE-HIDDEN
        FIELD idx             AS INTEGER SERIALIZE-HIDDEN
        FIELD maand           AS CHARACTER SERIALIZE-NAME "maand":u
        FIELD aantal          AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD omzet           AS DECIMAL   SERIALIZE-NAME "omzet":u
        FIELD aantalVorigJaar AS DECIMAL   SERIALIZE-NAME "aantalVorigJaar":u
        FIELD omzetVorigJaar  AS DECIMAL   SERIALIZE-NAME "omzetVorigJaar":u
        INDEX idxPk IS PRIMARY rijId idx.

    DEFINE TEMP-TABLE ttTotaal NO-UNDO SERIALIZE-NAME "totaal":u
        FIELD analyseId       AS INTEGER SERIALIZE-HIDDEN
        FIELD idx             AS INTEGER SERIALIZE-HIDDEN
        FIELD maand           AS CHARACTER SERIALIZE-NAME "maand":u
        FIELD aantal          AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD omzet           AS DECIMAL   SERIALIZE-NAME "omzet":u
        FIELD aantalVorigJaar AS DECIMAL   SERIALIZE-NAME "aantalVorigJaar":u
        FIELD omzetVorigJaar  AS DECIMAL   SERIALIZE-NAME "omzetVorigJaar":u
        INDEX idxPk IS PRIMARY analyseId idx.

    DEFINE DATASET dsVerkoopsanalyse SERIALIZE-NAME "dsVerkoopsanalyse":u
        FOR ttAnalyse, ttDealer, ttRij, ttRijMaand, ttTotaal
        DATA-RELATION rDealer FOR ttAnalyse, ttDealer   RELATION-FIELDS (analyseId, analyseId) NESTED
        DATA-RELATION rRij    FOR ttAnalyse, ttRij      RELATION-FIELDS (analyseId, analyseId) NESTED
        DATA-RELATION rMaand  FOR ttRij,     ttRijMaand RELATION-FIELDS (rijId, rijId) NESTED
        DATA-RELATION rTotaal FOR ttAnalyse, ttTotaal   RELATION-FIELDS (analyseId, analyseId) NESTED.

    /* ===================== Private working tables (never serialized) ===================== */

    /* Dealer scope: bon.klnr must be in here. */
    DEFINE PRIVATE TEMP-TABLE ttKlant NO-UNDO
        FIELD klnr AS INTEGER
        FIELD naam AS CHARACTER
        INDEX idxPk IS PRIMARY UNIQUE klnr.

    /* One per requested article entry (= one result row). */
    DEFINE PRIVATE TEMP-TABLE ttReq NO-UNDO
        FIELD rijId    AS INTEGER
        FIELD artnr    AS CHARACTER   /* as requested, without the trailing "*" */
        FIELD pat      AS CHARACTER   /* bonlijn.artnr match target */
        FIELD isBegins AS LOGICAL
        FIELD omschr   AS CHARACTER
        FIELD eenheid  AS CHARACTER
        INDEX idxPk IS PRIMARY UNIQUE rijId.

    /* Unit markers from led_lijstparameters: artnr (+ swBegins) -> "m"/"st". */
    DEFINE PRIVATE TEMP-TABLE ttUnit NO-UNDO
        FIELD artnr    AS CHARACTER
        FIELD swBegins AS LOGICAL
        FIELD eenheid  AS CHARACTER
        INDEX idxPk IS PRIMARY artnr swBegins.

    /* bon cache. bIdx = 0 -> out of scope; 1..12 vorige periode, 13..24 huidige. */
    DEFINE PRIVATE TEMP-TABLE ttBon NO-UNDO
        FIELD bonNr    AS INTEGER
        FIELD bIdx     AS INTEGER
        FIELD bStempel AS CHARACTER
        FIELD bKorting AS DECIMAL
        INDEX idxPk IS PRIMARY UNIQUE bonNr.

    DEFINE PRIVATE TEMP-TABLE ttArt NO-UNDO
        FIELD artNr     AS CHARACTER
        FIELD isNomaled AS LOGICAL
        INDEX idxPk IS PRIMARY UNIQUE artNr.

    /* korting of the subtotaal line per (bonnr, groepnr). */
    DEFINE PRIVATE TEMP-TABLE ttGrp NO-UNDO
        FIELD bonNr    AS INTEGER
        FIELD groepNr  AS INTEGER
        FIELD isFound  AS LOGICAL
        FIELD gKorting AS DECIMAL
        INDEX idxPk IS PRIMARY UNIQUE bonNr groepNr.

    /* Aggregates per row (rijId 0 = totaal) and month index 1..24. */
    DEFINE PRIVATE TEMP-TABLE ttAgg NO-UNDO
        FIELD rijId   AS INTEGER
        FIELD idx     AS INTEGER
        FIELD aAantal AS DECIMAL
        FIELD aOmzet  AS DECIMAL
        INDEX idxPk IS PRIMARY UNIQUE rijId idx.

    /* Lines already counted in the totaal (rule 6). */
    DEFINE PRIVATE TEMP-TABLE ttLijnSeen NO-UNDO
        FIELD cRowid AS CHARACTER
        INDEX idxPk IS PRIMARY UNIQUE cRowid.

    /* ===================== Request state ===================== */
    DEFINE PRIVATE VARIABLE dPeriodeVan  AS DATE    NO-UNDO.
    DEFINE PRIVATE VARIABLE dPeriodeTot  AS DATE    NO-UNDO.
    DEFINE PRIVATE VARIABLE dVorigVan    AS DATE    NO-UNDO.
    DEFINE PRIVATE VARIABLE dVorigTot    AS DATE    NO-UNDO.
    DEFINE PRIVATE VARIABLE iBaseMonths  AS INTEGER NO-UNDO.
    DEFINE PRIVATE VARIABLE lMeerdereRij AS LOGICAL NO-UNDO.

    DEFINE PRIVATE VARIABLE cNomaledPrefix AS CHARACTER NO-UNDO INITIAL "NOMALED.":u.

    /*------------------------------------------------------------------------------
        Purpose: Builds the Verkoopsanalyse.
                 pcKlnrs     : comma-separated positive klnrs, "" = all Nomaled dealers
                 pcArtikelen : "|"-separated artnrs, trailing "*" = BEGINS, "" = all
                 Both lists are already format-validated by the WebHandler.
        Throws : AppError 400 for an unknown klnr.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetAnalyse( INPUT pcKlnrs AS CHARACTER, INPUT pcArtikelen AS CHARACTER ):

        EMPTY TEMP-TABLE ttAnalyse.
        EMPTY TEMP-TABLE ttDealer.
        EMPTY TEMP-TABLE ttRij.
        EMPTY TEMP-TABLE ttRijMaand.
        EMPTY TEMP-TABLE ttTotaal.
        EMPTY TEMP-TABLE ttKlant.
        EMPTY TEMP-TABLE ttReq.
        EMPTY TEMP-TABLE ttUnit.
        EMPTY TEMP-TABLE ttBon.
        EMPTY TEMP-TABLE ttArt.
        EMPTY TEMP-TABLE ttGrp.
        EMPTY TEMP-TABLE ttAgg.
        EMPTY TEMP-TABLE ttLijnSeen.

        /* Rule 1: periods. */
        ASSIGN
            dPeriodeTot = DATE(MONTH(TODAY), 1, YEAR(TODAY)) - 1
            dPeriodeVan = AddMonths(DATE(MONTH(dPeriodeTot), 1, YEAR(dPeriodeTot)), -11)
            dVorigVan   = AddMonths(dPeriodeVan, -12)
            dVorigTot   = dPeriodeVan - 1
            iBaseMonths = YEAR(dVorigVan) * 12 + MONTH(dVorigVan) - 1.

        CREATE ttAnalyse.
        ASSIGN
            ttAnalyse.analyseId        = 1
            ttAnalyse.periodeVan       = dPeriodeVan
            ttAnalyse.periodeTot       = dPeriodeTot
            ttAnalyse.vorigePeriodeVan = dVorigVan
            ttAnalyse.vorigePeriodeTot = dVorigTot.

        LoadDealers(pcKlnrs).
        LoadUnits().
        LoadArtikelen(pcArtikelen).

        IF CAN-FIND(FIRST ttReq) THEN
            ScanArtikelen().
        ELSE
            ScanAlles().

        BuildOutput().

        RETURN DATASET dsVerkoopsanalyse:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: First day of the month pdFirst + piMonths months.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DATE AddMonths( INPUT pdFirst AS DATE, INPUT piMonths AS INTEGER ):

        DEFINE VARIABLE iTotal AS INTEGER NO-UNDO.

        iTotal = YEAR(pdFirst) * 12 + MONTH(pdFirst) - 1 + piMonths.

        RETURN DATE((iTotal MOD 12) + 1, 1, INTEGER(TRUNCATE(iTotal / 12, 0))).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Month index of pdDate: 1..12 vorige periode, 13..24 huidige
                 periode, 0 when outside both.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER MonthIdx( INPUT pdDate AS DATE ):

        IF pdDate EQ ? OR pdDate LT dVorigVan OR pdDate GT dPeriodeTot THEN
            RETURN 0.

        RETURN YEAR(pdDate) * 12 + MONTH(pdDate) - 1 - iBaseMonths + 1.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: "YYYY-MM" label of month index piIdx (13..24 -> huidige periode).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER MaandLabel( INPUT piIdx AS INTEGER ):

        DEFINE VARIABLE dMaand AS DATE NO-UNDO.

        dMaand = AddMonths(dVorigVan, piIdx - 1).

        RETURN STRING(YEAR(dMaand), "9999":u) + "-":u + STRING(MONTH(dMaand), "99":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Rule 2 - fills the dealer scope.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID LoadDealers( INPUT pcKlnrs AS CHARACTER ):

        DEFINE VARIABLE i      AS INTEGER NO-UNDO.
        DEFINE VARIABLE iKlnr  AS INTEGER NO-UNDO.

        IF pcKlnrs EQ ? OR pcKlnrs EQ "":u THEN
        DO:
            /* swNomaled can be unknown (?) - explicit EQ TRUE, as KlantBE. */
            FOR EACH klant NO-LOCK WHERE klant.swNomaled EQ TRUE:
                AddDealer(klant.klnr, klant.naam).
            END.
            RETURN.
        END.

        DO i = 1 TO NUM-ENTRIES(pcKlnrs):
            iKlnr = INTEGER(ENTRY(i, pcKlnrs)).
            FIND FIRST klant NO-LOCK WHERE klant.klnr EQ iKlnr NO-ERROR.
            IF NOT AVAILABLE klant THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Onbekende klant &1":u, iKlnr), 400).
            AddDealer(klant.klnr, klant.naam).
        END.

    END METHOD.

    METHOD PRIVATE VOID AddDealer( INPUT piKlnr AS INTEGER, INPUT pcNaam AS CHARACTER ):

        IF CAN-FIND(ttKlant WHERE ttKlant.klnr EQ piKlnr) THEN RETURN.

        CREATE ttKlant.
        ASSIGN
            ttKlant.klnr = piKlnr
            ttKlant.naam = (IF pcNaam EQ ? THEN "":u ELSE pcNaam).

        CREATE ttDealer.
        ASSIGN
            ttDealer.analyseId = 1
            ttDealer.klnr      = ttKlant.klnr
            ttDealer.naam      = ttKlant.naam.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Rule 7 - reads the unit markers of led_lijstparameters (same
                 walk as OmzetanalyseDealersBE:LoadSpecs): "m"/"st" rows set the
                 unit for the following rows of the same category.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID LoadUnits():

        DEFINE VARIABLE cCurCat AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lFirst  AS LOGICAL   NO-UNDO INITIAL TRUE.
        DEFINE VARIABLE cUnit   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cArtnr  AS CHARACTER NO-UNDO.

        FOR EACH led_lijstparameters NO-LOCK:

            IF lFirst OR led_lijstparameters.categorie NE cCurCat THEN
                ASSIGN
                    lFirst  = FALSE
                    cCurCat = led_lijstparameters.categorie
                    cUnit   = ?.

            cArtnr = TRIM(led_lijstparameters.artnr).
            IF cArtnr EQ "":u THEN NEXT.

            IF cArtnr EQ "m":u OR cArtnr EQ "st":u THEN
            DO:
                cUnit = LOWER(cArtnr).
                NEXT.
            END.

            IF cUnit EQ ? THEN NEXT.

            IF NOT CAN-FIND(FIRST ttUnit WHERE ttUnit.artnr EQ cArtnr
                                           AND ttUnit.swBegins EQ led_lijstparameters.swBegins) THEN
            DO:
                CREATE ttUnit.
                ASSIGN
                    ttUnit.artnr    = cArtnr
                    ttUnit.swBegins = led_lijstparameters.swBegins
                    ttUnit.eenheid  = cUnit.
            END.

        END.

    END METHOD.

    METHOD PRIVATE CHARACTER UnitFor( INPUT pcArtnr AS CHARACTER, INPUT plBegins AS LOGICAL ):

        FIND FIRST ttUnit WHERE ttUnit.artnr EQ pcArtnr AND ttUnit.swBegins EQ plBegins NO-ERROR.

        RETURN (IF AVAILABLE ttUnit THEN ttUnit.eenheid ELSE ?).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Rule 3 - one ttReq per requested entry, resolved to a match target.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID LoadArtikelen( INPUT pcArtikelen AS CHARACTER ):

        DEFINE VARIABLE i       AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cEntry  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lBegins AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE iRij    AS INTEGER   NO-UNDO.

        IF pcArtikelen EQ ? OR pcArtikelen EQ "":u THEN RETURN.

        DO i = 1 TO NUM-ENTRIES(pcArtikelen, "|":u):

            cEntry  = TRIM(ENTRY(i, pcArtikelen, "|":u)).
            lBegins = (cEntry NE "":u AND SUBSTRING(cEntry, LENGTH(cEntry), 1) EQ "*":u).
            IF lBegins THEN
                cEntry = RIGHT-TRIM(cEntry, "*":u).
            IF cEntry EQ "":u THEN NEXT.

            iRij = iRij + 1.
            CREATE ttReq.
            ASSIGN
                ttReq.rijId    = iRij
                ttReq.artnr    = cEntry
                ttReq.pat      = cEntry
                ttReq.isBegins = lBegins
                ttReq.omschr   = ?
                ttReq.eenheid  = UnitFor(cEntry, lBegins).

            IF NOT lBegins THEN
            DO:
                FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ cEntry NO-ERROR.
                IF NOT AVAILABLE artikel THEN
                    FIND FIRST artikel NO-LOCK WHERE artikel.x-ref EQ cEntry NO-ERROR.
                IF AVAILABLE artikel THEN
                DO:
                    ttReq.pat = artikel.artnr.
                    IF TRIM(artikel.omschr-n) NE "":u THEN
                        ttReq.omschr = TRIM(artikel.omschr-n).
                    IF ttReq.eenheid EQ ? THEN
                        ttReq.eenheid = UnitFor(artikel.artnr, FALSE).
                END.
            END.

        END.

        lMeerdereRij = (iRij GT 1).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: One indexed bonlijn scan per requested entry.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ScanArtikelen():

        DEFINE VARIABLE cPat AS CHARACTER NO-UNDO.

        /* USE-INDEX bonlijn-x2 is mandatory (see OmzetanalyseDealersBE:ScanPatterns):
           with the structural-flag predicates the optimizer otherwise picks
           bonlijn-x14 and scans every real line. */
        FOR EACH ttReq BY ttReq.rijId:

            cPat = ttReq.pat.

            IF ttReq.isBegins THEN
            DO:
                FOR EACH bonlijn NO-LOCK USE-INDEX bonlijn-x2
                    WHERE bonlijn.artnr     BEGINS cPat
                      AND bonlijn.subtotaal  EQ FALSE
                      AND bonlijn.kolomtitel EQ FALSE
                      AND bonlijn.infolijn   EQ FALSE:
                    ProcessLine(BUFFER bonlijn, ttReq.rijId).
                END.
            END.
            ELSE
            DO:
                FOR EACH bonlijn NO-LOCK USE-INDEX bonlijn-x2
                    WHERE bonlijn.artnr     EQ cPat
                      AND bonlijn.subtotaal  EQ FALSE
                      AND bonlijn.kolomtitel EQ FALSE
                      AND bonlijn.infolijn   EQ FALSE:
                    ProcessLine(BUFFER bonlijn, ttReq.rijId).
                END.
            END.

        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: No articles requested: every real line in the 24-month window,
                 via the denormalized bon-datum index.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ScanAlles():

        FOR EACH bonlijn NO-LOCK USE-INDEX bonlijn-x17
            WHERE bonlijn.bon-datum GE dVorigVan
              AND bonlijn.bon-datum LE dPeriodeTot
              AND bonlijn.kolomtitel EQ FALSE
              AND bonlijn.infolijn   EQ FALSE
              AND bonlijn.subtotaal  EQ FALSE
              AND bonlijn.artnr      NE "":u:
            ProcessLine(BUFFER bonlijn, 0).
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Cheap pre-filter on the denormalized bonlijn.klnr / bon-datum
                 (as OmzetanalyseDealersBE:PreFilterOut) - only skips lines that
                 are certainly out of scope; bon stays the authority.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL PreFilterOut( BUFFER pbLijn FOR bonlijn ):

        IF pbLijn.klnr NE 0 AND pbLijn.klnr NE ?
           AND NOT CAN-FIND(ttKlant WHERE ttKlant.klnr EQ pbLijn.klnr) THEN
            RETURN TRUE.

        IF pbLijn.bon-datum NE ?
           AND (pbLijn.bon-datum LT dVorigVan OR pbLijn.bon-datum GT dPeriodeTot) THEN
            RETURN TRUE.

        RETURN FALSE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Resolves the cached bon (creating the cache row); TRUE when the
                 bon is in scope (dealer + date), with ttBon positioned on it.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL LoadBon( INPUT piBonnr AS INTEGER ):

        FIND ttBon WHERE ttBon.bonNr EQ piBonnr NO-ERROR.
        IF AVAILABLE ttBon THEN
            RETURN (ttBon.bIdx GT 0).

        CREATE ttBon.
        ASSIGN
            ttBon.bonNr = piBonnr
            ttBon.bIdx  = 0.

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN RETURN FALSE.
        IF NOT CAN-FIND(ttKlant WHERE ttKlant.klnr EQ bon.klnr) THEN RETURN FALSE.

        ASSIGN
            ttBon.bIdx     = MonthIdx(bon.datum)
            ttBon.bStempel = bon.stempel
            ttBon.bKorting = bon.korting.

        RETURN (ttBon.bIdx GT 0).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: TRUE when the line counts towards revenue (rule 5): artnr or
                 artikel.x-ref BEGINS "NOMALED.".
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL IsNomaledArtnr( INPUT pcArtnr AS CHARACTER ):

        IF pcArtnr BEGINS cNomaledPrefix THEN RETURN TRUE.

        FIND ttArt WHERE ttArt.artNr EQ pcArtnr NO-ERROR.
        IF NOT AVAILABLE ttArt THEN
        DO:
            CREATE ttArt.
            ASSIGN
                ttArt.artNr     = pcArtnr
                ttArt.isNomaled = FALSE.
            FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.
            IF AVAILABLE artikel THEN
                ttArt.isNomaled = (artikel.x-ref BEGINS cNomaledPrefix).
        END.

        RETURN ttArt.isNomaled.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Effective discount % (rule 5): own korting, else (in a group) the
                 subtotaal line's korting for the same bonnr+groepnr, else bon.korting.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DECIMAL LineKorting( BUFFER pbLijn FOR bonlijn, INPUT pdBonKorting AS DECIMAL ):

        DEFINE BUFFER bSub FOR bonlijn.

        IF pbLijn.korting NE 0 THEN
            RETURN pbLijn.korting.

        IF pbLijn.groepnr NE 0 THEN
        DO:
            FIND ttGrp WHERE ttGrp.bonNr EQ pbLijn.bonnr AND ttGrp.groepNr EQ pbLijn.groepnr NO-ERROR.
            IF NOT AVAILABLE ttGrp THEN
            DO:
                CREATE ttGrp.
                ASSIGN
                    ttGrp.bonNr    = pbLijn.bonnr
                    ttGrp.groepNr  = pbLijn.groepnr
                    ttGrp.isFound  = FALSE
                    ttGrp.gKorting = 0.
                FIND FIRST bSub NO-LOCK
                    WHERE bSub.bonnr EQ pbLijn.bonnr
                      AND bSub.groepnr EQ pbLijn.groepnr
                      AND bSub.subtotaal EQ TRUE NO-ERROR.
                IF AVAILABLE bSub THEN
                    ASSIGN
                        ttGrp.isFound  = TRUE
                        ttGrp.gKorting = bSub.korting.
            END.
            IF ttGrp.isFound THEN
                RETURN ttGrp.gKorting.
        END.

        RETURN pdBonKorting.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Books one bonlijn into its row (piRijId, 0 = totaal only) and,
                 once per line, into the totaal.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ProcessLine( BUFFER pbLijn FOR bonlijn, INPUT piRijId AS INTEGER ):

        DEFINE VARIABLE iIdx   AS INTEGER   NO-UNDO.
        DEFINE VARIABLE dKort  AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dOmzet AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE cRowid AS CHARACTER NO-UNDO.

        IF PreFilterOut(BUFFER pbLijn) THEN RETURN.
        IF NOT LoadBon(pbLijn.bonnr) THEN RETURN.

        iIdx = ttBon.bIdx.

        IF ttBon.bStempel NE "O":u AND IsNomaledArtnr(pbLijn.artnr) THEN
        DO:
            dKort  = LineKorting(BUFFER pbLijn, ttBon.bKorting).
            dOmzet = pbLijn.aantal * (pbLijn.vprijs * (1 - dKort / 100)).
        END.

        IF piRijId GT 0 THEN
            Bump(piRijId, iIdx, pbLijn.aantal, dOmzet).

        /* Rule 6: with a single row (or none) every line is new by construction. */
        IF lMeerdereRij THEN
        DO:
            cRowid = STRING(ROWID(pbLijn)).
            IF CAN-FIND(ttLijnSeen WHERE ttLijnSeen.cRowid EQ cRowid) THEN RETURN.
            CREATE ttLijnSeen.
            ttLijnSeen.cRowid = cRowid.
        END.

        Bump(0, iIdx, pbLijn.aantal, dOmzet).

    END METHOD.

    METHOD PRIVATE VOID Bump( INPUT piRijId AS INTEGER, INPUT piIdx AS INTEGER,
                              INPUT pdAantal AS DECIMAL, INPUT pdOmzet AS DECIMAL ):

        FIND ttAgg WHERE ttAgg.rijId EQ piRijId AND ttAgg.idx EQ piIdx NO-ERROR.
        IF NOT AVAILABLE ttAgg THEN
        DO:
            CREATE ttAgg.
            ASSIGN
                ttAgg.rijId = piRijId
                ttAgg.idx   = piIdx.
        END.

        ASSIGN
            ttAgg.aAantal = ttAgg.aAantal + (IF pdAantal EQ ? THEN 0 ELSE pdAantal)
            ttAgg.aOmzet  = ttAgg.aOmzet  + (IF pdOmzet  EQ ? THEN 0 ELSE pdOmzet).

    END METHOD.

    METHOD PRIVATE DECIMAL AggAantal( INPUT piRijId AS INTEGER, INPUT piIdx AS INTEGER ):
        FIND ttAgg WHERE ttAgg.rijId EQ piRijId AND ttAgg.idx EQ piIdx NO-ERROR.
        RETURN (IF AVAILABLE ttAgg THEN ttAgg.aAantal ELSE 0).
    END METHOD.

    METHOD PRIVATE DECIMAL AggOmzet( INPUT piRijId AS INTEGER, INPUT piIdx AS INTEGER ):
        FIND ttAgg WHERE ttAgg.rijId EQ piRijId AND ttAgg.idx EQ piIdx NO-ERROR.
        RETURN (IF AVAILABLE ttAgg THEN ttAgg.aOmzet ELSE 0).
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Output rows: always 12 months per row and in the totaal, oldest
                 first; months without sales are 0, never null.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BuildOutput():

        DEFINE VARIABLE i AS INTEGER NO-UNDO.

        FOR EACH ttReq BY ttReq.rijId:

            CREATE ttRij.
            ASSIGN
                ttRij.analyseId    = 1
                ttRij.rijId        = ttReq.rijId
                ttRij.artnr        = ttReq.artnr
                ttRij.omschrijving = ttReq.omschr
                ttRij.swBegins     = ttReq.isBegins
                ttRij.eenheid      = ttReq.eenheid.

            DO i = 1 TO 12:
                CREATE ttRijMaand.
                ASSIGN
                    ttRijMaand.rijId           = ttReq.rijId
                    ttRijMaand.idx             = i
                    ttRijMaand.maand           = MaandLabel(12 + i)
                    ttRijMaand.aantal          = AggAantal(ttReq.rijId, 12 + i)
                    ttRijMaand.omzet           = AggOmzet(ttReq.rijId, 12 + i)
                    ttRijMaand.aantalVorigJaar = AggAantal(ttReq.rijId, i)
                    ttRijMaand.omzetVorigJaar  = AggOmzet(ttReq.rijId, i).
            END.

        END.

        DO i = 1 TO 12:
            CREATE ttTotaal.
            ASSIGN
                ttTotaal.analyseId       = 1
                ttTotaal.idx             = i
                ttTotaal.maand           = MaandLabel(12 + i)
                ttTotaal.aantal          = AggAantal(0, 12 + i)
                ttTotaal.omzet           = AggOmzet(0, 12 + i)
                ttTotaal.aantalVorigJaar = AggAantal(0, i)
                ttTotaal.omzetVorigJaar  = AggOmzet(0, i).
        END.

    END METHOD.

END CLASS.
