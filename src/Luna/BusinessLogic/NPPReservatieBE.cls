/*------------------------------------------------------------------------
    File        : NPPReservatieBE.cls
    Purpose     : Business Entity for the NPP "Reservaties" tile (read-only).
                  GetQueue  - list of bons (direct mode) or bon/LVB groups
                              (productie mode) that need reservation
                              follow-up, plus deleted reservations.
                  GetDetail - bonlijn rows of one bon (optionally one
                              LVB group) with an effective-reservation status.
                  Port of the read-side logic in
                  \LHDC01\TESTLUNA$\LunaV12\NPP\NPPReservatie.w
                  (vul-bon-direct / vul-bon-productie / vul-bon-reservatie).
    Deviations  : see docs/backend (design doc) - the legacy "deleted
                  reservations" block has no sw-delete filter and its
                  bonlijn.aantal reference (no bonlijn in scope) is NOT
                  ported; swNomaled stays FALSE for deleted rows.
    Errors      : AppError 404 "Bon &1 not found" from GetDetail.
    Author(s)   : Devin
    Created     : 2026-09-18
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.NPPReservatieBE:

    DEFINE TEMP-TABLE ttQueue NO-UNDO
        FIELD bonnr          AS INTEGER
        FIELD groepnr        AS INTEGER
        FIELD datum          AS DATE
        FIELD levDatum       AS DATE
        FIELD naam           AS CHARACTER
        FIELD plaatsingWijze AS CHARACTER
        FIELD transport      AS CHARACTER
        FIELD stempel        AS CHARACTER
        FIELD lockId         AS CHARACTER
        FIELD dringend       AS LOGICAL INITIAL FALSE
        FIELD swReservatie   AS LOGICAL INITIAL FALSE
        FIELD swProductie    AS LOGICAL INITIAL FALSE
        FIELD swNomaled      AS LOGICAL INITIAL FALSE
        FIELD verwijderd     AS LOGICAL INITIAL FALSE
        FIELD deleteOpm      AS CHARACTER
        INDEX idxKey IS UNIQUE bonnr groepnr.

    DEFINE TEMP-TABLE ttDetail NO-UNDO
        FIELD lijnnr            AS INTEGER
        FIELD groepnr           AS INTEGER
        FIELD artnr             AS CHARACTER
        FIELD omschrijving      AS CHARACTER
        FIELD teLeveren         AS DECIMAL
        FIELD gereserv          AS DECIMAL
        FIELD effectiefGereserv AS DECIMAL
        FIELD swEffectief       AS LOGICAL
        FIELD effectiefStatus   AS CHARACTER
        FIELD kolomtitel        AS LOGICAL
        FIELD infolijn          AS LOGICAL
        FIELD subtotaal         AS LOGICAL
        INDEX idxLijn IS PRIMARY lijnnr.

    /* syspara thresholds ("dringend" day counts) - 0 when syspara missing */
    DEFINE PRIVATE VARIABLE iDringReservDirect AS INTEGER NO-UNDO.
    DEFINE PRIVATE VARIABLE iDringReservProd   AS INTEGER NO-UNDO.
    DEFINE PRIVATE VARIABLE iDringSamenDirect  AS INTEGER NO-UNDO.
    DEFINE PRIVATE VARIABLE iDringSamenProd    AS INTEGER NO-UNDO.

    METHOD PRIVATE VOID LoadSyspara():

        ASSIGN
            iDringReservDirect = 0
            iDringReservProd   = 0
            iDringSamenDirect  = 0
            iDringSamenProd    = 0.

        FIND FIRST syspara NO-LOCK NO-ERROR.
        IF AVAILABLE syspara THEN
            ASSIGN
                iDringReservDirect = syspara.dagen_DringendReservDirect
                iDringReservProd   = syspara.dagen_DringendReservProd
                iDringSamenDirect  = syspara.dagen_DringendSamenDirect
                iDringSamenProd    = syspara.dagen_DringendSamenProd.

    END METHOD.

    /* ProductieDatum.i: deadline -> production date (3 days before, minus weekend extra) */
    METHOD PRIVATE DATE ProdDatum( INPUT pdaDeadline AS DATE ):

        DEFINE VARIABLE iExtra AS INTEGER NO-UNDO.

        IF pdaDeadline EQ ? THEN RETURN ?.

        CASE WEEKDAY(pdaDeadline):
            WHEN 5 OR WHEN 6 THEN iExtra = 0.
            WHEN 7 THEN iExtra = 1.
            OTHERWISE iExtra = 2.
        END CASE.

        RETURN pdaDeadline - iExtra - 3.

    END METHOD.

    /* vul-bon-reservatie: creates the live queue row from the bon header */
    METHOD PRIVATE VOID CreateRow( INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER, INPUT pdaLev AS DATE ):

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN RETURN.

        CREATE ttQueue.
        ASSIGN
            ttQueue.bonnr          = piBonnr
            ttQueue.groepnr        = piGroepnr
            ttQueue.datum          = bon.datum
            ttQueue.levDatum       = pdaLev
            ttQueue.naam           = bon.naam
            ttQueue.plaatsingWijze = bon.plaatsing-wijze
            ttQueue.transport      = bon.transport
            ttQueue.stempel        = bon.stempel
            ttQueue.lockId         = bon.LockID
            ttQueue.swReservatie   = TRUE
            .

    END METHOD.

    /* Direct mode: one row per bon */
    METHOD PRIVATE VOID VulDirect():

        DEFINE VARIABLE dProd    AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dAantal  AS DECIMAL NO-UNDO.

        /* --- Reservaties --- */
        FOR EACH bonlijn NO-LOCK
            WHERE (bonlijn.stempel EQ "":u OR bonlijn.stempel EQ "O":u OR bonlijn.stempel EQ "B":u)
              AND ((bonlijn.gereserv NE 0 AND bonlijn.gereserv NE bonlijn.effectief-gereserv)
                OR (bonlijn.te-leveren LT 0 AND bonlijn.gereserv EQ 0))
              AND bonlijn.swSikta EQ FALSE,
            FIRST bon OF bonlijn NO-LOCK,
            FIRST artikel NO-LOCK WHERE artikel.artnr EQ bonlijn.artnr AND artikel.stock EQ TRUE
            BREAK BY bonlijn.bonnr BY bonlijn.swLed BY bonlijn.swProductie:

            IF FIRST-OF(bonlijn.bonnr) THEN
            DO:
                IF (bonlijn.swProductie EQ FALSE AND bonlijn.swLed EQ FALSE)
                   OR (bonlijn.swProductie AND bonlijn.gereserv GT 0) THEN
                DO:
                    CreateRow(bonlijn.bonnr, 0, bon.lev-dat).
                    FIND FIRST ttQueue WHERE ttQueue.bonnr EQ bonlijn.bonnr AND ttQueue.groepnr EQ 0 NO-ERROR.
                    IF AVAILABLE ttQueue AND (bonlijn.bon-datum + iDringReservDirect) LT TODAY THEN
                        ttQueue.dringend = TRUE.
                END.
            END.

            IF bonlijn.swProductie EQ FALSE AND bonlijn.swLed EQ FALSE AND bonlijn.aantal LT 0 THEN
            DO:
                FIND FIRST ttQueue WHERE ttQueue.bonnr EQ bonlijn.bonnr AND ttQueue.groepnr EQ 0 NO-ERROR.
                IF AVAILABLE ttQueue THEN ttQueue.swNomaled = TRUE.
            END.
        END.

        /* --- Productie samengesteld --- */
        FOR EACH bonlijn NO-LOCK
            WHERE (bonlijn.stempel EQ "":u OR bonlijn.stempel EQ "O":u OR bonlijn.stempel EQ "B":u)
              AND ((bonlijn.gereserv EQ 0 AND (bonlijn.gereserv NE bonlijn.effectief-gereserv OR bonlijn.effectief-gereserv EQ 0))
                OR (bonlijn.te-leveren GT bonlijn.gereserv))
              AND bonlijn.swLed EQ FALSE
              AND bonlijn.swSikta EQ FALSE,
            FIRST bon OF bonlijn NO-LOCK,
            FIRST artikel NO-LOCK WHERE artikel.artnr EQ bonlijn.artnr AND artikel.stock EQ TRUE
            BREAK BY bonlijn.bonnr BY bonlijn.swLed BY bonlijn.swProductie DESCENDING:

            IF FIRST-OF(bonlijn.bonnr) THEN
            DO:
                IF bonlijn.swProductie AND bonlijn.swLed EQ FALSE THEN
                DO:
                    FIND FIRST ttQueue WHERE ttQueue.bonnr EQ bonlijn.bonnr AND ttQueue.groepnr EQ 0 NO-ERROR.
                    IF NOT AVAILABLE ttQueue THEN
                    DO:
                        CreateRow(bonlijn.bonnr, 0, bon.lev-dat).
                        FIND FIRST ttQueue WHERE ttQueue.bonnr EQ bonlijn.bonnr AND ttQueue.groepnr EQ 0 NO-ERROR.
                    END.
                    IF AVAILABLE ttQueue AND (bonlijn.bon-datum + iDringSamenDirect) LT TODAY THEN
                        ttQueue.dringend = TRUE.
                END.
            END.

            /* Enough stock for production? */
            IF bonlijn.swProductie AND bonlijn.swLed EQ FALSE THEN
            DO:
                FIND FIRST ttQueue WHERE ttQueue.bonnr EQ bonlijn.bonnr AND ttQueue.groepnr EQ 0 NO-ERROR.
                IF AVAILABLE ttQueue THEN
                DO:
                    ASSIGN dProd = 99999999 dAantal = 0.
                    FOR EACH artlijn NO-LOCK WHERE artlijn.artnr EQ artikel.artnr:
                        FOR EACH bonlijn_productie NO-LOCK
                            WHERE bonlijn_productie.bonnr   EQ bonlijn.bonnr
                              AND bonlijn_productie.blijnnr EQ bonlijn.lijnnr
                              AND bonlijn_productie.artnr   EQ artlijn.l-artnr:
                            IF artlijn.aantal NE 0 THEN
                                dAantal = TRUNCATE(bonlijn_productie.gereserv / artlijn.aantal, 3).
                        END.
                        IF dAantal LT dProd THEN dProd = dAantal.
                    END.
                    IF dProd LE 0 OR dProd EQ 99999999 THEN
                        ASSIGN ttQueue.swProductie = TRUE dProd = 0.
                    IF dProd NE 0 THEN
                        ttQueue.swReservatie = TRUE.
                END.
            END.
        END.

        /* --- Verwijderde reservaties (no bonlijn reference here) --- */
        FOR EACH reservatie NO-LOCK WHERE reservatie.groepnr EQ 0 OR reservatie.swLed EQ FALSE:
            FIND FIRST ttQueue WHERE ttQueue.bonnr EQ reservatie.bonnr AND ttQueue.groepnr EQ 0 NO-ERROR.
            IF NOT AVAILABLE ttQueue THEN
            DO:
                CREATE ttQueue.
                ASSIGN
                    ttQueue.bonnr        = reservatie.bonnr
                    ttQueue.groepnr      = 0
                    ttQueue.datum        = reservatie.datum
                    ttQueue.naam         = reservatie.naam
                    ttQueue.stempel      = "D":u
                    ttQueue.swReservatie = TRUE
                    ttQueue.verwijderd   = TRUE
                    .
            END.
            IF ttQueue.verwijderd AND ttQueue.deleteOpm EQ "":u AND TRIM(reservatie.delete-opm) NE "":u THEN
                ttQueue.deleteOpm = reservatie.delete-opm.
        END.

    END METHOD.

    /* Productie mode: one row per (bon, LVB groepnr) */
    METHOD PRIVATE VOID VulProductie():

        DEFINE VARIABLE dProd          AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dAantal        AS DECIMAL NO-UNDO.
        DEFINE VARIABLE lMaatBevestigd AS LOGICAL NO-UNDO.
        DEFINE VARIABLE daDeadline     AS DATE    NO-UNDO.

        /* --- Reservaties --- */
        FOR EACH bonlijn NO-LOCK
            WHERE (bonlijn.stempel EQ "":u OR bonlijn.stempel EQ "O":u OR bonlijn.stempel EQ "B":u)
              AND ((bonlijn.gereserv NE 0 AND bonlijn.gereserv NE bonlijn.effectief-gereserv)
                OR (bonlijn.te-leveren LT 0 AND bonlijn.gereserv EQ 0))
              AND bonlijn.swSikta EQ FALSE,
            FIRST bon OF bonlijn NO-LOCK,
            FIRST artikel NO-LOCK WHERE artikel.artnr EQ bonlijn.artnr AND artikel.stock EQ TRUE
            BREAK BY bonlijn.bonnr BY bonlijn.groepnr BY bonlijn.swLed DESCENDING BY bonlijn.swProductie:

            IF FIRST-OF(bonlijn.groepnr) THEN
            DO:
                IF bonlijn.swLed AND bonlijn.swProductie EQ FALSE THEN
                DO:
                    FIND FIRST bon_led NO-LOCK
                        WHERE bon_led.bonnr EQ bonlijn.bonnr AND bon_led.groepnr EQ bonlijn.groepnr
                          AND bon_led.led_lijn EQ 0 AND bon_led.lijnnr EQ 31 AND bon_led.switch1 EQ TRUE NO-ERROR.
                    lMaatBevestigd = AVAILABLE bon_led.

                    IF lMaatBevestigd THEN
                    DO:
                        FIND FIRST bon_led NO-LOCK
                            WHERE bon_led.bonnr EQ bonlijn.bonnr AND bon_led.groepnr EQ bonlijn.groepnr
                              AND bon_led.led_lijn EQ 0 AND bon_led.lijnnr EQ 30 NO-ERROR.
                        daDeadline = IF AVAILABLE bon_led THEN bon_led.datum ELSE bonlijn.bon-datum.
                        daDeadline = ProdDatum(daDeadline).

                        CreateRow(bonlijn.bonnr, bonlijn.groepnr, daDeadline).
                        FIND FIRST ttQueue WHERE ttQueue.bonnr EQ bonlijn.bonnr AND ttQueue.groepnr EQ bonlijn.groepnr NO-ERROR.
                        IF AVAILABLE ttQueue AND daDeadline NE ? AND (daDeadline + iDringReservProd) LT TODAY THEN
                            ttQueue.dringend = TRUE.
                    END.
                END.
            END.
        END.

        /* --- Productie samengesteld --- */
        FOR EACH bonlijn NO-LOCK
            WHERE (bonlijn.stempel EQ "":u OR bonlijn.stempel EQ "O":u OR bonlijn.stempel EQ "B":u)
              AND ((bonlijn.gereserv EQ 0 AND (bonlijn.gereserv NE bonlijn.effectief-gereserv OR bonlijn.effectief-gereserv EQ 0))
                OR (bonlijn.te-leveren GT bonlijn.gereserv))
              AND bonlijn.swSikta EQ FALSE,
            FIRST bon OF bonlijn NO-LOCK,
            FIRST artikel NO-LOCK WHERE artikel.artnr EQ bonlijn.artnr AND artikel.stock EQ TRUE
            BREAK BY bonlijn.bonnr BY bonlijn.groepnr BY bonlijn.swLed DESCENDING BY bonlijn.swProductie DESCENDING:

            IF FIRST-OF(bonlijn.groepnr) THEN
            DO:
                lMaatBevestigd = FALSE.
                IF bonlijn.swLed AND bonlijn.swProductie THEN
                DO:
                    FIND FIRST bon_led NO-LOCK
                        WHERE bon_led.bonnr EQ bonlijn.bonnr AND bon_led.groepnr EQ bonlijn.groepnr
                          AND bon_led.led_lijn EQ 0 AND bon_led.lijnnr EQ 31 AND bon_led.switch1 EQ TRUE NO-ERROR.
                    lMaatBevestigd = AVAILABLE bon_led.

                    IF lMaatBevestigd THEN
                    DO:
                        FIND FIRST bon_led NO-LOCK
                            WHERE bon_led.bonnr EQ bonlijn.bonnr AND bon_led.groepnr EQ bonlijn.groepnr
                              AND bon_led.led_lijn EQ 0 AND bon_led.lijnnr EQ 30 NO-ERROR.
                        daDeadline = IF AVAILABLE bon_led THEN bon_led.datum ELSE bonlijn.bon-datum.
                        daDeadline = ProdDatum(daDeadline).

                        FIND FIRST ttQueue WHERE ttQueue.bonnr EQ bonlijn.bonnr AND ttQueue.groepnr EQ bonlijn.groepnr NO-ERROR.
                        IF NOT AVAILABLE ttQueue THEN
                        DO:
                            CreateRow(bonlijn.bonnr, bonlijn.groepnr, daDeadline).
                            FIND FIRST ttQueue WHERE ttQueue.bonnr EQ bonlijn.bonnr AND ttQueue.groepnr EQ bonlijn.groepnr NO-ERROR.
                        END.
                        IF AVAILABLE ttQueue AND daDeadline NE ? AND (daDeadline + iDringSamenProd) LT TODAY THEN
                            ttQueue.dringend = TRUE.
                    END.
                END.
            END.

            /* Enough stock for production? */
            IF lMaatBevestigd AND bonlijn.swLed AND bonlijn.swProductie THEN
            DO:
                FIND FIRST ttQueue WHERE ttQueue.bonnr EQ bonlijn.bonnr AND ttQueue.groepnr EQ bonlijn.groepnr NO-ERROR.
                IF AVAILABLE ttQueue THEN
                DO:
                    ASSIGN dProd = 99999999 dAantal = 0.
                    FOR EACH artlijn NO-LOCK WHERE artlijn.artnr EQ artikel.artnr:
                        FOR EACH bonlijn_productie NO-LOCK
                            WHERE bonlijn_productie.bonnr   EQ bonlijn.bonnr
                              AND bonlijn_productie.blijnnr EQ bonlijn.lijnnr
                              AND bonlijn_productie.artnr   EQ artlijn.l-artnr:
                            IF artlijn.aantal NE 0 THEN
                                dAantal = TRUNCATE(bonlijn_productie.gereserv / artlijn.aantal, 3).
                        END.
                        IF dAantal LT dProd THEN dProd = dAantal.
                    END.
                    IF dProd LE 0 OR dProd EQ 99999999 THEN
                        ASSIGN ttQueue.swProductie = TRUE dProd = 0.
                    IF dProd NE 0 THEN
                        ttQueue.swReservatie = TRUE.
                END.
            END.
        END.

        /* --- Verwijderde reservaties (no bonlijn reference here) --- */
        FOR EACH reservatie NO-LOCK WHERE reservatie.groepnr NE 0 AND reservatie.swLed EQ TRUE:
            FIND FIRST ttQueue WHERE ttQueue.bonnr EQ reservatie.bonnr AND ttQueue.groepnr EQ reservatie.groepnr NO-ERROR.
            IF NOT AVAILABLE ttQueue THEN
            DO:
                CREATE ttQueue.
                ASSIGN
                    ttQueue.bonnr        = reservatie.bonnr
                    ttQueue.groepnr      = reservatie.groepnr
                    ttQueue.datum        = reservatie.datum
                    ttQueue.naam         = reservatie.naam
                    ttQueue.stempel      = "D":u
                    ttQueue.swReservatie = TRUE
                    ttQueue.verwijderd   = TRUE
                    .
            END.
            IF ttQueue.verwijderd AND ttQueue.deleteOpm EQ "":u AND TRIM(reservatie.delete-opm) NE "":u THEN
                ttQueue.deleteOpm = reservatie.delete-opm.
        END.

    END METHOD.

    METHOD PRIVATE VOID AddDate( INPUT poObj AS JsonObject, INPUT pcName AS CHARACTER, INPUT pdaValue AS DATE ):

        IF pdaValue EQ ? THEN
            poObj:AddNull(pcName).
        ELSE
            poObj:Add(pcName,
                STRING(YEAR(pdaValue), "9999":u) + "-":u
              + STRING(MONTH(pdaValue), "99":u) + "-":u
              + STRING(DAY(pdaValue), "99":u)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Queue list for mode direct|productie. Errors: AppError 400.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject GetQueue( INPUT pcMode AS CHARACTER ):

        DEFINE VARIABLE oResult AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems  AS JsonArray  NO-UNDO.
        DEFINE VARIABLE oItem   AS JsonObject NO-UNDO.
        DEFINE VARIABLE lProd   AS LOGICAL    NO-UNDO.

        IF pcMode NE "direct":u AND pcMode NE "productie":u THEN
            UNDO, THROW NEW Progress.Lang.AppError("Ongeldige parameter 'mode' (direct|productie)":u, 400).

        lProd = (pcMode EQ "productie":u).

        EMPTY TEMP-TABLE ttQueue.
        LoadSyspara().

        IF lProd THEN
            VulProductie().
        ELSE
            VulDirect().

        oItems = NEW JsonArray().

        FOR EACH ttQueue NO-LOCK BY ttQueue.verwijderd BY ttQueue.levDatum BY ttQueue.bonnr BY ttQueue.groepnr:
            oItem = NEW JsonObject().
            oItem:Add("bonnr":u, ttQueue.bonnr).
            oItem:Add("groepnr":u, ttQueue.groepnr).
            AddDate(oItem, "datum":u, ttQueue.datum).
            AddDate(oItem, "levDatum":u, ttQueue.levDatum).
            oItem:Add("naam":u, ttQueue.naam).
            oItem:Add("plaatsingWijze":u, ttQueue.plaatsingWijze).
            oItem:Add("transport":u, ttQueue.transport).
            oItem:Add("stempel":u, ttQueue.stempel).
            oItem:Add("lockId":u, ttQueue.lockId).
            oItem:Add("dringend":u, ttQueue.dringend).
            oItem:Add("swReservatie":u, ttQueue.swReservatie).
            oItem:Add("swProductie":u, ttQueue.swProductie).
            oItem:Add("swNomaled":u, ttQueue.swNomaled).
            oItem:Add("verwijderd":u, ttQueue.verwijderd).
            IF ttQueue.deleteOpm EQ ? OR ttQueue.deleteOpm EQ "":u THEN
                oItem:AddNull("deleteOpm":u).
            ELSE
                oItem:Add("deleteOpm":u, ttQueue.deleteOpm).
            oItems:Add(oItem).
        END.

        oResult = NEW JsonObject().
        oResult:Add("mode":u, pcMode).
        oResult:Add("dringendDagen":u, IF lProd THEN iDringReservProd ELSE iDringReservDirect).
        oResult:Add("items":u, oItems).

        RETURN oResult.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Detail lines of a bon (optionally one LVB group).
        Errors : AppError 404 "Bon &1 not found".
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject GetDetail( INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER ):

        DEFINE VARIABLE oResult AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems  AS JsonArray  NO-UNDO.
        DEFINE VARIABLE oItem   AS JsonObject NO-UNDO.
        DEFINE VARIABLE lItem   AS LOGICAL    NO-UNDO.

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

        EMPTY TEMP-TABLE ttDetail.

        FOR EACH bonlijn NO-LOCK
            WHERE bonlijn.bonnr EQ piBonnr
              AND (piGroepnr LE 0 OR bonlijn.groepnr EQ piGroepnr)
            BY bonlijn.lijnnr:

            FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ bonlijn.artnr NO-ERROR.

            CREATE ttDetail.
            ASSIGN
                ttDetail.lijnnr            = bonlijn.lijnnr
                ttDetail.groepnr           = bonlijn.groepnr
                ttDetail.artnr             = (IF AVAILABLE artikel AND TRIM(artikel.x-ref) NE "":u THEN artikel.x-ref ELSE bonlijn.artnr)
                ttDetail.omschrijving      = bonlijn.omschr
                ttDetail.teLeveren         = bonlijn.te-leveren
                ttDetail.gereserv          = bonlijn.gereserv
                ttDetail.effectiefGereserv = bonlijn.effectief-gereserv
                ttDetail.swEffectief       = bonlijn.swEffectief
                ttDetail.kolomtitel        = bonlijn.kolomtitel
                ttDetail.infolijn          = bonlijn.infolijn
                ttDetail.subtotaal         = bonlijn.subtotaal
                .

            lItem = NOT (bonlijn.kolomtitel OR bonlijn.infolijn OR bonlijn.subtotaal).

            IF NOT lItem THEN
                ttDetail.effectiefStatus = ?.
            ELSE IF NOT bonlijn.swEffectief THEN
                ttDetail.effectiefStatus = "niet_effectief":u.
            ELSE IF bonlijn.gereserv EQ bonlijn.effectief-gereserv THEN
                ttDetail.effectiefStatus = "volledig_effectief":u.
            ELSE IF bonlijn.effectief-gereserv EQ 0 THEN
                ttDetail.effectiefStatus = "geen_effectief":u.
            ELSE
                ttDetail.effectiefStatus = "gedeeltelijk_effectief":u.
        END.

        oItems = NEW JsonArray().

        FOR EACH ttDetail NO-LOCK BY ttDetail.lijnnr:
            oItem = NEW JsonObject().
            oItem:Add("lijnnr":u, ttDetail.lijnnr).
            oItem:Add("groepnr":u, ttDetail.groepnr).
            oItem:Add("artnr":u, ttDetail.artnr).
            oItem:Add("omschrijving":u, ttDetail.omschrijving).
            oItem:Add("teLeveren":u, ttDetail.teLeveren).
            oItem:Add("gereserv":u, ttDetail.gereserv).
            oItem:Add("effectiefGereserv":u, ttDetail.effectiefGereserv).
            oItem:Add("swEffectief":u, ttDetail.swEffectief).
            IF ttDetail.effectiefStatus EQ ? THEN
                oItem:AddNull("effectiefStatus":u).
            ELSE
                oItem:Add("effectiefStatus":u, ttDetail.effectiefStatus).
            oItem:Add("kolomtitel":u, ttDetail.kolomtitel).
            oItem:Add("infolijn":u, ttDetail.infolijn).
            oItem:Add("subtotaal":u, ttDetail.subtotaal).
            oItems:Add(oItem).
        END.

        oResult = NEW JsonObject().
        oResult:Add("bonnr":u, piBonnr).
        oResult:Add("groepnr":u, MAXIMUM(piGroepnr, 0)).
        oResult:Add("nBedrag":u, bon.n-bedrag).
        oResult:Add("items":u, oItems).

        RETURN oResult.

    END METHOD.

END CLASS.
