/*------------------------------------------------------------------------
    File        : Led3OLSuspensionBE.cls
    Purpose     : Business Entity for led_3OL_suspension. NO-LOCK reads,
                  EXCLUSIVE-LOCK in a transaction for writes.
    Field map   : artnr        -> artnr        (PK1, char(50), validated against artikel.artnr)
                  onderdeel    -> onderdeel     (PK2, char(50))
                  ophangpunten -> ophangpunten  (integer)
                  aantal       -> aantal        (integer)
    Author(s)   : Devin
    Created     : 2026-08-29
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.Led3OLSuspensionBE:

    DEFINE TEMP-TABLE ttLed3OLSuspension NO-UNDO SERIALIZE-NAME "items":u
        FIELD artnr        AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD onderdeel     AS CHARACTER SERIALIZE-NAME "onderdeel":u
        FIELD ophangpunten  AS INTEGER   SERIALIZE-NAME "ophangpunten":u
        FIELD aantal         AS INTEGER   SERIALIZE-NAME "aantal":u
        INDEX idx-key IS PRIMARY artnr onderdeel.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_3OL_suspension, BUFFER pbTt FOR ttLed3OLSuspension ):
        ASSIGN
            pbTt.artnr        = pbSrc.artnr
            pbTt.onderdeel     = pbSrc.onderdeel
            pbTt.ophangpunten  = pbSrc.ophangpunten
            pbTt.aantal         = pbSrc.aantal
            .
    END METHOD.

    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbRow FOR led_3OL_suspension ):
        IF poBody:Has("ophangpunten":u) THEN pbRow.ophangpunten = poBody:GetInteger("ophangpunten":u).
        IF poBody:Has("aantal":u)       THEN pbRow.aantal       = poBody:GetInteger("aantal":u).
    END METHOD.

    METHOD PRIVATE LOGICAL ArtikelExists( INPUT pcArtnr AS CHARACTER ):
        FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.
        RETURN AVAILABLE artikel.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of led_3OL_suspension rows, optionally
                 filtered by artnr (exact) / artnrPrefix (BEGINS).
        Notes  : NO-LOCK read-only.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetItems(
        INPUT  piPage        AS INTEGER,
        INPUT  piPageSize     AS INTEGER,
        INPUT  pcArtnr        AS CHARACTER,
        INPUT  pcArtnrPrefix  AS CHARACTER,
        OUTPUT plHasMore      AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cScan  AS CHARACTER NO-UNDO.

        EMPTY TEMP-TABLE ttLed3OLSuspension.

        ASSIGN
            pcArtnr       = TRIM(pcArtnr)
            pcArtnrPrefix = TRIM(pcArtnrPrefix)
            cScan         = (IF pcArtnr NE "":u THEN pcArtnr ELSE pcArtnrPrefix)
            iSkip         = (piPage - 1) * piPageSize
            iSeen         = 0
            iTaken        = 0
            plHasMore     = FALSE
            .

        FOR EACH led_3OL_suspension NO-LOCK
            WHERE led_3OL_suspension.artnr BEGINS cScan
            BY led_3OL_suspension.artnr BY led_3OL_suspension.onderdeel:

            IF pcArtnr NE "":u AND led_3OL_suspension.artnr NE pcArtnr THEN NEXT.

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLed3OLSuspension.
            CopyToTt( BUFFER led_3OL_suspension, BUFFER ttLed3OLSuspension ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLed3OLSuspension:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER ):

        EMPTY TEMP-TABLE ttLed3OLSuspension.

        FIND FIRST led_3OL_suspension NO-LOCK
            WHERE led_3OL_suspension.artnr EQ pcArtnr AND led_3OL_suspension.onderdeel EQ pcOnderdeel
            NO-ERROR.

        IF AVAILABLE led_3OL_suspension THEN
        DO:
            CREATE ttLed3OLSuspension.
            CopyToTt( BUFFER led_3OL_suspension, BUFFER ttLed3OLSuspension ).
        END.

        RETURN TEMP-TABLE ttLed3OLSuspension:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new led_3OL_suspension row.
        Errors : AppError 404 - artnr not found in artikel.
                 AppError 409 - the artnr/onderdeel combo already exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLed3OLSuspension.

        IF NOT ArtikelExists(pcArtnr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("artikel &1 not found":u, pcArtnr), 404).

        DO TRANSACTION:
            FIND FIRST led_3OL_suspension EXCLUSIVE-LOCK
                WHERE led_3OL_suspension.artnr EQ pcArtnr AND led_3OL_suspension.onderdeel EQ pcOnderdeel
                NO-ERROR.
            IF AVAILABLE led_3OL_suspension THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_3OL_suspension &1/&2 already exists":u, pcArtnr, pcOnderdeel), 409).

            CREATE led_3OL_suspension.
            ASSIGN
                led_3OL_suspension.artnr     = pcArtnr
                led_3OL_suspension.onderdeel = pcOnderdeel
                .
            ApplyFields( INPUT poBody, BUFFER led_3OL_suspension ).

            CREATE ttLed3OLSuspension.
            CopyToTt( BUFFER led_3OL_suspension, BUFFER ttLed3OLSuspension ).
        END.

        RETURN TEMP-TABLE ttLed3OLSuspension:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing led_3OL_suspension row (ophangpunten/
                 aantal - the key is immutable).
        Errors : AppError 404 - row not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLed3OLSuspension.

        DO TRANSACTION:
            FIND FIRST led_3OL_suspension EXCLUSIVE-LOCK
                WHERE led_3OL_suspension.artnr EQ pcArtnr AND led_3OL_suspension.onderdeel EQ pcOnderdeel
                NO-ERROR.
            IF NOT AVAILABLE led_3OL_suspension THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_3OL_suspension &1/&2 not found":u, pcArtnr, pcOnderdeel), 404).

            ApplyFields( INPUT poBody, BUFFER led_3OL_suspension ).

            CREATE ttLed3OLSuspension.
            CopyToTt( BUFFER led_3OL_suspension, BUFFER ttLed3OLSuspension ).
        END.

        RETURN TEMP-TABLE ttLed3OLSuspension:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeleteItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER ):

        DO TRANSACTION:
            FIND FIRST led_3OL_suspension EXCLUSIVE-LOCK
                WHERE led_3OL_suspension.artnr EQ pcArtnr AND led_3OL_suspension.onderdeel EQ pcOnderdeel
                NO-ERROR.
            IF NOT AVAILABLE led_3OL_suspension THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_3OL_suspension &1/&2 not found":u, pcArtnr, pcOnderdeel), 404).

            DELETE led_3OL_suspension.
        END.

    END METHOD.

END CLASS. 
