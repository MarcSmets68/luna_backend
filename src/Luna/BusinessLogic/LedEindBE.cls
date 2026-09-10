/*------------------------------------------------------------------------
    File        : LedEindBE.cls
    Purpose     : Business Entity for led_eind. NO-LOCK reads,
                  EXCLUSIVE-LOCK in a transaction for writes.
    Field map   : eind    -> eind    (char(50))
                  profiel -> profiel (char(50))
                  cover   -> cover   (char(50))
    Notes       : led_eind-x1 (eind/profiel/cover) is NOT declared unique in
                  the live schema, even though eind+profiel+cover is treated
                  as unique in practice - so every key lookup here counts
                  matches first: 0 -> 404, 1 -> proceed, >1 -> 409 ("multiple
                  rows match, data integrity issue"). The same count also
                  doubles as the duplicate-key guard on create. No
                  referential validation - none of eind/profiel/cover
                  reference another table.
    Author(s)   : Devin
    Created     : 2026-08-29
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LedEindBE:

    DEFINE TEMP-TABLE ttLedEind NO-UNDO SERIALIZE-NAME "items":u
        FIELD eind    AS CHARACTER SERIALIZE-NAME "eind":u
        FIELD profiel AS CHARACTER SERIALIZE-NAME "profiel":u
        FIELD cover   AS CHARACTER SERIALIZE-NAME "cover":u
        INDEX idx-key IS PRIMARY eind profiel cover.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_eind, BUFFER pbTt FOR ttLedEind ):
        ASSIGN
            pbTt.eind    = pbSrc.eind
            pbTt.profiel = pbSrc.profiel
            pbTt.cover   = pbSrc.cover
            .
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Counts led_eind rows matching the given key - used by every
                 GET/UPDATE/DELETE/CREATE-duplicate-check below since the
                 combo isn't declared unique at the DB level.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER CountMatchingEindRows( INPUT pcEind AS CHARACTER, INPUT pcProfiel AS CHARACTER, INPUT pcCover AS CHARACTER ):

        DEFINE VARIABLE iCount AS INTEGER NO-UNDO INITIAL 0.

        FOR EACH led_eind NO-LOCK
            WHERE led_eind.eind    EQ pcEind
              AND led_eind.profiel EQ pcProfiel
              AND led_eind.cover   EQ pcCover:
            iCount = iCount + 1.
        END.

        RETURN iCount.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of led_eind rows, optionally filtered by
                 eind (exact) / eindPrefix (BEGINS).
        Notes  : NO-LOCK read-only. Small lookup table, no scan-depth cap needed.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetItems(
        INPUT  piPage       AS INTEGER,
        INPUT  piPageSize    AS INTEGER,
        INPUT  pcEind        AS CHARACTER,
        INPUT  pcEindPrefix  AS CHARACTER,
        OUTPUT plHasMore     AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cScan  AS CHARACTER NO-UNDO.

        EMPTY TEMP-TABLE ttLedEind.

        ASSIGN
            pcEind       = TRIM(pcEind)
            pcEindPrefix = TRIM(pcEindPrefix)
            cScan        = (IF pcEind NE "":u THEN pcEind ELSE pcEindPrefix)
            iSkip        = (piPage - 1) * piPageSize
            iSeen        = 0
            iTaken       = 0
            plHasMore    = FALSE
            .

        FOR EACH led_eind NO-LOCK WHERE led_eind.eind BEGINS cScan BY led_eind.eind BY led_eind.profiel BY led_eind.cover:

            IF pcEind NE "":u AND led_eind.eind NE pcEind THEN NEXT.

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLedEind.
            CopyToTt( BUFFER led_eind, BUFFER ttLedEind ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLedEind:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns the single led_eind row matching the key.
        Errors : AppError 409 - more than one row matches (data integrity issue).
        Notes  : 0 matches simply returns an empty result (the WebHandler
                 turns that into a 404), same convention as every other table.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetItem( INPUT pcEind AS CHARACTER, INPUT pcProfiel AS CHARACTER, INPUT pcCover AS CHARACTER ):

        DEFINE VARIABLE iCount AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttLedEind.

        iCount = CountMatchingEindRows(pcEind, pcProfiel, pcCover).

        IF iCount GT 1 THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("led_eind &1/&2/&3: multiple rows match, data integrity issue":u, pcEind, pcProfiel, pcCover), 409).

        IF iCount EQ 1 THEN
        DO:
            FIND FIRST led_eind NO-LOCK
                WHERE led_eind.eind EQ pcEind AND led_eind.profiel EQ pcProfiel AND led_eind.cover EQ pcCover
                NO-ERROR.
            CREATE ttLedEind.
            CopyToTt( BUFFER led_eind, BUFFER ttLedEind ).
        END.

        RETURN TEMP-TABLE ttLedEind:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new led_eind row.
        Errors : AppError 409 - the eind/profiel/cover combo already exists
                 (1+ rows), or a concurrent duplicate check found >1.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateItem( INPUT pcEind AS CHARACTER, INPUT pcProfiel AS CHARACTER, INPUT pcCover AS CHARACTER ):

        EMPTY TEMP-TABLE ttLedEind.

        DO TRANSACTION:
            IF CountMatchingEindRows(pcEind, pcProfiel, pcCover) GT 0 THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_eind &1/&2/&3 already exists":u, pcEind, pcProfiel, pcCover), 409).

            CREATE led_eind.
            ASSIGN
                led_eind.eind    = pcEind
                led_eind.profiel = pcProfiel
                led_eind.cover   = pcCover
                .

            CREATE ttLedEind.
            CopyToTt( BUFFER led_eind, BUFFER ttLedEind ).
        END.

        RETURN TEMP-TABLE ttLedEind:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: "Updates" a led_eind row. The table has no fields besides
                 its 3-part key, which is immutable via PUT - so this just
                 re-confirms the key resolves to exactly one row and returns it.
        Errors : AppError 404 - no match. AppError 409 - multiple rows match.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateItem( INPUT pcEind AS CHARACTER, INPUT pcProfiel AS CHARACTER, INPUT pcCover AS CHARACTER ):

        DEFINE VARIABLE iCount AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttLedEind.

        iCount = CountMatchingEindRows(pcEind, pcProfiel, pcCover).

        IF iCount EQ 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("led_eind &1/&2/&3 not found":u, pcEind, pcProfiel, pcCover), 404).

        IF iCount GT 1 THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("led_eind &1/&2/&3: multiple rows match, data integrity issue":u, pcEind, pcProfiel, pcCover), 409).

        FIND FIRST led_eind NO-LOCK
            WHERE led_eind.eind EQ pcEind AND led_eind.profiel EQ pcProfiel AND led_eind.cover EQ pcCover
            NO-ERROR.
        CREATE ttLedEind.
        CopyToTt( BUFFER led_eind, BUFFER ttLedEind ).

        RETURN TEMP-TABLE ttLedEind:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes the led_eind row matching the key.
        Errors : AppError 404 - no match. AppError 409 - multiple rows match.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteItem( INPUT pcEind AS CHARACTER, INPUT pcProfiel AS CHARACTER, INPUT pcCover AS CHARACTER ):

        DEFINE VARIABLE iCount AS INTEGER NO-UNDO.

        DO TRANSACTION:
            iCount = CountMatchingEindRows(pcEind, pcProfiel, pcCover).

            IF iCount EQ 0 THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_eind &1/&2/&3 not found":u, pcEind, pcProfiel, pcCover), 404).

            IF iCount GT 1 THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_eind &1/&2/&3: multiple rows match, data integrity issue":u, pcEind, pcProfiel, pcCover), 409).

            FIND FIRST led_eind EXCLUSIVE-LOCK
                WHERE led_eind.eind EQ pcEind AND led_eind.profiel EQ pcProfiel AND led_eind.cover EQ pcCover
                NO-ERROR.
            DELETE led_eind.
        END.

    END METHOD.

END CLASS. 
