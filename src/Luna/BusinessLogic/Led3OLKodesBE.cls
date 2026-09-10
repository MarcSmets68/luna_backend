/*------------------------------------------------------------------------
    File        : Led3OLKodesBE.cls
    Purpose     : Business Entity for led_3OL_kodes. NO-LOCK reads,
                  EXCLUSIVE-LOCK in a transaction for writes.
    Field map   : kode               -> kode                (PK, char(15))
                  artnr              -> artnr                (char(50), validated against artikel.artnr)
                  comp               -> comp                 (char(1))
                  excelKode          -> Excel-kode            (char(15))
                  samenstellingKode  -> Samenstelling-kode     (char(40))
    Author(s)   : Devin
    Created     : 2026-08-29
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.Led3OLKodesBE:

    DEFINE TEMP-TABLE ttLed3OLKodes NO-UNDO SERIALIZE-NAME "items":u
        FIELD kode              AS CHARACTER SERIALIZE-NAME "kode":u
        FIELD artnr              AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD comp                AS CHARACTER SERIALIZE-NAME "comp":u
        FIELD excelKode           AS CHARACTER SERIALIZE-NAME "excelKode":u
        FIELD samenstellingKode   AS CHARACTER SERIALIZE-NAME "samenstellingKode":u
        INDEX idx-kode IS PRIMARY kode.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_3OL_kodes, BUFFER pbTt FOR ttLed3OLKodes ):
        ASSIGN
            pbTt.kode              = pbSrc.kode
            pbTt.artnr             = pbSrc.artnr
            pbTt.comp              = pbSrc.comp
            pbTt.excelKode         = pbSrc.Excel-kode
            pbTt.samenstellingKode = pbSrc.Samenstelling-kode
            .
    END METHOD.

    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbRow FOR led_3OL_kodes ):
        IF poBody:Has("comp":u)              THEN pbRow.comp               = poBody:GetCharacter("comp":u).
        IF poBody:Has("excelKode":u)          THEN pbRow.Excel-kode         = poBody:GetCharacter("excelKode":u).
        IF poBody:Has("samenstellingKode":u)  THEN pbRow.Samenstelling-kode = poBody:GetCharacter("samenstellingKode":u).
    END METHOD.

    METHOD PRIVATE LOGICAL ArtikelExists( INPUT pcArtnr AS CHARACTER ):
        FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.
        RETURN AVAILABLE artikel.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of led_3OL_kodes rows, optionally filtered
                 by kode (exact) / kodePrefix (BEGINS) and/or artnr (exact).
        Notes  : NO-LOCK read-only. kode BEGINS drives the unique
                 led_3OL_kodes-x1 index range scan; artnr (when supplied,
                 without a kode/kodePrefix) falls back to the
                 led_3OL_kodes-x2 index via a per-row filter.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetItems(
        INPUT  piPage        AS INTEGER,
        INPUT  piPageSize     AS INTEGER,
        INPUT  pcKode         AS CHARACTER,
        INPUT  pcKodePrefix   AS CHARACTER,
        INPUT  pcArtnr        AS CHARACTER,
        OUTPUT plHasMore      AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cScan  AS CHARACTER NO-UNDO.

        EMPTY TEMP-TABLE ttLed3OLKodes.

        ASSIGN
            pcKode       = TRIM(pcKode)
            pcKodePrefix = TRIM(pcKodePrefix)
            pcArtnr      = TRIM(pcArtnr)
            cScan        = (IF pcKode NE "":u THEN pcKode ELSE pcKodePrefix)
            iSkip        = (piPage - 1) * piPageSize
            iSeen        = 0
            iTaken       = 0
            plHasMore    = FALSE
            .

        FOR EACH led_3OL_kodes NO-LOCK WHERE led_3OL_kodes.kode BEGINS cScan BY led_3OL_kodes.kode:

            IF pcKode NE "":u AND led_3OL_kodes.kode NE pcKode THEN NEXT.
            IF pcArtnr NE "":u AND led_3OL_kodes.artnr NE pcArtnr THEN NEXT.

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLed3OLKodes.
            CopyToTt( BUFFER led_3OL_kodes, BUFFER ttLed3OLKodes ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLed3OLKodes:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetItem( INPUT pcKode AS CHARACTER ):

        EMPTY TEMP-TABLE ttLed3OLKodes.

        FIND FIRST led_3OL_kodes NO-LOCK WHERE led_3OL_kodes.kode EQ pcKode NO-ERROR.

        IF AVAILABLE led_3OL_kodes THEN
        DO:
            CREATE ttLed3OLKodes.
            CopyToTt( BUFFER led_3OL_kodes, BUFFER ttLed3OLKodes ).
        END.

        RETURN TEMP-TABLE ttLed3OLKodes:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new led_3OL_kodes row.
        Errors : AppError 404 - artnr not found in artikel.
                 AppError 409 - kode already exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateItem( INPUT pcKode AS CHARACTER, INPUT pcArtnr AS CHARACTER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLed3OLKodes.

        IF NOT ArtikelExists(pcArtnr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("artikel &1 not found":u, pcArtnr), 404).

        DO TRANSACTION:
            FIND FIRST led_3OL_kodes EXCLUSIVE-LOCK WHERE led_3OL_kodes.kode EQ pcKode NO-ERROR.
            IF AVAILABLE led_3OL_kodes THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_3OL_kodes &1 already exists":u, pcKode), 409).

            CREATE led_3OL_kodes.
            ASSIGN
                led_3OL_kodes.kode  = pcKode
                led_3OL_kodes.artnr = pcArtnr
                .
            ApplyFields( INPUT poBody, BUFFER led_3OL_kodes ).

            CREATE ttLed3OLKodes.
            CopyToTt( BUFFER led_3OL_kodes, BUFFER ttLed3OLKodes ).
        END.

        RETURN TEMP-TABLE ttLed3OLKodes:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing led_3OL_kodes row (artnr/comp/
                 excelKode/samenstellingKode - kode is immutable).
        Errors : AppError 404 - kode not found, or the new artnr (if
                 supplied) doesn't exist in artikel.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateItem( INPUT pcKode AS CHARACTER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLed3OLKodes.

        IF poBody:Has("artnr":u) AND TRIM(poBody:GetCharacter("artnr":u)) NE "":u
            AND NOT ArtikelExists(poBody:GetCharacter("artnr":u)) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("artikel &1 not found":u, poBody:GetCharacter("artnr":u)), 404).

        DO TRANSACTION:
            FIND FIRST led_3OL_kodes EXCLUSIVE-LOCK WHERE led_3OL_kodes.kode EQ pcKode NO-ERROR.
            IF NOT AVAILABLE led_3OL_kodes THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_3OL_kodes &1 not found":u, pcKode), 404).

            IF poBody:Has("artnr":u) THEN led_3OL_kodes.artnr = poBody:GetCharacter("artnr":u).
            ApplyFields( INPUT poBody, BUFFER led_3OL_kodes ).

            CREATE ttLed3OLKodes.
            CopyToTt( BUFFER led_3OL_kodes, BUFFER ttLed3OLKodes ).
        END.

        RETURN TEMP-TABLE ttLed3OLKodes:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeleteItem( INPUT pcKode AS CHARACTER ):

        DO TRANSACTION:
            FIND FIRST led_3OL_kodes EXCLUSIVE-LOCK WHERE led_3OL_kodes.kode EQ pcKode NO-ERROR.
            IF NOT AVAILABLE led_3OL_kodes THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_3OL_kodes &1 not found":u, pcKode), 404).

            DELETE led_3OL_kodes.
        END.

    END METHOD.

END CLASS. 
