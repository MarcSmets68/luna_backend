/*------------------------------------------------------------------------
    File        : Led3OLArtikelsBE.cls
    Purpose     : Business Entity for led_3OL_artikels (~244K rows in
                  production). NO-LOCK reads, EXCLUSIVE-LOCK in a
                  transaction for writes.
    Field map   : artnr     -> artnr     (PK1, char(50), validated against artikel.artnr)
                  onderdeel -> onderdeel (PK2, char(15))
                  lengte    -> lengte    (integer)
                  aantal    -> aantal    (decimal)
                  swExport  -> swExport  (logical)
    Notes       : GetItems pushes the artnr/artnrPrefix filter AND the
                  page window down to the ABL query itself (BEGINS on the
                  unique led_3OL_artikels-x1 index, whose leading component
                  is artnr) - it never loads the 244K-row table into memory
                  first. Same pattern as Luna.BusinessLogic.LedAuteurBE.
    Author(s)   : Devin
    Created     : 2026-08-29
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.Led3OLArtikelsBE:

    DEFINE TEMP-TABLE ttLed3OLArtikels NO-UNDO SERIALIZE-NAME "items":u
        FIELD artnr     AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD onderdeel AS CHARACTER SERIALIZE-NAME "onderdeel":u
        FIELD lengte    AS INTEGER   SERIALIZE-NAME "lengte":u
        FIELD aantal    AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD swExport  AS LOGICAL   SERIALIZE-NAME "swExport":u
        INDEX idx-key IS PRIMARY artnr onderdeel.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_3OL_artikels, BUFFER pbTt FOR ttLed3OLArtikels ):
        ASSIGN
            pbTt.artnr     = pbSrc.artnr
            pbTt.onderdeel = pbSrc.onderdeel
            pbTt.lengte    = pbSrc.lengte
            pbTt.aantal    = pbSrc.aantal
            pbTt.swExport  = pbSrc.swExport
            .
    END METHOD.

    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbRow FOR led_3OL_artikels ):
        IF poBody:Has("lengte":u)   THEN pbRow.lengte   = poBody:GetInteger("lengte":u).
        IF poBody:Has("aantal":u)   THEN pbRow.aantal   = poBody:GetDecimal("aantal":u).
        IF poBody:Has("swExport":u) THEN pbRow.swExport = poBody:GetLogical("swExport":u).
    END METHOD.

    METHOD PRIVATE LOGICAL ArtikelExists( INPUT pcArtnr AS CHARACTER ):
        FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.
        RETURN AVAILABLE artikel.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of led_3OL_artikels rows, filtered by artnr
                 (exact) and/or artnrPrefix (BEGINS). Both the filter and
                 the page/skip window are applied directly by this single
                 FOR EACH (range-scanning the unique led_3OL_artikels-x1
                 index on artnr+onderdeel) - this table has ~244K rows in
                 production and must never be pulled fully into memory first.
        Notes  : NO-LOCK read-only. piPage/piPageSize are expected to
                 already be validated/clamped by the caller.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetItems(
        INPUT  piPage         AS INTEGER,
        INPUT  piPageSize      AS INTEGER,
        INPUT  pcArtnr         AS CHARACTER,
        INPUT  pcArtnrPrefix   AS CHARACTER,
        OUTPUT plHasMore       AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cScan  AS CHARACTER NO-UNDO.

        EMPTY TEMP-TABLE ttLed3OLArtikels.

        ASSIGN
            pcArtnr       = TRIM(pcArtnr)
            pcArtnrPrefix = TRIM(pcArtnrPrefix)
            cScan         = (IF pcArtnr NE "":u THEN pcArtnr ELSE pcArtnrPrefix)
            iSkip         = (piPage - 1) * piPageSize
            iSeen         = 0
            iTaken        = 0
            plHasMore     = FALSE
            .

        /* artnr BEGINS cScan is a single, un-OR'd condition so the query
           optimizer can range-scan the unique led_3OL_artikels-x1 index -
           see Luna.BusinessLogic.ArtikelBE:GetArtikelen for why this must
           stay un-OR'd. The exact-artnr case is narrowed further by the
           per-row NE check below. */
        FOR EACH led_3OL_artikels NO-LOCK
            WHERE led_3OL_artikels.artnr BEGINS cScan
            BY led_3OL_artikels.artnr BY led_3OL_artikels.onderdeel:

            IF pcArtnr NE "":u AND led_3OL_artikels.artnr NE pcArtnr THEN NEXT.

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLed3OLArtikels.
            CopyToTt( BUFFER led_3OL_artikels, BUFFER ttLed3OLArtikels ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLed3OLArtikels:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER ):

        EMPTY TEMP-TABLE ttLed3OLArtikels.

        FIND FIRST led_3OL_artikels NO-LOCK
            WHERE led_3OL_artikels.artnr EQ pcArtnr AND led_3OL_artikels.onderdeel EQ pcOnderdeel
            NO-ERROR.

        IF AVAILABLE led_3OL_artikels THEN
        DO:
            CREATE ttLed3OLArtikels.
            CopyToTt( BUFFER led_3OL_artikels, BUFFER ttLed3OLArtikels ).
        END.

        RETURN TEMP-TABLE ttLed3OLArtikels:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new led_3OL_artikels row.
        Errors : AppError 404 - artnr not found in artikel.
                 AppError 409 - the artnr/onderdeel combo already exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLed3OLArtikels.

        IF NOT ArtikelExists(pcArtnr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("artikel &1 not found":u, pcArtnr), 404).

        DO TRANSACTION:
            FIND FIRST led_3OL_artikels EXCLUSIVE-LOCK
                WHERE led_3OL_artikels.artnr EQ pcArtnr AND led_3OL_artikels.onderdeel EQ pcOnderdeel
                NO-ERROR.
            IF AVAILABLE led_3OL_artikels THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_3OL_artikels &1/&2 already exists":u, pcArtnr, pcOnderdeel), 409).

            CREATE led_3OL_artikels.
            ASSIGN
                led_3OL_artikels.artnr     = pcArtnr
                led_3OL_artikels.onderdeel = pcOnderdeel
                .
            ApplyFields( INPUT poBody, BUFFER led_3OL_artikels ).

            CREATE ttLed3OLArtikels.
            CopyToTt( BUFFER led_3OL_artikels, BUFFER ttLed3OLArtikels ).
        END.

        RETURN TEMP-TABLE ttLed3OLArtikels:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing led_3OL_artikels row (lengte/aantal/
                 swExport - the key is immutable).
        Errors : AppError 404 - row not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLed3OLArtikels.

        DO TRANSACTION:
            FIND FIRST led_3OL_artikels EXCLUSIVE-LOCK
                WHERE led_3OL_artikels.artnr EQ pcArtnr AND led_3OL_artikels.onderdeel EQ pcOnderdeel
                NO-ERROR.
            IF NOT AVAILABLE led_3OL_artikels THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_3OL_artikels &1/&2 not found":u, pcArtnr, pcOnderdeel), 404).

            ApplyFields( INPUT poBody, BUFFER led_3OL_artikels ).

            CREATE ttLed3OLArtikels.
            CopyToTt( BUFFER led_3OL_artikels, BUFFER ttLed3OLArtikels ).
        END.

        RETURN TEMP-TABLE ttLed3OLArtikels:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeleteItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER ):

        DO TRANSACTION:
            FIND FIRST led_3OL_artikels EXCLUSIVE-LOCK
                WHERE led_3OL_artikels.artnr EQ pcArtnr AND led_3OL_artikels.onderdeel EQ pcOnderdeel
                NO-ERROR.
            IF NOT AVAILABLE led_3OL_artikels THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_3OL_artikels &1/&2 not found":u, pcArtnr, pcOnderdeel), 404).

            DELETE led_3OL_artikels.
        END.

    END METHOD.

END CLASS. 
