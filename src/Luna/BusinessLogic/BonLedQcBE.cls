/*------------------------------------------------------------------------
    File        : BonLedQcBE.cls
    Purpose     : Business Entity for the "bon_led_qc" table - LED QC
                  regels onder een bon. Always scoped to an existing
                  bonnr (EnsureBonExists guard on every method).
    Field map (JSON key -> bon_led_qc column):
                  bonnr    -> bonnr    (PK, from path, immutable)
                  groepnr  -> groepnr  (PK, required in body on create)
                  datum    -> datum    (PK, server-side TODAY on create)
                  volgnr   -> volgnr   (PK, server-generated on create)
                  lijnnr   -> lijnnr   (PK, part of index, taken from body if
                                        present, else 0 - no other lijnnr
                                        source is defined for this resource)
                  omschr   -> omschr
                  controle -> controle
                  id       -> id
                  info     -> info
                  swInfo   -> swInfo
    Syntax      : Called from Luna.Web.BonHandler
                  (/web/bon/{bonnr}/led-qc[/{groepnr}/{volgnr}/{lijnnr}])
    Author(s)   : Devin
    Created     : 2026-09-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.BonLedQcBE:

    DEFINE TEMP-TABLE ttBonLedQc NO-UNDO SERIALIZE-NAME "items":u
        FIELD bonnr    AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD groepnr  AS INTEGER   SERIALIZE-NAME "groepnr":u
        FIELD datum    AS DATE      SERIALIZE-NAME "datum":u
        FIELD volgnr   AS INTEGER   SERIALIZE-NAME "volgnr":u
        FIELD lijnnr   AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD omschr   AS CHARACTER SERIALIZE-NAME "omschr":u
        FIELD controle AS CHARACTER SERIALIZE-NAME "controle":u
        FIELD id       AS CHARACTER SERIALIZE-NAME "id":u
        FIELD info     AS CHARACTER SERIALIZE-NAME "info":u
        FIELD swInfo   AS LOGICAL   SERIALIZE-NAME "swInfo":u
        INDEX idx-lijnnr IS PRIMARY bonnr groepnr datum volgnr lijnnr.

    METHOD PRIVATE VOID EnsureBonExists( INPUT piBonnr AS INTEGER ):

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

    END METHOD.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbQc FOR bon_led_qc, BUFFER pbTt FOR ttBonLedQc ):

        ASSIGN
            pbTt.bonnr    = pbQc.bonnr
            pbTt.groepnr  = pbQc.groepnr
            pbTt.datum    = pbQc.datum
            pbTt.volgnr   = pbQc.volgnr
            pbTt.lijnnr   = pbQc.lijnnr
            pbTt.omschr   = pbQc.omschr
            pbTt.controle = pbQc.controle
            pbTt.id       = pbQc.id
            pbTt.info     = pbQc.info
            pbTt.swInfo   = pbQc.swInfo
            .

    END METHOD.

    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbQc FOR bon_led_qc ):

        IF poBody:Has("omschr":u)   THEN pbQc.omschr   = poBody:GetCharacter("omschr":u).
        IF poBody:Has("controle":u) THEN pbQc.controle = poBody:GetCharacter("controle":u).
        IF poBody:Has("id":u)       THEN pbQc.id       = poBody:GetCharacter("id":u).
        IF poBody:Has("info":u)     THEN pbQc.info     = poBody:GetCharacter("info":u).
        IF poBody:Has("swInfo":u)   THEN pbQc.swInfo   = poBody:GetLogical("swInfo":u).

    END METHOD.

    METHOD PUBLIC HANDLE GetBonLedQcLijnen( INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER ):

        EnsureBonExists( piBonnr ).

        EMPTY TEMP-TABLE ttBonLedQc.

        FOR EACH bon_led_qc NO-LOCK
            WHERE bon_led_qc.bonnr EQ piBonnr
              AND (piGroepnr LE 0 OR bon_led_qc.groepnr EQ piGroepnr)
            BY bon_led_qc.groepnr BY bon_led_qc.datum BY bon_led_qc.volgnr BY bon_led_qc.lijnnr:

            CREATE ttBonLedQc.
            CopyToTt( BUFFER bon_led_qc, BUFFER ttBonLedQc ).
        END.

        RETURN TEMP-TABLE ttBonLedQc:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetBonLedQcLijn(
        INPUT piBonnr   AS INTEGER,
        INPUT piGroepnr AS INTEGER,
        INPUT piVolgnr  AS INTEGER,
        INPUT piLijnnr  AS INTEGER ):

        EnsureBonExists( piBonnr ).

        EMPTY TEMP-TABLE ttBonLedQc.

        FIND FIRST bon_led_qc NO-LOCK
            WHERE bon_led_qc.bonnr   EQ piBonnr
              AND bon_led_qc.groepnr EQ piGroepnr
              AND bon_led_qc.volgnr  EQ piVolgnr
              AND bon_led_qc.lijnnr  EQ piLijnnr NO-ERROR.

        IF AVAILABLE bon_led_qc THEN
        DO:
            CREATE ttBonLedQc.
            CopyToTt( BUFFER bon_led_qc, BUFFER ttBonLedQc ).
        END.

        RETURN TEMP-TABLE ttBonLedQc:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a bon_led_qc row. groepnr is required in the
                 body; datum is set server-side to TODAY; volgnr is
                 server-generated (last volgnr for bonnr+groepnr+datum +
                 1) inside the same transaction. lijnnr, if present in
                 the body, is taken as-is (no other server-side source
                 for it is defined for this resource); defaults to 0.
        Errors : AppError 404 - bon not found.
                 AppError 400 - groepnr missing.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateBonLedQcLijn( INPUT piBonnr AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iGroepnr  AS INTEGER NO-UNDO.
        DEFINE VARIABLE dDatum    AS DATE    NO-UNDO.
        DEFINE VARIABLE iNewVolgnr AS INTEGER NO-UNDO.

        EnsureBonExists( piBonnr ).

        IF NOT poBody:Has("groepnr":u) THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                "groepnr is required to create a bon_led_qc row":u, 400).

        iGroepnr = poBody:GetInteger("groepnr":u).
        dDatum   = TODAY.

        EMPTY TEMP-TABLE ttBonLedQc.

        DO TRANSACTION:
            FIND LAST bon_led_qc USE-INDEX bon_led_qc-x1 EXCLUSIVE-LOCK
                WHERE bon_led_qc.bonnr   EQ piBonnr
                  AND bon_led_qc.groepnr EQ iGroepnr
                  AND bon_led_qc.datum   EQ dDatum NO-ERROR.

            iNewVolgnr = (IF AVAILABLE bon_led_qc THEN bon_led_qc.volgnr ELSE 0) + 1.

            CREATE bon_led_qc.
            ASSIGN
                bon_led_qc.bonnr   = piBonnr
                bon_led_qc.groepnr = iGroepnr
                bon_led_qc.datum   = dDatum
                bon_led_qc.volgnr  = iNewVolgnr
                bon_led_qc.lijnnr  = (IF poBody:Has("lijnnr":u) THEN poBody:GetInteger("lijnnr":u) ELSE 0)
                .

            ApplyFields( INPUT poBody, BUFFER bon_led_qc ).

            CREATE ttBonLedQc.
            CopyToTt( BUFFER bon_led_qc, BUFFER ttBonLedQc ).
        END.

        RETURN TEMP-TABLE ttBonLedQc:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE UpdateBonLedQcLijn(
        INPUT piBonnr   AS INTEGER,
        INPUT piGroepnr AS INTEGER,
        INPUT piVolgnr  AS INTEGER,
        INPUT piLijnnr  AS INTEGER,
        INPUT poBody    AS JsonObject ):

        EnsureBonExists( piBonnr ).

        EMPTY TEMP-TABLE ttBonLedQc.

        DO TRANSACTION:
            FIND FIRST bon_led_qc EXCLUSIVE-LOCK
                WHERE bon_led_qc.bonnr   EQ piBonnr
                  AND bon_led_qc.groepnr EQ piGroepnr
                  AND bon_led_qc.volgnr  EQ piVolgnr
                  AND bon_led_qc.lijnnr  EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bon_led_qc THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("LED-QC-lijn &1/&2/&3/&4 not found":u, piBonnr, piGroepnr, piVolgnr, piLijnnr), 404).

            ApplyFields( INPUT poBody, BUFFER bon_led_qc ).

            CREATE ttBonLedQc.
            CopyToTt( BUFFER bon_led_qc, BUFFER ttBonLedQc ).
        END.

        RETURN TEMP-TABLE ttBonLedQc:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeleteBonLedQcLijn(
        INPUT piBonnr   AS INTEGER,
        INPUT piGroepnr AS INTEGER,
        INPUT piVolgnr  AS INTEGER,
        INPUT piLijnnr  AS INTEGER ):

        EnsureBonExists( piBonnr ).

        DO TRANSACTION:
            FIND FIRST bon_led_qc EXCLUSIVE-LOCK
                WHERE bon_led_qc.bonnr   EQ piBonnr
                  AND bon_led_qc.groepnr EQ piGroepnr
                  AND bon_led_qc.volgnr  EQ piVolgnr
                  AND bon_led_qc.lijnnr  EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bon_led_qc THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("LED-QC-lijn &1/&2/&3/&4 not found":u, piBonnr, piGroepnr, piVolgnr, piLijnnr), 404).

            DELETE bon_led_qc.
        END.

    END METHOD.

END CLASS.

