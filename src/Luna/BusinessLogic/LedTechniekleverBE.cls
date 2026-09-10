/*------------------------------------------------------------------------
    File        : LedTechniekleverBE.cls
    Purpose     : Business Entity for led_technieklever (kleurtechnieken
                  per leverancier). NO-LOCK reads, EXCLUSIVE-LOCK in a
                  transaction for writes.
    Field map   : laktechniek     -> laktechniek     (PK1, char(5))
                  kleursoort      -> kleursoort       (PK2, char(5))
                  ledType         -> led-type         (PK3, char(20), default "Geen")
                  levnr           -> levnr             (PK4, integer, validated against lever.levnr)
                  instelkost      -> instelkost        (decimal)
                  kleursupplement -> kleursupplement   (char(50))
    Author(s)   : Devin
    Created     : 2026-08-29
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LedTechniekleverBE:

    DEFINE TEMP-TABLE ttLedTechnieklever NO-UNDO SERIALIZE-NAME "items":u
        FIELD laktechniek     AS CHARACTER SERIALIZE-NAME "laktechniek":u
        FIELD kleursoort      AS CHARACTER SERIALIZE-NAME "kleursoort":u
        FIELD ledType         AS CHARACTER SERIALIZE-NAME "ledType":u
        FIELD levnr           AS INTEGER   SERIALIZE-NAME "levnr":u
        FIELD instelkost      AS DECIMAL   SERIALIZE-NAME "instelkost":u
        FIELD kleursupplement AS CHARACTER SERIALIZE-NAME "kleursupplement":u
        INDEX idx-key IS PRIMARY laktechniek kleursoort ledType levnr.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_technieklever, BUFFER pbTt FOR ttLedTechnieklever ):
        ASSIGN
            pbTt.laktechniek     = pbSrc.laktechniek
            pbTt.kleursoort      = pbSrc.kleursoort
            pbTt.ledType         = pbSrc.led-type
            pbTt.levnr           = pbSrc.levnr
            pbTt.instelkost      = pbSrc.instelkost
            pbTt.kleursupplement = pbSrc.kleursupplement
            .
    END METHOD.

    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbRow FOR led_technieklever ):
        IF poBody:Has("instelkost":u)      THEN pbRow.instelkost      = poBody:GetDecimal("instelkost":u).
        IF poBody:Has("kleursupplement":u) THEN pbRow.kleursupplement = poBody:GetCharacter("kleursupplement":u).
    END METHOD.

    METHOD PRIVATE LOGICAL LevnrExists( INPUT piLevnr AS INTEGER ):
        FIND FIRST lever NO-LOCK WHERE lever.levnr EQ piLevnr NO-ERROR.
        RETURN AVAILABLE lever.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of led_technieklever rows, optionally
                 filtered by laktechniek (exact) and/or levnr (exact).
        Notes  : NO-LOCK read-only. Small lookup table, no scan-depth cap needed.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetItems(
        INPUT  piPage        AS INTEGER,
        INPUT  piPageSize     AS INTEGER,
        INPUT  pcLaktechniek  AS CHARACTER,
        INPUT  piLevnr        AS INTEGER,
        OUTPUT plHasMore      AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttLedTechnieklever.

        ASSIGN
            pcLaktechniek = TRIM(pcLaktechniek)
            iSkip         = (piPage - 1) * piPageSize
            iSeen         = 0
            iTaken        = 0
            plHasMore     = FALSE
            .

        FOR EACH led_technieklever NO-LOCK
            WHERE led_technieklever.laktechniek BEGINS pcLaktechniek
            BY led_technieklever.laktechniek BY led_technieklever.kleursoort
            BY led_technieklever.led-type BY led_technieklever.levnr:

            IF piLevnr NE 0 AND led_technieklever.levnr NE piLevnr THEN NEXT.

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLedTechnieklever.
            CopyToTt( BUFFER led_technieklever, BUFFER ttLedTechnieklever ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLedTechnieklever:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetItem(
        INPUT pcLaktechniek AS CHARACTER, INPUT pcKleursoort AS CHARACTER,
        INPUT pcLedType AS CHARACTER, INPUT piLevnr AS INTEGER ):

        EMPTY TEMP-TABLE ttLedTechnieklever.

        FIND FIRST led_technieklever NO-LOCK
            WHERE led_technieklever.laktechniek EQ pcLaktechniek
              AND led_technieklever.kleursoort  EQ pcKleursoort
              AND led_technieklever.led-type    EQ pcLedType
              AND led_technieklever.levnr       EQ piLevnr
            NO-ERROR.

        IF AVAILABLE led_technieklever THEN
        DO:
            CREATE ttLedTechnieklever.
            CopyToTt( BUFFER led_technieklever, BUFFER ttLedTechnieklever ).
        END.

        RETURN TEMP-TABLE ttLedTechnieklever:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new led_technieklever row.
        Errors : AppError 404 - levnr not found in lever.
                 AppError 409 - the key combo already exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateItem(
        INPUT pcLaktechniek AS CHARACTER, INPUT pcKleursoort AS CHARACTER,
        INPUT pcLedType AS CHARACTER, INPUT piLevnr AS INTEGER,
        INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLedTechnieklever.

        /* Business rule: led-type defaults to "Geen" (matches the DB default)
           when the caller does not supply a non-blank value. This decision
           belongs here, not in any calling WebHandler. */
        IF TRIM(pcLedType) EQ "":u THEN
            pcLedType = "Geen":u.

        IF NOT LevnrExists(piLevnr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("lever &1 not found":u, piLevnr), 404).

        DO TRANSACTION:
            FIND FIRST led_technieklever EXCLUSIVE-LOCK
                WHERE led_technieklever.laktechniek EQ pcLaktechniek
                  AND led_technieklever.kleursoort  EQ pcKleursoort
                  AND led_technieklever.led-type    EQ pcLedType
                  AND led_technieklever.levnr       EQ piLevnr
                NO-ERROR.
            IF AVAILABLE led_technieklever THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_technieklever &1/&2/&3/&4 already exists":u, pcLaktechniek, pcKleursoort, pcLedType, piLevnr), 409).

            CREATE led_technieklever.
            ASSIGN
                led_technieklever.laktechniek = pcLaktechniek
                led_technieklever.kleursoort  = pcKleursoort
                led_technieklever.led-type    = pcLedType
                led_technieklever.levnr       = piLevnr
                .
            ApplyFields( INPUT poBody, BUFFER led_technieklever ).

            CREATE ttLedTechnieklever.
            CopyToTt( BUFFER led_technieklever, BUFFER ttLedTechnieklever ).
        END.

        RETURN TEMP-TABLE ttLedTechnieklever:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing led_technieklever row (instelkost /
                 kleursupplement only - the key is immutable).
        Errors : AppError 404 - row not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateItem(
        INPUT pcLaktechniek AS CHARACTER, INPUT pcKleursoort AS CHARACTER,
        INPUT pcLedType AS CHARACTER, INPUT piLevnr AS INTEGER,
        INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLedTechnieklever.

        DO TRANSACTION:
            FIND FIRST led_technieklever EXCLUSIVE-LOCK
                WHERE led_technieklever.laktechniek EQ pcLaktechniek
                  AND led_technieklever.kleursoort  EQ pcKleursoort
                  AND led_technieklever.led-type    EQ pcLedType
                  AND led_technieklever.levnr       EQ piLevnr
                NO-ERROR.
            IF NOT AVAILABLE led_technieklever THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_technieklever &1/&2/&3/&4 not found":u, pcLaktechniek, pcKleursoort, pcLedType, piLevnr), 404).

            ApplyFields( INPUT poBody, BUFFER led_technieklever ).

            CREATE ttLedTechnieklever.
            CopyToTt( BUFFER led_technieklever, BUFFER ttLedTechnieklever ).
        END.

        RETURN TEMP-TABLE ttLedTechnieklever:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeleteItem(
        INPUT pcLaktechniek AS CHARACTER, INPUT pcKleursoort AS CHARACTER,
        INPUT pcLedType AS CHARACTER, INPUT piLevnr AS INTEGER ):

        DO TRANSACTION:
            FIND FIRST led_technieklever EXCLUSIVE-LOCK
                WHERE led_technieklever.laktechniek EQ pcLaktechniek
                  AND led_technieklever.kleursoort  EQ pcKleursoort
                  AND led_technieklever.led-type    EQ pcLedType
                  AND led_technieklever.levnr       EQ piLevnr
                NO-ERROR.
            IF NOT AVAILABLE led_technieklever THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_technieklever &1/&2/&3/&4 not found":u, pcLaktechniek, pcKleursoort, pcLedType, piLevnr), 404).

            DELETE led_technieklever.
        END.

    END METHOD.

END CLASS. 
