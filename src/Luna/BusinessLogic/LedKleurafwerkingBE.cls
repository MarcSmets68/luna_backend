/*------------------------------------------------------------------------
    File        : LedKleurafwerkingBE.cls
    Purpose     : Business Entity for led_kleurafwerking (kleurafwerkingen,
                  15 rijen). Full CRUD, NO-LOCK reads, EXCLUSIVE-LOCK in a
                  transaction for writes. Added as the 10th LED
                  reference-data table (see
                  docs/architecture/coating-fase1-afronding-ontwerp.md
                  sectie 7) to expose the pre-existing `standaard` flag
                  (Punt 6 / FR-15/16/17) - no schema change was needed,
                  this field already existed and was simply unontsloten.
    Field map   : kleursoort -> kleursoort (PK1, char 5, FK-validated
                                against led_kleursoort.kode on create)
                  kode       -> kode       (PK2, char 5)
                  omschr     -> omschr     (char 30, writable)
                  standaard  -> standaard  (logical, default no, writable)
    Delete-block check performed: searched docs/database-analysis.md and
                  docs/db-analysis/schema_dump.txt for any other table with
                  a field referencing led_kleurafwerking's key
                  (kleursoort+kode) - none found. DELETE is therefore NOT
                  blocked (no known FK-referencing table exists), unlike
                  led_kenmerk's block-on-delete precedent.
    Author(s)   : Devin (backend-coder)
    Created     : 2026-09-20
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LedKleurafwerkingBE:

    DEFINE TEMP-TABLE ttLedKleurafwerking NO-UNDO SERIALIZE-NAME "items":u
        FIELD kleursoort AS CHARACTER SERIALIZE-NAME "kleursoort":u
        FIELD kode       AS CHARACTER SERIALIZE-NAME "kode":u
        FIELD omschr     AS CHARACTER SERIALIZE-NAME "omschr":u
        FIELD standaard  AS LOGICAL   SERIALIZE-NAME "standaard":u
        INDEX idx-key IS PRIMARY kleursoort kode.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_kleurafwerking, BUFFER pbTt FOR ttLedKleurafwerking ):
        ASSIGN
            pbTt.kleursoort = pbSrc.kleursoort
            pbTt.kode       = pbSrc.kode
            pbTt.omschr     = pbSrc.omschr
            pbTt.standaard  = pbSrc.standaard
            .
    END METHOD.

    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbRow FOR led_kleurafwerking ):
        IF poBody:Has("omschr":u)    THEN pbRow.omschr    = poBody:GetCharacter("omschr":u).
        IF poBody:Has("standaard":u) THEN pbRow.standaard = poBody:GetLogical("standaard":u).
    END METHOD.

    METHOD PRIVATE LOGICAL KleursoortExists( INPUT pcKleursoort AS CHARACTER ):
        FIND FIRST led_kleursoort NO-LOCK WHERE led_kleursoort.kode EQ pcKleursoort NO-ERROR.
        RETURN AVAILABLE led_kleursoort.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of led_kleurafwerking rows, optionally
                 filtered by kleursoort (exact) and/or standaard (true/false).
        Notes  : NO-LOCK read-only. Only 15 rows in total - no scan-depth
                 cap needed.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetItems(
        INPUT  piPage        AS INTEGER,
        INPUT  piPageSize     AS INTEGER,
        INPUT  pcKleursoort   AS CHARACTER,
        INPUT  pcStandaard    AS CHARACTER,
        OUTPUT plHasMore      AS LOGICAL ):

        DEFINE VARIABLE iSkip        AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen        AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken       AS INTEGER NO-UNDO.
        DEFINE VARIABLE lFilterStd   AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lHasStdFilter AS LOGICAL NO-UNDO.

        EMPTY TEMP-TABLE ttLedKleurafwerking.

        ASSIGN
            pcKleursoort   = TRIM(pcKleursoort)
            iSkip          = (piPage - 1) * piPageSize
            iSeen          = 0
            iTaken         = 0
            plHasMore      = FALSE
            lHasStdFilter  = (pcStandaard EQ "true":u OR pcStandaard EQ "false":u)
            lFilterStd     = (pcStandaard EQ "true":u)
            .

        FOR EACH led_kleurafwerking NO-LOCK
            WHERE led_kleurafwerking.kleursoort BEGINS pcKleursoort
            BY led_kleurafwerking.kleursoort BY led_kleurafwerking.kode:

            IF lHasStdFilter AND led_kleurafwerking.standaard NE lFilterStd THEN NEXT.

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLedKleurafwerking.
            CopyToTt( BUFFER led_kleurafwerking, BUFFER ttLedKleurafwerking ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLedKleurafwerking:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetItem( INPUT pcKleursoort AS CHARACTER, INPUT pcKode AS CHARACTER ):

        EMPTY TEMP-TABLE ttLedKleurafwerking.

        FIND FIRST led_kleurafwerking NO-LOCK
            WHERE led_kleurafwerking.kleursoort EQ pcKleursoort
              AND led_kleurafwerking.kode       EQ pcKode
            NO-ERROR.

        IF AVAILABLE led_kleurafwerking THEN
        DO:
            CREATE ttLedKleurafwerking.
            CopyToTt( BUFFER led_kleurafwerking, BUFFER ttLedKleurafwerking ).
        END.

        RETURN TEMP-TABLE ttLedKleurafwerking:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new led_kleurafwerking row.
        Errors : AppError 404 - kleursoort not found in led_kleursoort.
                 AppError 409 - the key combo already exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateItem(
        INPUT pcKleursoort AS CHARACTER, INPUT pcKode AS CHARACTER,
        INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLedKleurafwerking.

        IF NOT KleursoortExists(pcKleursoort) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_kleursoort &1 not found":u, pcKleursoort), 404).

        DO TRANSACTION:
            FIND FIRST led_kleurafwerking EXCLUSIVE-LOCK
                WHERE led_kleurafwerking.kleursoort EQ pcKleursoort
                  AND led_kleurafwerking.kode       EQ pcKode
                NO-ERROR.
            IF AVAILABLE led_kleurafwerking THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_kleurafwerking &1/&2 already exists":u, pcKleursoort, pcKode), 409).

            CREATE led_kleurafwerking.
            ASSIGN
                led_kleurafwerking.kleursoort = pcKleursoort
                led_kleurafwerking.kode       = pcKode
                .
            ApplyFields( INPUT poBody, BUFFER led_kleurafwerking ).

            CREATE ttLedKleurafwerking.
            CopyToTt( BUFFER led_kleurafwerking, BUFFER ttLedKleurafwerking ).
        END.

        RETURN TEMP-TABLE ttLedKleurafwerking:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing led_kleurafwerking row (omschr /
                 standaard only - the key is immutable).
        Errors : AppError 404 - row not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateItem(
        INPUT pcKleursoort AS CHARACTER, INPUT pcKode AS CHARACTER,
        INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLedKleurafwerking.

        DO TRANSACTION:
            FIND FIRST led_kleurafwerking EXCLUSIVE-LOCK
                WHERE led_kleurafwerking.kleursoort EQ pcKleursoort
                  AND led_kleurafwerking.kode       EQ pcKode
                NO-ERROR.
            IF NOT AVAILABLE led_kleurafwerking THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_kleurafwerking &1/&2 not found":u, pcKleursoort, pcKode), 404).

            ApplyFields( INPUT poBody, BUFFER led_kleurafwerking ).

            CREATE ttLedKleurafwerking.
            CopyToTt( BUFFER led_kleurafwerking, BUFFER ttLedKleurafwerking ).
        END.

        RETURN TEMP-TABLE ttLedKleurafwerking:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a led_kleurafwerking row. No referential block:
                 no other table's field referencing this table's key was
                 found (see class header) - unlike led_kenmerk.
        Errors : AppError 404 - row not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteItem( INPUT pcKleursoort AS CHARACTER, INPUT pcKode AS CHARACTER ):

        DO TRANSACTION:
            FIND FIRST led_kleurafwerking EXCLUSIVE-LOCK
                WHERE led_kleurafwerking.kleursoort EQ pcKleursoort
                  AND led_kleurafwerking.kode       EQ pcKode
                NO-ERROR.
            IF NOT AVAILABLE led_kleurafwerking THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_kleurafwerking &1/&2 not found":u, pcKleursoort, pcKode), 404).

            DELETE led_kleurafwerking.
        END.

    END METHOD.

END CLASS.
