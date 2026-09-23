/*------------------------------------------------------------------------
    File        : BonLijnProductieBE.cls
    Purpose     : Business Entity for the "bonlijn_productie" table -
                  production sub-lines of a bonlijn. Always scoped to an
                  existing bonnr+blijnnr (EnsureBonLijnExists guard on
                  every method). Fase 4 (VerwerkProductie/AnnulProductie/
                  CheckProductie/Productie-datum logica) is explicitly out
                  of scope here.
    Field map (JSON key -> bonlijn_productie column):
                  bonnr             -> bonnr    (PK, from path, immutable)
                  blijnnr           -> blijnnr  (PK, from path, immutable)
                  lijnnr            -> lijnnr   (PK, server-generated on create)
                  artnr             -> artnr
                  aantal            -> aantal
                  gereserv          -> gereserv
                  effectiefGereserv -> effectief-gereserv
                  swEffectief       -> swEffectief
                  besteld           -> besteld
                  omschr            -> omschr
    Syntax      : Called from Luna.Web.BonHandler
                  (/web/bon/{bonnr}/lijn/{blijnnr}/productie[/{lijnnr}])
    Author(s)   : Devin
    Created     : 2026-09-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.BonLijnProductieBE:

    DEFINE TEMP-TABLE ttProductie NO-UNDO SERIALIZE-NAME "items":u
        FIELD bonnr             AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD blijnnr           AS INTEGER   SERIALIZE-NAME "blijnnr":u
        FIELD lijnnr            AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD artnr             AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD aantal            AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD gereserv          AS DECIMAL   SERIALIZE-NAME "gereserv":u
        FIELD effectiefGereserv AS DECIMAL   SERIALIZE-NAME "effectiefGereserv":u
        FIELD swEffectief       AS LOGICAL   SERIALIZE-NAME "swEffectief":u
        FIELD besteld           AS DECIMAL   SERIALIZE-NAME "besteld":u
        FIELD omschr            AS CHARACTER SERIALIZE-NAME "omschr":u
        INDEX idx-lijnnr IS PRIMARY bonnr blijnnr lijnnr.

    /*------------------------------------------------------------------------------
        Purpose: Throws AppError 404 if the parent bon or bonlijn
                 (bonnr+blijnnr) doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureBonLijnExists( INPUT piBonnr AS INTEGER, INPUT piBlijnnr AS INTEGER ):

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

        FIND FIRST bonlijn NO-LOCK
            WHERE bonlijn.bonnr EQ piBonnr
              AND bonlijn.lijnnr EQ piBlijnnr NO-ERROR.
        IF NOT AVAILABLE bonlijn THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Bonlijn &1/&2 not found":u, piBonnr, piBlijnnr), 404).

    END METHOD.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbProductie FOR bonlijn_productie, BUFFER pbTt FOR ttProductie ):

        ASSIGN
            pbTt.bonnr             = pbProductie.bonnr
            pbTt.blijnnr           = pbProductie.blijnnr
            pbTt.lijnnr            = pbProductie.lijnnr
            pbTt.artnr             = pbProductie.artnr
            pbTt.aantal            = pbProductie.aantal
            pbTt.gereserv          = pbProductie.gereserv
            pbTt.effectiefGereserv = pbProductie.effectief-gereserv
            pbTt.swEffectief       = pbProductie.swEffectief
            pbTt.besteld           = pbProductie.besteld
            pbTt.omschr            = pbProductie.omschr
            .

    END METHOD.

    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbProductie FOR bonlijn_productie ):

        IF poBody:Has("artnr":u)             THEN pbProductie.artnr             = poBody:GetCharacter("artnr":u).
        IF poBody:Has("aantal":u)            THEN pbProductie.aantal            = poBody:GetDecimal("aantal":u).
        IF poBody:Has("gereserv":u)          THEN pbProductie.gereserv          = poBody:GetDecimal("gereserv":u).
        IF poBody:Has("effectiefGereserv":u) THEN pbProductie.effectief-gereserv = poBody:GetDecimal("effectiefGereserv":u).
        IF poBody:Has("swEffectief":u)       THEN pbProductie.swEffectief       = poBody:GetLogical("swEffectief":u).
        IF poBody:Has("besteld":u)           THEN pbProductie.besteld           = poBody:GetDecimal("besteld":u).
        IF poBody:Has("omschr":u)            THEN pbProductie.omschr            = poBody:GetCharacter("omschr":u).

    END METHOD.

    METHOD PUBLIC HANDLE GetProductieLijnen( INPUT piBonnr AS INTEGER, INPUT piBlijnnr AS INTEGER ):

        EnsureBonLijnExists( piBonnr, piBlijnnr ).

        EMPTY TEMP-TABLE ttProductie.

        FOR EACH bonlijn_productie NO-LOCK
            WHERE bonlijn_productie.bonnr   EQ piBonnr
              AND bonlijn_productie.blijnnr EQ piBlijnnr
            BY bonlijn_productie.lijnnr:

            CREATE ttProductie.
            CopyToTt( BUFFER bonlijn_productie, BUFFER ttProductie ).
        END.

        RETURN TEMP-TABLE ttProductie:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetProductieLijn( INPUT piBonnr AS INTEGER, INPUT piBlijnnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureBonLijnExists( piBonnr, piBlijnnr ).

        EMPTY TEMP-TABLE ttProductie.

        FIND FIRST bonlijn_productie NO-LOCK
            WHERE bonlijn_productie.bonnr   EQ piBonnr
              AND bonlijn_productie.blijnnr EQ piBlijnnr
              AND bonlijn_productie.lijnnr  EQ piLijnnr NO-ERROR.

        IF AVAILABLE bonlijn_productie THEN
        DO:
            CREATE ttProductie.
            CopyToTt( BUFFER bonlijn_productie, BUFFER ttProductie ).
        END.

        RETURN TEMP-TABLE ttProductie:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE CreateProductieLijn( INPUT piBonnr AS INTEGER, INPUT piBlijnnr AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iNewLijnnr AS INTEGER NO-UNDO.

        EnsureBonLijnExists( piBonnr, piBlijnnr ).

        EMPTY TEMP-TABLE ttProductie.

        DO TRANSACTION:
            FIND LAST bonlijn_productie USE-INDEX bonlijn_productie-x1 EXCLUSIVE-LOCK
                WHERE bonlijn_productie.bonnr   EQ piBonnr
                  AND bonlijn_productie.blijnnr EQ piBlijnnr NO-ERROR.

            iNewLijnnr = (IF AVAILABLE bonlijn_productie THEN bonlijn_productie.lijnnr ELSE 0) + 1.

            CREATE bonlijn_productie.
            ASSIGN
                bonlijn_productie.bonnr   = piBonnr
                bonlijn_productie.blijnnr = piBlijnnr
                bonlijn_productie.lijnnr  = iNewLijnnr
                .

            ApplyFields( INPUT poBody, BUFFER bonlijn_productie ).

            CREATE ttProductie.
            CopyToTt( BUFFER bonlijn_productie, BUFFER ttProductie ).
        END.

        RETURN TEMP-TABLE ttProductie:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE UpdateProductieLijn(
        INPUT piBonnr   AS INTEGER,
        INPUT piBlijnnr AS INTEGER,
        INPUT piLijnnr  AS INTEGER,
        INPUT poBody    AS JsonObject ):

        EnsureBonLijnExists( piBonnr, piBlijnnr ).

        EMPTY TEMP-TABLE ttProductie.

        DO TRANSACTION:
            FIND FIRST bonlijn_productie EXCLUSIVE-LOCK
                WHERE bonlijn_productie.bonnr   EQ piBonnr
                  AND bonlijn_productie.blijnnr EQ piBlijnnr
                  AND bonlijn_productie.lijnnr  EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bonlijn_productie THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Productie sublijn &1/&2/&3 not found":u, piBonnr, piBlijnnr, piLijnnr), 404).

            ApplyFields( INPUT poBody, BUFFER bonlijn_productie ).

            CREATE ttProductie.
            CopyToTt( BUFFER bonlijn_productie, BUFFER ttProductie ).
        END.

        RETURN TEMP-TABLE ttProductie:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeleteProductieLijn( INPUT piBonnr AS INTEGER, INPUT piBlijnnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureBonLijnExists( piBonnr, piBlijnnr ).

        DO TRANSACTION:
            FIND FIRST bonlijn_productie EXCLUSIVE-LOCK
                WHERE bonlijn_productie.bonnr   EQ piBonnr
                  AND bonlijn_productie.blijnnr EQ piBlijnnr
                  AND bonlijn_productie.lijnnr  EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bonlijn_productie THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Productie sublijn &1/&2/&3 not found":u, piBonnr, piBlijnnr, piLijnnr), 404).

            DELETE bonlijn_productie.
        END.

    END METHOD.

END CLASS.

