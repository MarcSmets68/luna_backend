/*------------------------------------------------------------------------
    File        : LedTTBE.cls
    Purpose     : Business Entity for led_TT. NO-LOCK reads, EXCLUSIVE-LOCK
                  in a transaction for writes.
    Field map   : artnr     -> artnr     (PK1, char(50), validated against artikel.artnr)
                  onderdeel -> onderdeel (PK2, char(50))
                  tt        -> TT        (char(100))
    Notes       : This table is currently empty in production and its real
                  usage is unconfirmed - built structurally identical to
                  led_3OL_suspension per the design doc, no extra rules invented.
    Author(s)   : Devin
    Created     : 2026-08-29
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LedTTBE:

    DEFINE TEMP-TABLE ttLedTT NO-UNDO SERIALIZE-NAME "items":u
        FIELD artnr     AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD onderdeel AS CHARACTER SERIALIZE-NAME "onderdeel":u
        FIELD tt         AS CHARACTER SERIALIZE-NAME "tt":u
        INDEX idx-key IS PRIMARY artnr onderdeel.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_TT, BUFFER pbTt FOR ttLedTT ):
        ASSIGN
            pbTt.artnr     = pbSrc.artnr
            pbTt.onderdeel = pbSrc.onderdeel
            pbTt.tt        = pbSrc.TT
            .
    END METHOD.

    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbRow FOR led_TT ):
        IF poBody:Has("tt":u) THEN pbRow.TT = poBody:GetCharacter("tt":u).
    END METHOD.

    METHOD PRIVATE LOGICAL ArtikelExists( INPUT pcArtnr AS CHARACTER ):
        FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.
        RETURN AVAILABLE artikel.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of led_TT rows, optionally filtered by
                 artnr (exact) / artnrPrefix (BEGINS).
        Notes  : NO-LOCK read-only. Table is currently empty in production;
                 filter is still pushed into the FOR EACH WHERE for consistency.
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

        EMPTY TEMP-TABLE ttLedTT.

        ASSIGN
            pcArtnr       = TRIM(pcArtnr)
            pcArtnrPrefix = TRIM(pcArtnrPrefix)
            cScan         = (IF pcArtnr NE "":u THEN pcArtnr ELSE pcArtnrPrefix)
            iSkip         = (piPage - 1) * piPageSize
            iSeen         = 0
            iTaken        = 0
            plHasMore     = FALSE
            .

        FOR EACH led_TT NO-LOCK WHERE led_TT.artnr BEGINS cScan BY led_TT.artnr BY led_TT.onderdeel:

            IF pcArtnr NE "":u AND led_TT.artnr NE pcArtnr THEN NEXT.

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLedTT.
            CopyToTt( BUFFER led_TT, BUFFER ttLedTT ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLedTT:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER ):

        EMPTY TEMP-TABLE ttLedTT.

        FIND FIRST led_TT NO-LOCK WHERE led_TT.artnr EQ pcArtnr AND led_TT.onderdeel EQ pcOnderdeel NO-ERROR.

        IF AVAILABLE led_TT THEN
        DO:
            CREATE ttLedTT.
            CopyToTt( BUFFER led_TT, BUFFER ttLedTT ).
        END.

        RETURN TEMP-TABLE ttLedTT:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new led_TT row.
        Errors : AppError 404 - artnr not found in artikel.
                 AppError 409 - the artnr/onderdeel combo already exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLedTT.

        IF NOT ArtikelExists(pcArtnr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("artikel &1 not found":u, pcArtnr), 404).

        DO TRANSACTION:
            FIND FIRST led_TT EXCLUSIVE-LOCK WHERE led_TT.artnr EQ pcArtnr AND led_TT.onderdeel EQ pcOnderdeel NO-ERROR.
            IF AVAILABLE led_TT THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_TT &1/&2 already exists":u, pcArtnr, pcOnderdeel), 409).

            CREATE led_TT.
            ASSIGN
                led_TT.artnr     = pcArtnr
                led_TT.onderdeel = pcOnderdeel
                .
            ApplyFields( INPUT poBody, BUFFER led_TT ).

            CREATE ttLedTT.
            CopyToTt( BUFFER led_TT, BUFFER ttLedTT ).
        END.

        RETURN TEMP-TABLE ttLedTT:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing led_TT row (tt only - the key is immutable).
        Errors : AppError 404 - row not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLedTT.

        DO TRANSACTION:
            FIND FIRST led_TT EXCLUSIVE-LOCK WHERE led_TT.artnr EQ pcArtnr AND led_TT.onderdeel EQ pcOnderdeel NO-ERROR.
            IF NOT AVAILABLE led_TT THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_TT &1/&2 not found":u, pcArtnr, pcOnderdeel), 404).

            ApplyFields( INPUT poBody, BUFFER led_TT ).

            CREATE ttLedTT.
            CopyToTt( BUFFER led_TT, BUFFER ttLedTT ).
        END.

        RETURN TEMP-TABLE ttLedTT:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeleteItem( INPUT pcArtnr AS CHARACTER, INPUT pcOnderdeel AS CHARACTER ):

        DO TRANSACTION:
            FIND FIRST led_TT EXCLUSIVE-LOCK WHERE led_TT.artnr EQ pcArtnr AND led_TT.onderdeel EQ pcOnderdeel NO-ERROR.
            IF NOT AVAILABLE led_TT THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_TT &1/&2 not found":u, pcArtnr, pcOnderdeel), 404).

            DELETE led_TT.
        END.

    END METHOD.

END CLASS. 
