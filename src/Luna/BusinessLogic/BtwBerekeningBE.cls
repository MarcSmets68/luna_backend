/*------------------------------------------------------------------------
    File        : BtwBerekeningBE.cls
    Purpose     : Pure read-only VAT/BTW calculation service (Iteratie B).
                  The only DB access is a NO-LOCK FIND on `btw-kode` to
                  resolve the percentage for a given btw-kode. Does not
                  write to any table.
    Syntax      : Called from Luna.Web.BtwHandler (POST /web/btw/bereken).
    Description : Groups input lines by btw-kode (max 2 unique groups),
                  applies an optional document-level discount (K3 fixed
                  amount pro-rata by group share, or K5 uniform percentage),
                  then applies the group's btw-kode percentage to the
                  post-discount basis. If plSwRegime is FALSE, the whole
                  btw-kode/group lookup is skipped and only a flat
                  totaal (no VAT) is returned.
    Author(s)   : Devin
    Created     : 2026-09-27
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.BtwBerekeningBE:

    DEFINE TEMP-TABLE ttBtwInvoerLijn NO-UNDO SERIALIZE-NAME "regels":u
        FIELD btwKode       AS CHARACTER SERIALIZE-NAME "btwKode":u
        FIELD bedrag        AS DECIMAL   SERIALIZE-NAME "bedrag":u
        FIELD totaalRecupel AS DECIMAL   SERIALIZE-NAME "totaalRecupel":u.

    DEFINE TEMP-TABLE ttBtwTotaal NO-UNDO SERIALIZE-NAME "totaal":u   /* altijd exact 1 rij */
        FIELD regimeToegepast AS LOGICAL SERIALIZE-NAME "regimeToegepast":u
        FIELD totaalBasis     AS DECIMAL SERIALIZE-NAME "totaalBasis":u
        FIELD totBtw          AS DECIMAL SERIALIZE-NAME "totBtw":u
        FIELD totaalInclBtw   AS DECIMAL SERIALIZE-NAME "totaalInclBtw":u.

    DEFINE TEMP-TABLE ttBtwGroep NO-UNDO SERIALIZE-NAME "groepen":u   /* 0-2 rijen, alleen gevuld als regimeToegepast */
        FIELD btwKode    AS CHARACTER SERIALIZE-NAME "btwKode":u
        FIELD percentage AS DECIMAL   SERIALIZE-NAME "percentage":u
        FIELD basis      AS DECIMAL   SERIALIZE-NAME "basis":u
        FIELD btwBedrag  AS DECIMAL   SERIALIZE-NAME "btwBedrag":u.

    DEFINE DATASET dsBtwResultaat FOR ttBtwTotaal, ttBtwGroep.

    /* Internal-only aggregation table - never serialized, never exposed
       outside this class. Groups input lines by btw-kode. */
    DEFINE PRIVATE TEMP-TABLE ttGroepAgg NO-UNDO
        FIELD btwKode  AS CHARACTER
        FIELD basisRuw AS DECIMAL
        INDEX idx-kode IS UNIQUE btwKode.

    /*------------------------------------------------------------------------------
        Purpose: Returns a HANDLE to a fresh, empty ttBtwInvoerLijn buffer
                 the caller (Luna.Web.BtwHandler) can populate (e.g. via
                 HANDLE:READ-JSON) and then pass straight into
                 BerekenBtw() as phInvoerLijnen.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetInvoerLijnenHandle():

        RETURN TEMP-TABLE ttBtwInvoerLijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Orchestrates the full BTW calculation. Returns a HANDLE to
                 the dsBtwResultaat ProDataSet (ttBtwTotaal + ttBtwGroep).
        Errors : AppError 400 - more than 2 unique btw-kodes in
                          phInvoerLijnen, or an unrecognized pcTypeKorting.
                 AppError 404 - a btw-kode used by a group does not exist
                          in the btw-kode table.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE BerekenBtw(
        INPUT phInvoerLijnen              AS HANDLE,
        INPUT plSwRegime                  AS LOGICAL,
        INPUT plSwPrijsRecup              AS LOGICAL,
        INPUT pcTypeKorting               AS CHARACTER,
        INPUT pdDocumentKortingBedrag     AS DECIMAL,
        INPUT pdDocumentKortingPercentage AS DECIMAL ):

        IF LOOKUP(pcTypeKorting, ",K3,K5":u) EQ 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Unknown typeKorting '&1', expected '', K3 or K5":u, pcTypeKorting), 400).

        EMPTY TEMP-TABLE ttBtwTotaal.
        EMPTY TEMP-TABLE ttBtwGroep.
        EMPTY TEMP-TABLE ttGroepAgg.

        IF plSwRegime THEN
            BerekenMetRegime(phInvoerLijnen, plSwPrijsRecup, pcTypeKorting,
                pdDocumentKortingBedrag, pdDocumentKortingPercentage).
        ELSE
            BerekenZonderRegime(phInvoerLijnen, pcTypeKorting,
                pdDocumentKortingBedrag, pdDocumentKortingPercentage).

        RETURN DATASET dsBtwResultaat:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: swRegime = TRUE path - group by btw-kode (max 2), apply
                 pro-rata/uniform document discount per group, resolve each
                 group's btw-kode percentage, fill ttBtwGroep + ttBtwTotaal.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BerekenMetRegime(
        INPUT phInvoerLijnen AS HANDLE,
        INPUT plSwPrijsRecup AS LOGICAL,
        INPUT pcTypeKorting AS CHARACTER,
        INPUT pdDocumentKortingBedrag AS DECIMAL,
        INPUT pdDocumentKortingPercentage AS DECIMAL ):

        DEFINE VARIABLE hBuffer          AS HANDLE    NO-UNDO.
        DEFINE VARIABLE hQuery           AS HANDLE    NO-UNDO.
        DEFINE VARIABLE cBtwKode         AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dBedrag          AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dRecupel         AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE iAantalGroepen   AS INTEGER   NO-UNDO.
        DEFINE VARIABLE dTotaalBasisRuw  AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dReductie        AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dBasisNaKorting  AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dTotBtw          AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dTotaalBasis     AS DECIMAL   NO-UNDO.

        hBuffer = phInvoerLijnen:DEFAULT-BUFFER-HANDLE.

        CREATE QUERY hQuery.
        hQuery:SET-BUFFERS(hBuffer).
        hQuery:QUERY-PREPARE(SUBSTITUTE("FOR EACH &1":u, hBuffer:NAME)).
        hQuery:QUERY-OPEN().
        hQuery:GET-FIRST().
        DO WHILE NOT hQuery:QUERY-OFF-END:

            ASSIGN
                cBtwKode = hBuffer:BUFFER-FIELD("btwKode":u):BUFFER-VALUE
                dBedrag  = hBuffer:BUFFER-FIELD("bedrag":u):BUFFER-VALUE
                dRecupel = hBuffer:BUFFER-FIELD("totaalRecupel":u):BUFFER-VALUE
                .

            FIND FIRST ttGroepAgg WHERE ttGroepAgg.btwKode EQ cBtwKode NO-ERROR.
            IF NOT AVAILABLE ttGroepAgg THEN
            DO:
                CREATE ttGroepAgg.
                ttGroepAgg.btwKode = cBtwKode.
            END.

            ttGroepAgg.basisRuw = ttGroepAgg.basisRuw + dBedrag.
            IF plSwPrijsRecup THEN
                ttGroepAgg.basisRuw = ttGroepAgg.basisRuw + dRecupel.

            hQuery:GET-NEXT().
        END.
        hQuery:QUERY-CLOSE().
        DELETE OBJECT hQuery.

        iAantalGroepen = 0.
        FOR EACH ttGroepAgg NO-LOCK:
            iAantalGroepen = iAantalGroepen + 1.
        END.

        IF iAantalGroepen GT 2 THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Maximum 2 unieke btw-kodes toegestaan, gevonden: &1":u, iAantalGroepen), 400).

        dTotaalBasisRuw = 0.
        FOR EACH ttGroepAgg NO-LOCK:
            dTotaalBasisRuw = dTotaalBasisRuw + ttGroepAgg.basisRuw.
        END.

        FOR EACH ttGroepAgg NO-LOCK:

            CASE pcTypeKorting:
                WHEN "K5":u THEN
                    dReductie = ttGroepAgg.basisRuw * pdDocumentKortingPercentage / 100.
                WHEN "K3":u THEN
                DO:
                    IF dTotaalBasisRuw EQ 0 THEN
                        dReductie = 0.
                    ELSE
                        dReductie = pdDocumentKortingBedrag * (ttGroepAgg.basisRuw / dTotaalBasisRuw).
                END.
                OTHERWISE
                    dReductie = 0.
            END CASE.

            dBasisNaKorting = ttGroepAgg.basisRuw - dReductie.

            FindBtwKodeGroep(ttGroepAgg.btwKode, dBasisNaKorting).

        END.

        dTotBtw      = 0.
        dTotaalBasis = 0.
        FOR EACH ttBtwGroep NO-LOCK:
            ASSIGN
                dTotBtw      = dTotBtw + ttBtwGroep.btwBedrag
                dTotaalBasis = dTotaalBasis + ttBtwGroep.basis
                .
        END.

        CREATE ttBtwTotaal.
        ASSIGN
            ttBtwTotaal.regimeToegepast = TRUE
            ttBtwTotaal.totaalBasis     = ROUND(dTotaalBasis, 2)
            ttBtwTotaal.totBtw          = ROUND(dTotBtw, 2)
            ttBtwTotaal.totaalInclBtw   = ROUND(dTotaalBasis, 2) + ROUND(dTotBtw, 2)
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Resolves the btw-kode percentage for one group and creates
                 the corresponding ttBtwGroep row (unrounded basis/btwBedrag
                 - see class header/design doc).
        Errors : AppError 404 - pcBtwKode not found in btw-kode.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID FindBtwKodeGroep( INPUT pcBtwKode AS CHARACTER, INPUT pdBasisNaKorting AS DECIMAL ):

        FIND FIRST btw-kode NO-LOCK WHERE btw-kode.kode EQ pcBtwKode NO-ERROR.
        IF NOT AVAILABLE btw-kode THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Unknown btw-kode '&1'":u, pcBtwKode), 404).

        CREATE ttBtwGroep.
        ASSIGN
            ttBtwGroep.btwKode    = pcBtwKode
            ttBtwGroep.percentage = btw-kode.btw
            ttBtwGroep.basis      = pdBasisNaKorting
            ttBtwGroep.btwBedrag  = pdBasisNaKorting * btw-kode.btw / 100
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: swRegime = FALSE path - no btw-kode grouping/lookup at all.
                 Applies the document discount to the flat sum of all input
                 lines' `bedrag` (recupel is NOT included here - see design
                 doc step 8) and returns totBtw = 0.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BerekenZonderRegime(
        INPUT phInvoerLijnen AS HANDLE,
        INPUT pcTypeKorting AS CHARACTER,
        INPUT pdDocumentKortingBedrag AS DECIMAL,
        INPUT pdDocumentKortingPercentage AS DECIMAL ):

        DEFINE VARIABLE hBuffer         AS HANDLE  NO-UNDO.
        DEFINE VARIABLE hQuery          AS HANDLE  NO-UNDO.
        DEFINE VARIABLE dTotaalBasisRuw AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dReductie       AS DECIMAL NO-UNDO.

        hBuffer = phInvoerLijnen:DEFAULT-BUFFER-HANDLE.

        CREATE QUERY hQuery.
        hQuery:SET-BUFFERS(hBuffer).
        hQuery:QUERY-PREPARE(SUBSTITUTE("FOR EACH &1":u, hBuffer:NAME)).
        hQuery:QUERY-OPEN().
        hQuery:GET-FIRST().
        DO WHILE NOT hQuery:QUERY-OFF-END:
            dTotaalBasisRuw = dTotaalBasisRuw + hBuffer:BUFFER-FIELD("bedrag":u):BUFFER-VALUE.
            hQuery:GET-NEXT().
        END.
        hQuery:QUERY-CLOSE().
        DELETE OBJECT hQuery.

        CASE pcTypeKorting:
            WHEN "K5":u THEN
                dReductie = dTotaalBasisRuw * pdDocumentKortingPercentage / 100.
            WHEN "K3":u THEN
                dReductie = pdDocumentKortingBedrag.
            OTHERWISE
                dReductie = 0.
        END CASE.

        CREATE ttBtwTotaal.
        ASSIGN
            ttBtwTotaal.regimeToegepast = FALSE
            ttBtwTotaal.totaalBasis     = ROUND(dTotaalBasisRuw - dReductie, 2)
            ttBtwTotaal.totBtw          = 0
            ttBtwTotaal.totaalInclBtw   = ROUND(dTotaalBasisRuw - dReductie, 2)
            .

    END METHOD.

END CLASS.
