/*------------------------------------------------------------------------
    File        : LedNCSBE.cls
    Purpose     : Business Entity for led_NCS (NCS kleuren, 1950 rijen).
                  Read-only - GetItems/GetItem only, NO-LOCK. No CRUD-writes:
                  led_NCS is an industry-standard reference table (NCS color
                  system), not editable through this API per architect
                  decision (coating-fase1-afronding-ontwerp.md sectie 2.2) -
                  FR-4/FR-5 only need lookup/validate/display, no create/
                  update/delete need was raised.
    Field map   : ncs          -> ncs          (PK, char 11, e.g. "S 0500-N")
                  omschrijving -> omschrijving (char 30)
                  hexKleur     -> hexKleur     (char 6)
                  rgbWaarde    -> rgbWaarde    (char 11)
    Author(s)   : Devin (backend-coder)
    Created     : 2026-09-20
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LedNCSBE:

    DEFINE TEMP-TABLE ttLedNCS NO-UNDO SERIALIZE-NAME "items":u
        FIELD ncs          AS CHARACTER SERIALIZE-NAME "ncs":u
        FIELD omschrijving AS CHARACTER SERIALIZE-NAME "omschrijving":u
        FIELD hexKleur     AS CHARACTER SERIALIZE-NAME "hexKleur":u
        FIELD rgbWaarde    AS CHARACTER SERIALIZE-NAME "rgbWaarde":u
        INDEX idx-ncs IS PRIMARY ncs.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_NCS, BUFFER pbTt FOR ttLedNCS ):
        ASSIGN
            pbTt.ncs          = pbSrc.ncs
            pbTt.omschrijving = pbSrc.omschrijving
            pbTt.hexKleur     = pbSrc.hexKleur
            pbTt.rgbWaarde    = pbSrc.rgbWaarde
            .
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of led_NCS rows, optionally filtered by
                 omschrijvingPrefix (BEGINS match on omschrijving).
        Notes  : NO-LOCK read-only. 1950 rows - page/skip windowing avoids
                 materializing more than one page + 1 lookahead row into
                 the temp-table. No pushdown onto an omschrijving index is
                 needed at this row count (unlike led_auteur's ~536K rows).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetItems(
        INPUT  piPage               AS INTEGER,
        INPUT  piPageSize           AS INTEGER,
        INPUT  pcOmschrijvingPrefix AS CHARACTER,
        OUTPUT plHasMore            AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttLedNCS.

        ASSIGN
            pcOmschrijvingPrefix = TRIM(pcOmschrijvingPrefix)
            iSkip                = (piPage - 1) * piPageSize
            iSeen                = 0
            iTaken               = 0
            plHasMore            = FALSE
            .

        FOR EACH led_NCS NO-LOCK
            WHERE led_NCS.omschrijving BEGINS pcOmschrijvingPrefix
            BY led_NCS.ncs:

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLedNCS.
            CopyToTt( BUFFER led_NCS, BUFFER ttLedNCS ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLedNCS:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetItem( INPUT pcNcs AS CHARACTER ):

        EMPTY TEMP-TABLE ttLedNCS.

        FIND FIRST led_NCS NO-LOCK WHERE led_NCS.ncs EQ pcNcs NO-ERROR.

        IF AVAILABLE led_NCS THEN
        DO:
            CREATE ttLedNCS.
            CopyToTt( BUFFER led_NCS, BUFFER ttLedNCS ).
        END.

        RETURN TEMP-TABLE ttLedNCS:HANDLE.

    END METHOD.

END CLASS.
