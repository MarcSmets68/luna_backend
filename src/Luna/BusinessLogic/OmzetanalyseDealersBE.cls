/*------------------------------------------------------------------------
    File        : OmzetanalyseDealersBE.cls
    Purpose     : Business Entity for the "Omzetanalyse dealers" report (port of
                  the legacy "Analyselijst dealers"). Read-only: NO-LOCK reads
                  throughout, no writes anywhere.
    Syntax      : Called from Luna.Web.RapportageHandler
                  GET /rapportage/omzetanalyse-dealers
                  GET /rapportage/omzetanalyse-dealers/soorten
    Description : Owns all DB access + business rules for this report. See
                  docs/backend/omzetanalyse-dealers.md for the contract.
                  Rules implemented (Marc-confirmed, legacy-exact):
                  1. Rows come from led_lijstparameters (primary index order).
                     artnr "" = category title, "m"/"st" = unit marker for the
                     following rows in the category (never matched), swBegins =
                     BEGINS match else exact match.
                  2. Nomacurve: artnr NOMALED.NTX.00.BRUT-T4 is matched as
                     BEGINS "NOMALED.NC.C" OR BEGINS "NOMALED.NC.O".
                  3. Quantity: qtyLos = SUM(aantal) where swLed = FALSE,
                     qtyProductie = swLed = TRUE. subtotaal/kolomtitel/infolijn
                     lines never match.
                  4. Revenue: Los = groepnr = 0, Productie = groepnr <> 0; only
                     bon.stempel <> "O" and artnr/artikel.x-ref BEGINS
                     "NOMALED.". Discount: line korting <> 0, else (groepnr <> 0)
                     korting of the subtotaal line with same bonnr+groepnr, else
                     bon.korting. Computed fresh, stored bedrag never used.
                  5. aantalOrders = distinct bonnr per scope (row/category/section).
                  6. Meters: lines with groepnr = 0; ledstripNomatrack =
                     artikel.led-type "Ledstrip/Nomatrack", coverLicht =
                     "Cover" with art_cover.licht; aantal only.
                  7. Soort filter = klant.soort (not bon.soort).
                  8. Growth vs next (older) column, JAREN mode only.
                  Performance: one indexed bonlijn scan per DISTINCT match
                  pattern (bonlijn-x2), each line bucketed in-loop via a cached
                  bon lookup (bon.datum has no index).
    Author(s)   : Devin
    Created     : 2026-09-20
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.OmzetanalyseDealersBE:

    /* ===================== Public / serialized result ===================== */

    DEFINE TEMP-TABLE ttSoort NO-UNDO SERIALIZE-NAME "items":u
        FIELD kode   AS CHARACTER SERIALIZE-NAME "kode":u
        FIELD omschr AS CHARACTER SERIALIZE-NAME "omschr":u
        INDEX idxKode IS PRIMARY kode.

    DEFINE TEMP-TABLE ttAnalyse NO-UNDO SERIALIZE-NAME "analyse":u
        FIELD analyseId AS INTEGER SERIALIZE-HIDDEN
        FIELD modus     AS CHARACTER SERIALIZE-NAME "modus":u
        INDEX idxPk IS PRIMARY analyseId.

    DEFINE TEMP-TABLE ttFilter NO-UNDO SERIALIZE-NAME "filters":u
        FIELD analyseId   AS INTEGER SERIALIZE-HIDDEN
        FIELD datumVan    AS DATE      SERIALIZE-NAME "datumVan":u
        FIELD datumTot    AS DATE      SERIALIZE-NAME "datumTot":u
        FIELD klnr        AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD klantNaam   AS CHARACTER SERIALIZE-NAME "klantNaam":u
        FIELD soort       AS CHARACTER SERIALIZE-NAME "soort":u
        FIELD soortOmschr AS CHARACTER SERIALIZE-NAME "soortOmschr":u
        FIELD perDealer   AS LOGICAL   SERIALIZE-NAME "perDealer":u
        FIELD leegRijen   AS LOGICAL   SERIALIZE-NAME "leegRijen":u
        INDEX idxPk IS PRIMARY analyseId.

    DEFINE TEMP-TABLE ttKolom NO-UNDO SERIALIZE-NAME "kolommen":u
        FIELD analyseId AS INTEGER SERIALIZE-HIDDEN
        FIELD idx       AS INTEGER SERIALIZE-HIDDEN
        FIELD kolKey    AS CHARACTER SERIALIZE-NAME "key":u
        FIELD kolLabel  AS CHARACTER SERIALIZE-NAME "label":u
        INDEX idxPk IS PRIMARY analyseId idx.

    DEFINE TEMP-TABLE ttSectie NO-UNDO SERIALIZE-NAME "secties":u
        FIELD analyseId  AS INTEGER SERIALIZE-HIDDEN
        FIELD sectieId   AS INTEGER SERIALIZE-HIDDEN
        FIELD dealerKlnr AS INTEGER   SERIALIZE-NAME "dealerKlnr":u
        FIELD dealerNaam AS CHARACTER SERIALIZE-NAME "dealerNaam":u
        INDEX idxPk IS PRIMARY analyseId sectieId.

    DEFINE TEMP-TABLE ttCategorie NO-UNDO SERIALIZE-NAME "categorieen":u
        FIELD sectieId         AS INTEGER SERIALIZE-HIDDEN
        FIELD catId            AS INTEGER SERIALIZE-HIDDEN
        FIELD categorie        AS CHARACTER SERIALIZE-NAME "categorie":u
        FIELD gemengdeEenheden AS LOGICAL   SERIALIZE-NAME "gemengdeEenheden":u
        INDEX idxPk IS PRIMARY sectieId catId.

    DEFINE TEMP-TABLE ttRij NO-UNDO SERIALIZE-NAME "rijen":u
        FIELD catId    AS INTEGER SERIALIZE-HIDDEN
        FIELD rijId    AS INTEGER SERIALIZE-HIDDEN
        FIELD artnr    AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD swBegins AS LOGICAL   SERIALIZE-NAME "swBegins":u
        FIELD eenheid  AS CHARACTER SERIALIZE-NAME "eenheid":u
        INDEX idxPk IS PRIMARY catId rijId.

    DEFINE TEMP-TABLE ttRijPeriode NO-UNDO SERIALIZE-NAME "perioden":u
        FIELD rijId               AS INTEGER SERIALIZE-HIDDEN
        FIELD idx                 AS INTEGER SERIALIZE-HIDDEN
        FIELD qtyLos              AS DECIMAL
        FIELD qtyProductie        AS DECIMAL
        FIELD aantalOrders        AS INTEGER
        FIELD omzetLos            AS DECIMAL
        FIELD omzetProductie      AS DECIMAL
        FIELD omzetTotaal         AS DECIMAL
        FIELD groeiQtyLos         AS DECIMAL
        FIELD groeiQtyProductie   AS DECIMAL
        FIELD groeiAantalOrders   AS DECIMAL
        FIELD groeiOmzetLos       AS DECIMAL
        FIELD groeiOmzetProductie AS DECIMAL
        FIELD groeiOmzetTotaal    AS DECIMAL
        INDEX idxPk IS PRIMARY rijId idx.

    DEFINE TEMP-TABLE ttCatPeriode NO-UNDO SERIALIZE-NAME "totalen":u
        FIELD catId               AS INTEGER SERIALIZE-HIDDEN
        FIELD idx                 AS INTEGER SERIALIZE-HIDDEN
        FIELD qtyLos              AS DECIMAL
        FIELD qtyProductie        AS DECIMAL
        FIELD aantalOrders        AS INTEGER
        FIELD omzetLos            AS DECIMAL
        FIELD omzetProductie      AS DECIMAL
        FIELD omzetTotaal         AS DECIMAL
        FIELD groeiQtyLos         AS DECIMAL
        FIELD groeiQtyProductie   AS DECIMAL
        FIELD groeiAantalOrders   AS DECIMAL
        FIELD groeiOmzetLos       AS DECIMAL
        FIELD groeiOmzetProductie AS DECIMAL
        FIELD groeiOmzetTotaal    AS DECIMAL
        INDEX idxPk IS PRIMARY catId idx.

    DEFINE TEMP-TABLE ttSectiePeriode NO-UNDO SERIALIZE-NAME "omzet":u
        FIELD sectieId            AS INTEGER SERIALIZE-HIDDEN
        FIELD idx                 AS INTEGER SERIALIZE-HIDDEN
        FIELD qtyLos              AS DECIMAL
        FIELD qtyProductie        AS DECIMAL
        FIELD aantalOrders        AS INTEGER
        FIELD omzetLos            AS DECIMAL
        FIELD omzetProductie      AS DECIMAL
        FIELD omzetTotaal         AS DECIMAL
        FIELD groeiQtyLos         AS DECIMAL
        FIELD groeiQtyProductie   AS DECIMAL
        FIELD groeiAantalOrders   AS DECIMAL
        FIELD groeiOmzetLos       AS DECIMAL
        FIELD groeiOmzetProductie AS DECIMAL
        FIELD groeiOmzetTotaal    AS DECIMAL
        INDEX idxPk IS PRIMARY sectieId idx.

    /* Flat per-column meter rows; the WebHandler reshapes into
       {"ledstripNomatrack":[..],"coverLicht":[..]}. */
    DEFINE TEMP-TABLE ttMeter NO-UNDO SERIALIZE-NAME "meters":u
        FIELD sectieId          AS INTEGER SERIALIZE-HIDDEN
        FIELD idx               AS INTEGER SERIALIZE-HIDDEN
        FIELD ledstripNomatrack AS DECIMAL
        FIELD coverLicht        AS DECIMAL
        INDEX idxPk IS PRIMARY sectieId idx.

    DEFINE DATASET dsOmzetanalyse SERIALIZE-NAME "dsOmzetanalyse":u
        FOR ttAnalyse, ttFilter, ttKolom, ttSectie, ttCategorie, ttRij,
            ttRijPeriode, ttCatPeriode, ttSectiePeriode, ttMeter
        DATA-RELATION rFilter  FOR ttAnalyse,  ttFilter        RELATION-FIELDS (analyseId, analyseId) NESTED
        DATA-RELATION rKolom   FOR ttAnalyse,  ttKolom         RELATION-FIELDS (analyseId, analyseId) NESTED
        DATA-RELATION rSectie  FOR ttAnalyse,  ttSectie        RELATION-FIELDS (analyseId, analyseId) NESTED
        DATA-RELATION rCat     FOR ttSectie,   ttCategorie     RELATION-FIELDS (sectieId, sectieId) NESTED
        DATA-RELATION rRij     FOR ttCategorie, ttRij          RELATION-FIELDS (catId, catId) NESTED
        DATA-RELATION rRijP    FOR ttRij,      ttRijPeriode    RELATION-FIELDS (rijId, rijId) NESTED
        DATA-RELATION rCatP    FOR ttCategorie, ttCatPeriode   RELATION-FIELDS (catId, catId) NESTED
        DATA-RELATION rSectieP FOR ttSectie,   ttSectiePeriode RELATION-FIELDS (sectieId, sectieId) NESTED
        DATA-RELATION rMeter   FOR ttSectie,   ttMeter         RELATION-FIELDS (sectieId, sectieId) NESTED.

    /* ===================== Private working tables (never serialized) ===================== */

    /* One category per distinct led_lijstparameters.categorie, in index order. */
    DEFINE PRIVATE TEMP-TABLE ttCat NO-UNDO
        FIELD catNr     AS INTEGER
        FIELD catNaam   AS CHARACTER
        INDEX idxPk IS PRIMARY UNIQUE catNr.

    /* One per article row (title/marker rows are not stored). */
    DEFINE PRIVATE TEMP-TABLE ttSpec NO-UNDO
        FIELD specId    AS INTEGER
        FIELD catNr     AS INTEGER
        FIELD artnr     AS CHARACTER
        FIELD swBegins  AS LOGICAL
        FIELD eenheid   AS CHARACTER
        INDEX idxPk IS PRIMARY UNIQUE specId
        INDEX idxCat catNr specId.

    /* Distinct bonlijn.artnr match patterns -> one scan each. */
    DEFINE PRIVATE TEMP-TABLE ttPat NO-UNDO
        FIELD patId     AS INTEGER
        FIELD pat       AS CHARACTER
        FIELD isBegins  AS LOGICAL
        INDEX idxPk IS PRIMARY UNIQUE patId
        INDEX idxPat pat isBegins.

    DEFINE PRIVATE TEMP-TABLE ttRule NO-UNDO
        FIELD patId     AS INTEGER
        FIELD specId    AS INTEGER
        INDEX idxPk IS PRIMARY patId specId.

    /* bon cache. bKol = 0 -> out of scope (date/klnr/soort filter or no bon). */
    DEFINE PRIVATE TEMP-TABLE ttBon NO-UNDO
        FIELD bonNr     AS INTEGER
        FIELD bKol      AS INTEGER
        FIELD bKlnr     AS INTEGER
        FIELD bStempel  AS CHARACTER
        FIELD bKorting  AS DECIMAL
        INDEX idxPk IS PRIMARY UNIQUE bonNr.

    DEFINE PRIVATE TEMP-TABLE ttArt NO-UNDO
        FIELD artNr     AS CHARACTER
        FIELD isNomaled AS LOGICAL
        INDEX idxPk IS PRIMARY UNIQUE artNr.

    /* korting of the subtotaal line per (bonnr, groepnr). */
    DEFINE PRIVATE TEMP-TABLE ttGrp NO-UNDO
        FIELD bonNr     AS INTEGER
        FIELD groepNr   AS INTEGER
        FIELD isFound   AS LOGICAL
        FIELD gKorting  AS DECIMAL
        INDEX idxPk IS PRIMARY UNIQUE bonNr groepNr.

    /* Aggregates. lvl: 1 = row(specId), 2 = category(catNr), 3 = section. sk = section key
       (klnr in per-dealer mode, else 0). kol = column 1..n. */
    DEFINE PRIVATE TEMP-TABLE ttAgg NO-UNDO
        FIELD sk        AS INTEGER
        FIELD lvl       AS INTEGER
        FIELD scp       AS INTEGER
        FIELD kol       AS INTEGER
        FIELD aQtyLos   AS DECIMAL
        FIELD aQtyProd  AS DECIMAL
        FIELD aOrders   AS INTEGER
        FIELD aOmzLos   AS DECIMAL
        FIELD aOmzProd  AS DECIMAL
        INDEX idxPk IS PRIMARY UNIQUE sk lvl scp kol.

    /* distinct-order tracking (bonnr determines the column, so not part of the key). */
    DEFINE PRIVATE TEMP-TABLE ttSeen NO-UNDO
        FIELD sk        AS INTEGER
        FIELD lvl       AS INTEGER
        FIELD scp       AS INTEGER
        FIELD bonNr     AS INTEGER
        INDEX idxPk IS PRIMARY UNIQUE sk lvl scp bonNr.

    DEFINE PRIVATE TEMP-TABLE ttMeterAgg NO-UNDO
        FIELD sk        AS INTEGER
        FIELD kol       AS INTEGER
        FIELD mLsn      AS DECIMAL
        FIELD mCover    AS DECIMAL
        INDEX idxPk IS PRIMARY UNIQUE sk kol.

    DEFINE PRIVATE TEMP-TABLE ttSectKey NO-UNDO
        FIELD sk        AS INTEGER
        FIELD skNaam    AS CHARACTER
        INDEX idxPk IS PRIMARY UNIQUE sk
        INDEX idxNaam skNaam sk.

    /* Scratch: computed metrics (incl. growth) for one scope, one row per column. */
    DEFINE PRIVATE TEMP-TABLE ttM NO-UNDO
        FIELD idx                 AS INTEGER
        FIELD qtyLos              AS DECIMAL
        FIELD qtyProductie        AS DECIMAL
        FIELD aantalOrders        AS INTEGER
        FIELD omzetLos            AS DECIMAL
        FIELD omzetProductie      AS DECIMAL
        FIELD omzetTotaal         AS DECIMAL
        FIELD groeiQtyLos         AS DECIMAL
        FIELD groeiQtyProductie   AS DECIMAL
        FIELD groeiAantalOrders   AS DECIMAL
        FIELD groeiOmzetLos       AS DECIMAL
        FIELD groeiOmzetProductie AS DECIMAL
        FIELD groeiOmzetTotaal    AS DECIMAL
        INDEX idxPk IS PRIMARY UNIQUE idx.

    /* ===================== Request state ===================== */
    DEFINE PRIVATE VARIABLE lJaren       AS LOGICAL   NO-UNDO.
    DEFINE PRIVATE VARIABLE iNCols       AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE iYearNow     AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE dFiltVan     AS DATE      NO-UNDO.
    DEFINE PRIVATE VARIABLE dFiltTot     AS DATE      NO-UNDO.
    DEFINE PRIVATE VARIABLE iKlnrF       AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE cSoortF      AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE lDealerMode  AS LOGICAL   NO-UNDO.
    DEFINE PRIVATE VARIABLE lLeegRijen   AS LOGICAL   NO-UNDO.
    DEFINE PRIVATE VARIABLE iSeqSectie   AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE iSeqCat      AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE iSeqRij      AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE iSeqPat      AS INTEGER   NO-UNDO.

    DEFINE PRIVATE VARIABLE cNomacurveArtnr AS CHARACTER NO-UNDO INITIAL "NOMALED.NTX.00.BRUT-T4":u.
    DEFINE PRIVATE VARIABLE cNomaledPrefix  AS CHARACTER NO-UNDO INITIAL "NOMALED.":u.

    /*------------------------------------------------------------------------------
        Purpose: All rows of the soort table, sorted by kode (feeds the Soort dropdown).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetSoorten():

        EMPTY TEMP-TABLE ttSoort.

        FOR EACH soort NO-LOCK BY soort.kode:
            CREATE ttSoort.
            ASSIGN
                ttSoort.kode   = soort.kode
                ttSoort.omschr = soort.omschr.
        END.

        RETURN TEMP-TABLE ttSoort:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Builds the Omzetanalyse dealers report. ? = "not given" for the
                 optional params.
        Throws : AppError 400 on business-rule violations (van > tot, unknown soort).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetAnalyse( INPUT pdVan       AS DATE,
                                     INPUT pdTot       AS DATE,
                                     INPUT piKlnr      AS INTEGER,
                                     INPUT pcSoort     AS CHARACTER,
                                     INPUT plPerDealer AS LOGICAL,
                                     INPUT plLeegRijen AS LOGICAL ):

        DEFINE VARIABLE cSoortOmschr AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cKlantNaam   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iYr          AS INTEGER   NO-UNDO.

        IF pdVan NE ? AND pdTot NE ? AND pdVan GT pdTot THEN
            UNDO, THROW NEW Progress.Lang.AppError("datumVan mag niet na datumTot liggen":u, 400).

        cSoortF = ?.
        IF pcSoort NE ? AND pcSoort NE "":u THEN
        DO:
            FIND FIRST soort NO-LOCK WHERE soort.kode EQ pcSoort NO-ERROR.
            IF NOT AVAILABLE soort THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Onbekende soort '&1'":u, pcSoort), 400).
            ASSIGN
                cSoortF      = soort.kode
                cSoortOmschr = soort.omschr.
        END.

        ASSIGN
            dFiltVan    = pdVan
            dFiltTot    = pdTot
            iKlnrF      = piKlnr
            lLeegRijen  = (plLeegRijen NE FALSE)
            lDealerMode = (plPerDealer EQ TRUE AND cSoortF NE ?)
            lJaren      = (pdVan EQ ? AND pdTot EQ ?)
            iYearNow    = YEAR(TODAY)
            iNCols      = (IF lJaren THEN 5 ELSE 1)
            iSeqSectie  = 0
            iSeqCat     = 0
            iSeqRij     = 0
            iSeqPat     = 0.

        EMPTY TEMP-TABLE ttAnalyse.
        EMPTY TEMP-TABLE ttFilter.
        EMPTY TEMP-TABLE ttKolom.
        EMPTY TEMP-TABLE ttSectie.
        EMPTY TEMP-TABLE ttCategorie.
        EMPTY TEMP-TABLE ttRij.
        EMPTY TEMP-TABLE ttRijPeriode.
        EMPTY TEMP-TABLE ttCatPeriode.
        EMPTY TEMP-TABLE ttSectiePeriode.
        EMPTY TEMP-TABLE ttMeter.
        EMPTY TEMP-TABLE ttCat.
        EMPTY TEMP-TABLE ttSpec.
        EMPTY TEMP-TABLE ttPat.
        EMPTY TEMP-TABLE ttRule.
        EMPTY TEMP-TABLE ttBon.
        EMPTY TEMP-TABLE ttArt.
        EMPTY TEMP-TABLE ttGrp.
        EMPTY TEMP-TABLE ttAgg.
        EMPTY TEMP-TABLE ttSeen.
        EMPTY TEMP-TABLE ttMeterAgg.
        EMPTY TEMP-TABLE ttSectKey.

        /* Header: modus, filters echo, columns. */
        CREATE ttAnalyse.
        ASSIGN
            ttAnalyse.analyseId = 1
            ttAnalyse.modus     = (IF lJaren THEN "JAREN":u ELSE "PERIODE":u).

        IF iKlnrF NE ? THEN
        DO:
            FIND FIRST klant NO-LOCK WHERE klant.klnr EQ iKlnrF NO-ERROR.
            IF AVAILABLE klant THEN cKlantNaam = klant.naam.
        END.

        CREATE ttFilter.
        ASSIGN
            ttFilter.analyseId   = 1
            ttFilter.datumVan    = pdVan
            ttFilter.datumTot    = pdTot
            ttFilter.klnr        = iKlnrF
            ttFilter.klantNaam   = cKlantNaam
            ttFilter.soort       = cSoortF
            ttFilter.soortOmschr = (IF cSoortF NE ? THEN cSoortOmschr ELSE ?)
            ttFilter.perDealer   = lDealerMode
            ttFilter.leegRijen   = lLeegRijen.

        IF lJaren THEN
        DO iYr = 0 TO 4:
            CREATE ttKolom.
            ASSIGN
                ttKolom.analyseId = 1
                ttKolom.idx       = iYr + 1
                ttKolom.kolKey    = STRING(iYearNow - iYr)
                ttKolom.kolLabel  = STRING(iYearNow - iYr).
        END.
        ELSE
        DO:
            CREATE ttKolom.
            ASSIGN
                ttKolom.analyseId = 1
                ttKolom.idx       = 1
                ttKolom.kolKey    = "periode":u
                ttKolom.kolLabel  = PeriodeLabel().
        END.

        LoadSpecs().
        ScanPatterns().
        ScanMeters().
        BuildOutput().

        RETURN DATASET dsOmzetanalyse:HANDLE.

    END METHOD.

    METHOD PRIVATE CHARACTER PeriodeLabel():

        IF dFiltVan NE ? AND dFiltTot NE ? THEN
            RETURN SUBSTITUTE("&1 - &2":u, FmtDate(dFiltVan), FmtDate(dFiltTot)).
        IF dFiltVan NE ? THEN
            RETURN SUBSTITUTE("vanaf &1":u, FmtDate(dFiltVan)).
        RETURN SUBSTITUTE("tot &1":u, FmtDate(dFiltTot)).

    END METHOD.

    METHOD PRIVATE CHARACTER FmtDate( INPUT pdDate AS DATE ):
        RETURN STRING(YEAR(pdDate), "9999":u) + "-":u
             + STRING(MONTH(pdDate), "99":u) + "-":u
             + STRING(DAY(pdDate), "99":u).
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Loads led_lijstparameters (primary index order) into categories,
                 article specs (with resolved eenheid) and match patterns.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID LoadSpecs():

        DEFINE VARIABLE cCurCat  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lFirst   AS LOGICAL   NO-UNDO INITIAL TRUE.
        DEFINE VARIABLE cUnit    AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cArtnr   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iCatNr   AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iSpecId  AS INTEGER   NO-UNDO.

        FOR EACH led_lijstparameters NO-LOCK:

            IF lFirst OR led_lijstparameters.categorie NE cCurCat THEN
            DO:
                ASSIGN
                    lFirst  = FALSE
                    cCurCat = led_lijstparameters.categorie
                    iCatNr  = iCatNr + 1
                    cUnit   = ?.
                CREATE ttCat.
                ASSIGN
                    ttCat.catNr   = iCatNr
                    ttCat.catNaam = led_lijstparameters.categorie.
            END.

            cArtnr = TRIM(led_lijstparameters.artnr).

            /* Title row: the category name itself is carried by ttCat. */
            IF cArtnr EQ "":u THEN NEXT.

            /* Unit markers apply to the following rows in the category. */
            IF cArtnr EQ "m":u OR cArtnr EQ "st":u THEN
            DO:
                cUnit = LOWER(cArtnr).
                NEXT.
            END.

            iSpecId = iSpecId + 1.
            CREATE ttSpec.
            ASSIGN
                ttSpec.specId   = iSpecId
                ttSpec.catNr    = iCatNr
                ttSpec.artnr    = cArtnr
                ttSpec.swBegins = led_lijstparameters.swBegins
                ttSpec.eenheid  = cUnit.

            /* Nomacurve: hardcoded legacy special case. */
            IF cArtnr EQ cNomacurveArtnr THEN
            DO:
                AddRule(iSpecId, "NOMALED.NC.C":u, TRUE).
                AddRule(iSpecId, "NOMALED.NC.O":u, TRUE).
            END.
            ELSE
                AddRule(iSpecId, cArtnr, led_lijstparameters.swBegins).

        END.

    END METHOD.

    METHOD PRIVATE VOID AddRule( INPUT piSpecId AS INTEGER, INPUT pcPat AS CHARACTER, INPUT plBegins AS LOGICAL ):

        FIND FIRST ttPat WHERE ttPat.pat EQ pcPat AND ttPat.isBegins EQ plBegins NO-ERROR.
        IF NOT AVAILABLE ttPat THEN
        DO:
            iSeqPat = iSeqPat + 1.
            CREATE ttPat.
            ASSIGN
                ttPat.patId    = iSeqPat
                ttPat.pat      = pcPat
                ttPat.isBegins = plBegins.
        END.

        CREATE ttRule.
        ASSIGN
            ttRule.patId  = ttPat.patId
            ttRule.specId = piSpecId.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: One indexed bonlijn scan per distinct match pattern.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ScanPatterns():

        DEFINE VARIABLE cPat AS CHARACTER NO-UNDO.

        /* USE-INDEX bonlijn-x2 is mandatory: with the structural-flag predicates in the
           WHERE the optimizer otherwise picks bonlijn-x14 (kolomtitel, infolijn,
           subtotaal, ...) and scans ALL real lines per pattern (~1.4s x 200 patterns). */
        FOR EACH ttPat:

            cPat = ttPat.pat.

            IF ttPat.isBegins THEN
            DO:
                FOR EACH bonlijn NO-LOCK USE-INDEX bonlijn-x2
                    WHERE bonlijn.artnr     BEGINS cPat
                      AND bonlijn.subtotaal  EQ FALSE
                      AND bonlijn.kolomtitel EQ FALSE
                      AND bonlijn.infolijn   EQ FALSE:
                    ProcessLine(BUFFER bonlijn, ttPat.patId).
                END.
            END.
            ELSE
            DO:
                FOR EACH bonlijn NO-LOCK USE-INDEX bonlijn-x2
                    WHERE bonlijn.artnr     EQ cPat
                      AND bonlijn.subtotaal  EQ FALSE
                      AND bonlijn.kolomtitel EQ FALSE
                      AND bonlijn.infolijn   EQ FALSE:
                    ProcessLine(BUFFER bonlijn, ttPat.patId).
                END.
            END.

        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Resolves the cached bon for piBonnr (creating the cache row) and
                 returns TRUE when it is in scope (ttBon.bKol > 0).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL LoadBon( INPUT piBonnr AS INTEGER ):

        DEFINE VARIABLE iYr AS INTEGER NO-UNDO.

        FIND ttBon WHERE ttBon.bonNr EQ piBonnr NO-ERROR.
        IF AVAILABLE ttBon THEN
            RETURN (ttBon.bKol GT 0).

        CREATE ttBon.
        ASSIGN
            ttBon.bonNr = piBonnr
            ttBon.bKol  = 0.

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN RETURN FALSE.
        IF bon.datum EQ ? THEN RETURN FALSE.

        IF iKlnrF NE ? AND bon.klnr NE iKlnrF THEN RETURN FALSE.

        IF cSoortF NE ? THEN
        DO:
            /* Soort = the customer's CURRENT klant.soort (legacy-exact), not bon.soort. */
            FIND FIRST klant NO-LOCK WHERE klant.klnr EQ bon.klnr NO-ERROR.
            IF NOT AVAILABLE klant OR klant.soort NE cSoortF THEN RETURN FALSE.
        END.

        IF lJaren THEN
        DO:
            iYr = YEAR(bon.datum).
            IF iYr GT iYearNow OR iYr LE iYearNow - 5 THEN RETURN FALSE.
            ttBon.bKol = iYearNow - iYr + 1.
        END.
        ELSE
        DO:
            IF dFiltVan NE ? AND bon.datum LT dFiltVan THEN RETURN FALSE.
            IF dFiltTot NE ? AND bon.datum GT dFiltTot THEN RETURN FALSE.
            ttBon.bKol = 1.
        END.

        ASSIGN
            ttBon.bKlnr    = bon.klnr
            ttBon.bStempel = bon.stempel
            ttBon.bKorting = bon.korting.

        RETURN TRUE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: TRUE when the line counts towards REVENUE: artnr or
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
        Purpose: Effective discount % for a line: own korting, else (in a group) the
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
        Purpose: Buckets one matching bonlijn into every spec that uses the pattern.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ProcessLine( BUFFER pbLijn FOR bonlijn, INPUT piPatId AS INTEGER ):

        DEFINE VARIABLE iSk     AS INTEGER NO-UNDO.
        DEFINE VARIABLE iKol    AS INTEGER NO-UNDO.
        DEFINE VARIABLE dQL     AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dQP     AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dOL     AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dOP     AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dKort   AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dOmzet  AS DECIMAL NO-UNDO.
        DEFINE VARIABLE iBonnr  AS INTEGER NO-UNDO.

        iBonnr = pbLijn.bonnr.
        IF NOT LoadBon(iBonnr) THEN RETURN.

        iKol = ttBon.bKol.
        iSk  = 0.
        IF lDealerMode THEN
        DO:
            iSk = ttBon.bKlnr.
            FIND ttSectKey WHERE ttSectKey.sk EQ iSk NO-ERROR.
            IF NOT AVAILABLE ttSectKey THEN
            DO:
                CREATE ttSectKey.
                ttSectKey.sk = iSk.
                FIND FIRST klant NO-LOCK WHERE klant.klnr EQ iSk NO-ERROR.
                ttSectKey.skNaam = (IF AVAILABLE klant THEN klant.naam ELSE "").
            END.
        END.

        /* Quantity axis: swLed. */
        IF pbLijn.swLed THEN dQP = pbLijn.aantal. ELSE dQL = pbLijn.aantal.

        /* Revenue axis: groepnr; open orders (stempel "O") excluded from revenue only. */
        IF ttBon.bStempel NE "O":u AND IsNomaledArtnr(pbLijn.artnr) THEN
        DO:
            dKort  = LineKorting(BUFFER pbLijn, ttBon.bKorting).
            dOmzet = pbLijn.aantal * (pbLijn.vprijs * (1 - dKort / 100)).
            IF pbLijn.groepnr NE 0 THEN dOP = dOmzet. ELSE dOL = dOmzet.
        END.

        FOR EACH ttRule WHERE ttRule.patId EQ piPatId:
            FIND ttSpec WHERE ttSpec.specId EQ ttRule.specId.
            Bump(iSk, 1, ttSpec.specId, iKol, iBonnr, dQL, dQP, dOL, dOP).
            Bump(iSk, 2, ttSpec.catNr,  iKol, iBonnr, dQL, dQP, dOL, dOP).
            Bump(iSk, 3, 0,             iKol, iBonnr, dQL, dQP, dOL, dOP).
        END.

    END METHOD.

    METHOD PRIVATE VOID Bump( INPUT piSk    AS INTEGER, INPUT piLvl AS INTEGER, INPUT piScp AS INTEGER,
                              INPUT piKol   AS INTEGER, INPUT piBonnr AS INTEGER,
                              INPUT pdQL    AS DECIMAL, INPUT pdQP AS DECIMAL,
                              INPUT pdOL    AS DECIMAL, INPUT pdOP AS DECIMAL ):

        FIND ttAgg WHERE ttAgg.sk EQ piSk AND ttAgg.lvl EQ piLvl AND ttAgg.scp EQ piScp AND ttAgg.kol EQ piKol NO-ERROR.
        IF NOT AVAILABLE ttAgg THEN
        DO:
            CREATE ttAgg.
            ASSIGN
                ttAgg.sk  = piSk
                ttAgg.lvl = piLvl
                ttAgg.scp = piScp
                ttAgg.kol = piKol.
        END.

        ASSIGN
            ttAgg.aQtyLos  = ttAgg.aQtyLos  + pdQL
            ttAgg.aQtyProd = ttAgg.aQtyProd + pdQP
            ttAgg.aOmzLos  = ttAgg.aOmzLos  + pdOL
            ttAgg.aOmzProd = ttAgg.aOmzProd + pdOP.

        FIND ttSeen WHERE ttSeen.sk EQ piSk AND ttSeen.lvl EQ piLvl AND ttSeen.scp EQ piScp AND ttSeen.bonNr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE ttSeen THEN
        DO:
            CREATE ttSeen.
            ASSIGN
                ttSeen.sk     = piSk
                ttSeen.lvl    = piLvl
                ttSeen.scp    = piScp
                ttSeen.bonNr  = piBonnr
                ttAgg.aOrders = ttAgg.aOrders + 1.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Meters block: lines with groepnr = 0 of Ledstrip/Nomatrack articles
                 and of light-transmitting Cover articles (art_cover.licht).
                 Same date/klnr/soort scoping as the main scan. aantal only.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ScanMeters():

        FOR EACH artikel NO-LOCK WHERE artikel.led-type EQ "Ledstrip/Nomatrack":u:
            ScanMeterArtnr(artikel.artnr, FALSE).
        END.

        FOR EACH artikel NO-LOCK WHERE artikel.led-type EQ "Cover":u:
            FIND FIRST art_cover NO-LOCK WHERE art_cover.artnr EQ artikel.artnr NO-ERROR.
            IF AVAILABLE art_cover AND art_cover.licht THEN
                ScanMeterArtnr(artikel.artnr, TRUE).
        END.

    END METHOD.

    METHOD PRIVATE VOID ScanMeterArtnr( INPUT pcArtnr AS CHARACTER, INPUT plCover AS LOGICAL ):

        DEFINE VARIABLE iSk AS INTEGER NO-UNDO.

        FOR EACH bonlijn NO-LOCK USE-INDEX bonlijn-x2
            WHERE bonlijn.artnr     EQ pcArtnr
              AND bonlijn.groepnr    EQ 0
              AND bonlijn.subtotaal  EQ FALSE
              AND bonlijn.kolomtitel EQ FALSE
              AND bonlijn.infolijn   EQ FALSE:

            IF NOT LoadBon(bonlijn.bonnr) THEN NEXT.

            iSk = (IF lDealerMode THEN ttBon.bKlnr ELSE 0).

            FIND ttMeterAgg WHERE ttMeterAgg.sk EQ iSk AND ttMeterAgg.kol EQ ttBon.bKol NO-ERROR.
            IF NOT AVAILABLE ttMeterAgg THEN
            DO:
                CREATE ttMeterAgg.
                ASSIGN
                    ttMeterAgg.sk  = iSk
                    ttMeterAgg.kol = ttBon.bKol.
            END.

            IF plCover THEN
                ttMeterAgg.mCover = ttMeterAgg.mCover + bonlijn.aantal.
            ELSE
                ttMeterAgg.mLsn   = ttMeterAgg.mLsn + bonlijn.aantal.

        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Growth % of pdThis vs pdLast: (this/last*100)-100, 0 if both zero,
                 +100 if last = 0 and this > 0, -100 if this = 0 and last > 0.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DECIMAL Growth( INPUT pdThis AS DECIMAL, INPUT pdLast AS DECIMAL ):

        IF pdThis EQ ? OR pdLast EQ ? THEN RETURN ?.
        IF pdThis EQ 0 AND pdLast EQ 0 THEN RETURN 0.
        IF pdLast EQ 0 THEN RETURN 100.
        IF pdThis EQ 0 THEN RETURN -100.

        RETURN (pdThis / pdLast * 100) - 100.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Fills ttM (one row per column) for one scope incl. growth %.
                 plHideQty / plHideOmzet -> those metrics are unknown (null).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ComputeMetrics( INPUT piSk AS INTEGER, INPUT piLvl AS INTEGER, INPUT piScp AS INTEGER,
                                        INPUT plHideQty AS LOGICAL, INPUT plHideOmzet AS LOGICAL ):

        DEFINE VARIABLE i AS INTEGER NO-UNDO.
        DEFINE BUFFER bNext FOR ttM.

        EMPTY TEMP-TABLE ttM.

        DO i = 1 TO iNCols:
            CREATE ttM.
            ttM.idx = i.
            FIND ttAgg WHERE ttAgg.sk EQ piSk AND ttAgg.lvl EQ piLvl AND ttAgg.scp EQ piScp AND ttAgg.kol EQ i NO-ERROR.

            ASSIGN
                ttM.qtyLos         = (IF plHideQty THEN ? ELSE (IF AVAILABLE ttAgg THEN ttAgg.aQtyLos ELSE 0))
                ttM.qtyProductie   = (IF plHideQty THEN ? ELSE (IF AVAILABLE ttAgg THEN ttAgg.aQtyProd ELSE 0))
                ttM.aantalOrders   = (IF AVAILABLE ttAgg THEN ttAgg.aOrders ELSE 0)
                ttM.omzetLos       = (IF plHideOmzet THEN ? ELSE (IF AVAILABLE ttAgg THEN ttAgg.aOmzLos ELSE 0))
                ttM.omzetProductie = (IF plHideOmzet THEN ? ELSE (IF AVAILABLE ttAgg THEN ttAgg.aOmzProd ELSE 0)).

            ttM.omzetTotaal = (IF plHideOmzet THEN ? ELSE ttM.omzetLos + ttM.omzetProductie).
        END.

        /* Growth only in JAREN mode, vs the next (older) column; the oldest column has none. */
        IF lJaren THEN
        DO:
            FOR EACH ttM WHERE ttM.idx LT iNCols:
                FIND bNext WHERE bNext.idx EQ ttM.idx + 1.
                ASSIGN
                    ttM.groeiQtyLos         = Growth(ttM.qtyLos, bNext.qtyLos)
                    ttM.groeiQtyProductie   = Growth(ttM.qtyProductie, bNext.qtyProductie)
                    ttM.groeiAantalOrders   = Growth(ttM.aantalOrders, bNext.aantalOrders)
                    ttM.groeiOmzetLos       = Growth(ttM.omzetLos, bNext.omzetLos)
                    ttM.groeiOmzetProductie = Growth(ttM.omzetProductie, bNext.omzetProductie)
                    ttM.groeiOmzetTotaal    = Growth(ttM.omzetTotaal, bNext.omzetTotaal).
            END.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Builds the output ProDataSet sections from the aggregates.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BuildOutput():

        IF NOT lDealerMode THEN
            BuildSection(0, ?, ?).
        ELSE
        DO:
            FOR EACH ttSectKey BY ttSectKey.skNaam BY ttSectKey.sk:
                BuildSection(ttSectKey.sk, ttSectKey.sk, ttSectKey.skNaam).
            END.
        END.

    END METHOD.

    METHOD PRIVATE VOID BuildSection( INPUT piSk AS INTEGER, INPUT piKlnr AS INTEGER, INPUT pcNaam AS CHARACTER ):

        DEFINE VARIABLE iSectieId  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iCatId     AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iRows      AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cUnits     AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cUnit      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lMixed     AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE i          AS INTEGER   NO-UNDO.

        iSeqSectie = iSeqSectie + 1.
        iSectieId  = iSeqSectie.

        CREATE ttSectie.
        ASSIGN
            ttSectie.analyseId  = 1
            ttSectie.sectieId   = iSectieId
            ttSectie.dealerKlnr = piKlnr
            ttSectie.dealerNaam = pcNaam.

        FOR EACH ttCat BY ttCat.catNr:

            iSeqCat = iSeqCat + 1.
            iCatId  = iSeqCat.
            iRows   = 0.
            cUnits  = "":u.

            CREATE ttCategorie.
            ASSIGN
                ttCategorie.sectieId  = iSectieId
                ttCategorie.catId     = iCatId
                ttCategorie.categorie = ttCat.catNaam.

            FOR EACH ttSpec WHERE ttSpec.catNr EQ ttCat.catNr BY ttSpec.specId:

                IF NOT lLeegRijen
                   AND NOT CAN-FIND(FIRST ttAgg WHERE ttAgg.sk EQ piSk AND ttAgg.lvl EQ 1 AND ttAgg.scp EQ ttSpec.specId) THEN
                    NEXT.

                iRows   = iRows + 1.
                iSeqRij = iSeqRij + 1.

                CREATE ttRij.
                ASSIGN
                    ttRij.catId    = iCatId
                    ttRij.rijId    = iSeqRij
                    ttRij.artnr    = ttSpec.artnr
                    ttRij.swBegins = ttSpec.swBegins
                    ttRij.eenheid  = ttSpec.eenheid.

                cUnit = (IF ttSpec.eenheid EQ ? THEN "-":u ELSE ttSpec.eenheid).
                IF LOOKUP(cUnit, cUnits) EQ 0 THEN
                    cUnits = cUnits + (IF cUnits EQ "":u THEN "":u ELSE ",":u) + cUnit.

                /* Row level: qty + orders only, omzet null. */
                ComputeMetrics(piSk, 1, ttSpec.specId, FALSE, TRUE).
                FOR EACH ttM BY ttM.idx:
                    CREATE ttRijPeriode.
                    BUFFER-COPY ttM TO ttRijPeriode ASSIGN ttRijPeriode.rijId = iSeqRij.
                END.

            END.

            IF iRows EQ 0 AND NOT lLeegRijen THEN
            DO:
                DELETE ttCategorie.
                NEXT.
            END.

            lMixed = (NUM-ENTRIES(cUnits) GT 1).
            ttCategorie.gemengdeEenheden = lMixed.

            /* Category level: all 6 metrics; qty hidden when units are mixed. */
            ComputeMetrics(piSk, 2, ttCat.catNr, lMixed, FALSE).
            FOR EACH ttM BY ttM.idx:
                CREATE ttCatPeriode.
                BUFFER-COPY ttM TO ttCatPeriode ASSIGN ttCatPeriode.catId = iCatId.
            END.

        END.

        /* Section level: qty null, orders distinct across the section, omzet summed. */
        ComputeMetrics(piSk, 3, 0, TRUE, FALSE).
        FOR EACH ttM BY ttM.idx:
            CREATE ttSectiePeriode.
            BUFFER-COPY ttM TO ttSectiePeriode ASSIGN ttSectiePeriode.sectieId = iSectieId.
        END.

        DO i = 1 TO iNCols:
            CREATE ttMeter.
            ASSIGN
                ttMeter.sectieId          = iSectieId
                ttMeter.idx               = i
                ttMeter.ledstripNomatrack = 0
                ttMeter.coverLicht        = 0.
            FIND ttMeterAgg WHERE ttMeterAgg.sk EQ piSk AND ttMeterAgg.kol EQ i NO-ERROR.
            IF AVAILABLE ttMeterAgg THEN
                ASSIGN
                    ttMeter.ledstripNomatrack = ttMeterAgg.mLsn
                    ttMeter.coverLicht        = ttMeterAgg.mCover.
        END.

    END METHOD.

END CLASS.
