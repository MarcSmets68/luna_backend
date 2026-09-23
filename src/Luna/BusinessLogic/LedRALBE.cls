/*------------------------------------------------------------------------
    File        : LedRALBE.cls
    Purpose     : Business Entity for led_RAL (RAL kleuren, 216 rijen).
                  Read-only - GetItems/GetItem only, NO-LOCK. No CRUD-writes:
                  led_RAL is an industry-standard reference table (RAL color
                  system), not editable through this API per architect
                  decision (coating-fase1-afronding-ontwerp.md sectie 2.1) -
                  FR-4/FR-5 only need lookup/validate/display, no create/
                  update/delete need was raised.
    Field map   : ral          -> ral          (PK, integer)
                  omschrijving -> omschrijving (char 30)
                  hexKleur     -> hexKleur     (char 6)
                  rgbWaarde    -> rgbWaarde    (char 11)
    Author(s)   : Devin (backend-coder)
    Created     : 2026-09-20
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LedRALBE:

    DEFINE TEMP-TABLE ttLedRAL NO-UNDO SERIALIZE-NAME "items":u
        FIELD ral          AS INTEGER   SERIALIZE-NAME "ral":u
        FIELD omschrijving AS CHARACTER SERIALIZE-NAME "omschrijving":u
        FIELD hexKleur     AS CHARACTER SERIALIZE-NAME "hexKleur":u
        FIELD rgbWaarde    AS CHARACTER SERIALIZE-NAME "rgbWaarde":u
        INDEX idx-ral IS PRIMARY ral.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_RAL, BUFFER pbTt FOR ttLedRAL ):
        ASSIGN
            pbTt.ral          = pbSrc.ral
            pbTt.omschrijving = pbSrc.omschrijving
            pbTt.hexKleur     = pbSrc.hexKleur
            pbTt.rgbWaarde    = pbSrc.rgbWaarde
            .
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of led_RAL rows, optionally filtered by
                 omschrijvingPrefix (BEGINS match on omschrijving).
        Notes  : NO-LOCK read-only. Small lookup table (216 rows) - the
                 page/skip windowing avoids materializing more than one
                 page + 1 lookahead row into the temp-table.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetItems(
        INPUT  piPage               AS INTEGER,
        INPUT  piPageSize           AS INTEGER,
        INPUT  pcOmschrijvingPrefix AS CHARACTER,
        OUTPUT plHasMore            AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttLedRAL.

        ASSIGN
            pcOmschrijvingPrefix = TRIM(pcOmschrijvingPrefix)
            iSkip                = (piPage - 1) * piPageSize
            iSeen                = 0
            iTaken               = 0
            plHasMore            = FALSE
            .

        FOR EACH led_RAL NO-LOCK
            WHERE led_RAL.omschrijving BEGINS pcOmschrijvingPrefix
            BY led_RAL.ral:

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLedRAL.
            CopyToTt( BUFFER led_RAL, BUFFER ttLedRAL ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLedRAL:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetItem( INPUT piRal AS INTEGER ):

        EMPTY TEMP-TABLE ttLedRAL.

        FIND FIRST led_RAL NO-LOCK WHERE led_RAL.ral EQ piRal NO-ERROR.

        IF AVAILABLE led_RAL THEN
        DO:
            CREATE ttLedRAL.
            CopyToTt( BUFFER led_RAL, BUFFER ttLedRAL ).
        END.

        RETURN TEMP-TABLE ttLedRAL:HANDLE.

    END METHOD.

END CLASS.