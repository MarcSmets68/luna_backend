/*------------------------------------------------------------------------
    File        : BonHerstelBE.cls
    Purpose     : Business Entity for the "bon_herstel" table -
                  herstelworkflow (repair workflow) 1-on-1 record per
                  bonnr, only for bon.type EQ "HERSTELLING". CRUD +
                  status transitions ONTVANGST -> DIAGNOSE ->
                  OND.BESTELD -> (auto) IN HERSTELLING -> HERSTELD.
    Field map (JSON key -> bon_herstel column), all 22 non-PK fields:
                  bonnr                -> bonnr    (PK, from path, immutable)
                  artnr                -> artnr
                  omschr               -> omschr
                  probleem             -> probleem
                  facnr                -> facnr
                  facDatum             -> fac-datum
                  ordnr                -> ordnr
                  levDatum             -> lev-dat
                  bestek               -> bestek
                  bestekKosten         -> bestek-kosten
                  stempel              -> stempel   (not writable via PUT - only via the transition endpoints)
                  herstelling          -> herstelling
                  datum                -> datum
                  refLev               -> ref-lev
                  rapnr                -> rapnr
                  levnr                -> levnr
                  locatie              -> locatie
                  herstelDatum         -> herstel-datum
                  herstelLocatieDatum  -> herstel-locatie-datum
                  technieker           -> technieker
                  maxKosten            -> max-kosten
                  garantie             -> garantie
                  prior                -> prior
                  opmTechn             -> opm-techn
    Syntax      : Called from Luna.Web.BonHandler
                  (/web/bon/{bonnr}/herstel[/diagnose|/bestellen|/hersteld])
    Description : Owns all bon_herstel DB access. Every endpoint (except
                  where the check is about stempel itself) 409s if
                  bon.type NE "HERSTELLING". CheckAutoTransitionToInHerstelling
                  is PUBLIC so Luna.BusinessLogic.BonLijnReserveringBE can
                  call it within the same transaction as a reservation
                  change.
    Author(s)   : Devin
    Created     : 2026-09-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.BonHerstelBE:

    DEFINE TEMP-TABLE ttBonHerstel NO-UNDO SERIALIZE-NAME "items":u
        FIELD bonnr               AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD artnr                AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschr                AS CHARACTER SERIALIZE-NAME "omschr":u
        FIELD probleem              AS CHARACTER SERIALIZE-NAME "probleem":u
        FIELD facnr                 AS INTEGER   SERIALIZE-NAME "facnr":u
        FIELD facDatum              AS DATE      SERIALIZE-NAME "facDatum":u
        FIELD ordnr                 AS INTEGER   SERIALIZE-NAME "ordnr":u
        FIELD levDatum              AS DATE      SERIALIZE-NAME "levDatum":u
        FIELD bestek                AS LOGICAL   SERIALIZE-NAME "bestek":u
        FIELD bestekKosten          AS DECIMAL   SERIALIZE-NAME "bestekKosten":u
        FIELD stempel               AS CHARACTER SERIALIZE-NAME "stempel":u
        FIELD herstelling           AS CHARACTER SERIALIZE-NAME "herstelling":u
        FIELD datum                 AS DATE      SERIALIZE-NAME "datum":u
        FIELD refLev                AS CHARACTER SERIALIZE-NAME "refLev":u
        FIELD rapnr                 AS INTEGER   SERIALIZE-NAME "rapnr":u
        FIELD levnr                 AS INTEGER   SERIALIZE-NAME "levnr":u
        FIELD locatie                AS CHARACTER SERIALIZE-NAME "locatie":u
        FIELD herstelDatum           AS DATE      SERIALIZE-NAME "herstelDatum":u
        FIELD herstelLocatieDatum    AS DATE      SERIALIZE-NAME "herstelLocatieDatum":u
        FIELD technieker             AS CHARACTER SERIALIZE-NAME "technieker":u
        FIELD maxKosten              AS DECIMAL   SERIALIZE-NAME "maxKosten":u
        FIELD garantie               AS LOGICAL   SERIALIZE-NAME "garantie":u
        FIELD prior                  AS LOGICAL   SERIALIZE-NAME "prior":u
        FIELD opmTechn                AS CHARACTER SERIALIZE-NAME "opmTechn":u
        INDEX idx-bonnr IS PRIMARY bonnr.

    /*------------------------------------------------------------------------------
        Purpose: 404 if bon not found; 409 if bon.type NE "HERSTELLING".
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureBonIsHerstelling( INPUT piBonnr AS INTEGER ):

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

        IF bon.type NE "HERSTELLING":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Bon &1 has type '&2', bon_herstel is only available for type HERSTELLING":u,
                    piBonnr, bon.type), 409).

    END METHOD.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbHerstel FOR bon_herstel, BUFFER pbTt FOR ttBonHerstel ):

        ASSIGN
            pbTt.bonnr               = pbHerstel.bonnr
            pbTt.artnr               = pbHerstel.artnr
            pbTt.omschr              = pbHerstel.omschr
            pbTt.probleem            = pbHerstel.probleem
            pbTt.facnr               = pbHerstel.facnr
            pbTt.facDatum            = pbHerstel.fac-datum
            pbTt.ordnr               = pbHerstel.ordnr
            pbTt.levDatum            = pbHerstel.lev-dat
            pbTt.bestek              = pbHerstel.bestek
            pbTt.bestekKosten        = pbHerstel.bestek-kosten
            pbTt.stempel             = pbHerstel.stempel
            pbTt.herstelling         = pbHerstel.herstelling
            pbTt.datum               = pbHerstel.datum
            pbTt.refLev              = pbHerstel.ref-lev
            pbTt.rapnr               = pbHerstel.rapnr
            pbTt.levnr               = pbHerstel.levnr
            pbTt.locatie             = pbHerstel.locatie
            pbTt.herstelDatum        = pbHerstel.herstel-datum
            pbTt.herstelLocatieDatum = pbHerstel.herstel-locatie-datum
            pbTt.technieker          = pbHerstel.technieker
            pbTt.maxKosten           = pbHerstel.max-kosten
            pbTt.garantie            = pbHerstel.garantie
            pbTt.prior               = pbHerstel.prior
            pbTt.opmTechn            = pbHerstel.opm-techn
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every writable (non-stempel) field present in the
                 body. `stempel` is never touched here - only the
                 transition methods below change it.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbHerstel FOR bon_herstel ):

        IF poBody:Has("artnr":u)               THEN pbHerstel.artnr                   = poBody:GetCharacter("artnr":u).
        IF poBody:Has("omschr":u)              THEN pbHerstel.omschr                  = poBody:GetCharacter("omschr":u).
        IF poBody:Has("probleem":u)            THEN pbHerstel.probleem                = poBody:GetCharacter("probleem":u).
        IF poBody:Has("facnr":u)                THEN pbHerstel.facnr                   = poBody:GetInteger("facnr":u).
        IF poBody:Has("facDatum":u)             THEN pbHerstel.fac-datum               = poBody:GetDate("facDatum":u).
        IF poBody:Has("ordnr":u)                THEN pbHerstel.ordnr                   = poBody:GetInteger("ordnr":u).
        IF poBody:Has("levDatum":u)             THEN pbHerstel.lev-dat                 = poBody:GetDate("levDatum":u).
        IF poBody:Has("bestek":u)               THEN pbHerstel.bestek                  = poBody:GetLogical("bestek":u).
        IF poBody:Has("bestekKosten":u)         THEN pbHerstel.bestek-kosten           = poBody:GetDecimal("bestekKosten":u).
        IF poBody:Has("herstelling":u)          THEN pbHerstel.herstelling             = poBody:GetCharacter("herstelling":u).
        IF poBody:Has("datum":u)                THEN pbHerstel.datum                   = poBody:GetDate("datum":u).
        IF poBody:Has("refLev":u)               THEN pbHerstel.ref-lev                 = poBody:GetCharacter("refLev":u).
        IF poBody:Has("rapnr":u)                THEN pbHerstel.rapnr                   = poBody:GetInteger("rapnr":u).
        IF poBody:Has("levnr":u)                THEN pbHerstel.levnr                   = poBody:GetInteger("levnr":u).
        IF poBody:Has("locatie":u)              THEN pbHerstel.locatie                 = poBody:GetCharacter("locatie":u).
        IF poBody:Has("herstelDatum":u)         THEN pbHerstel.herstel-datum           = poBody:GetDate("herstelDatum":u).
        IF poBody:Has("herstelLocatieDatum":u)  THEN pbHerstel.herstel-locatie-datum   = poBody:GetDate("herstelLocatieDatum":u).
        IF poBody:Has("technieker":u)           THEN pbHerstel.technieker              = poBody:GetCharacter("technieker":u).
        IF poBody:Has("maxKosten":u)            THEN pbHerstel.max-kosten              = poBody:GetDecimal("maxKosten":u).
        IF poBody:Has("garantie":u)             THEN pbHerstel.garantie                = poBody:GetLogical("garantie":u).
        IF poBody:Has("prior":u)                THEN pbHerstel.prior                   = poBody:GetLogical("prior":u).
        IF poBody:Has("opmTechn":u)             THEN pbHerstel.opm-techn               = poBody:GetCharacter("opmTechn":u).

    END METHOD.

    METHOD PUBLIC HANDLE GetBonHerstel( INPUT piBonnr AS INTEGER ):

        EnsureBonIsHerstelling( piBonnr ).

        EMPTY TEMP-TABLE ttBonHerstel.

        FIND FIRST bon_herstel NO-LOCK WHERE bon_herstel.bonnr EQ piBonnr NO-ERROR.

        IF AVAILABLE bon_herstel THEN
        DO:
            CREATE ttBonHerstel.
            CopyToTt( BUFFER bon_herstel, BUFFER ttBonHerstel ).
        END.

        RETURN TEMP-TABLE ttBonHerstel:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE CreateBonHerstel( INPUT piBonnr AS INTEGER, INPUT poBody AS JsonObject ):

        EnsureBonIsHerstelling( piBonnr ).

        EMPTY TEMP-TABLE ttBonHerstel.

        DO TRANSACTION:
            IF CAN-FIND(FIRST bon_herstel WHERE bon_herstel.bonnr EQ piBonnr) THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bon &1 already has a bon_herstel record":u, piBonnr), 409).

            CREATE bon_herstel.
            ASSIGN bon_herstel.bonnr = piBonnr.

            ApplyFields( INPUT poBody, BUFFER bon_herstel ).

            CREATE ttBonHerstel.
            CopyToTt( BUFFER bon_herstel, BUFFER ttBonHerstel ).
        END.

        RETURN TEMP-TABLE ttBonHerstel:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE UpdateBonHerstel( INPUT piBonnr AS INTEGER, INPUT poBody AS JsonObject ):

        EnsureBonIsHerstelling( piBonnr ).

        EMPTY TEMP-TABLE ttBonHerstel.

        DO TRANSACTION:
            FIND FIRST bon_herstel EXCLUSIVE-LOCK WHERE bon_herstel.bonnr EQ piBonnr NO-ERROR.
            IF NOT AVAILABLE bon_herstel THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bon &1 has no bon_herstel record":u, piBonnr), 404).

            ApplyFields( INPUT poBody, BUFFER bon_herstel ).

            CREATE ttBonHerstel.
            CopyToTt( BUFFER bon_herstel, BUFFER ttBonHerstel ).
        END.

        RETURN TEMP-TABLE ttBonHerstel:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Generic status transition helper - 404 if no
                 bon_herstel record, 409 if the current stempel isn't
                 pcFromStempel.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE HANDLE Transition(
        INPUT piBonnr       AS INTEGER,
        INPUT pcFromStempel AS CHARACTER,
        INPUT pcToStempel   AS CHARACTER ):

        EnsureBonIsHerstelling( piBonnr ).

        EMPTY TEMP-TABLE ttBonHerstel.

        DO TRANSACTION:
            FIND FIRST bon_herstel EXCLUSIVE-LOCK WHERE bon_herstel.bonnr EQ piBonnr NO-ERROR.
            IF NOT AVAILABLE bon_herstel THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bon &1 has no bon_herstel record":u, piBonnr), 404).

            IF bon_herstel.stempel NE pcFromStempel THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bon &1 bon_herstel has stempel '&2' and cannot transition to '&3' (must be '&4')":u,
                        piBonnr, bon_herstel.stempel, pcToStempel, pcFromStempel), 409).

            bon_herstel.stempel = pcToStempel.

            CREATE ttBonHerstel.
            CopyToTt( BUFFER bon_herstel, BUFFER ttBonHerstel ).
        END.

        RETURN TEMP-TABLE ttBonHerstel:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE TransitionToDiagnose( INPUT piBonnr AS INTEGER ):
        RETURN Transition( piBonnr, "ONTVANGST":u, "DIAGNOSE":u ).
    END METHOD.

    METHOD PUBLIC HANDLE TransitionToBesteld( INPUT piBonnr AS INTEGER ):
        RETURN Transition( piBonnr, "DIAGNOSE":u, "OND.BESTELD":u ).
    END METHOD.

    METHOD PUBLIC HANDLE TransitionToHersteld( INPUT piBonnr AS INTEGER ):
        RETURN Transition( piBonnr, "IN HERSTELLING":u, "HERSTELD":u ).
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: If bon.type EQ "HERSTELLING" AND bon_herstel.stempel EQ
                 "OND.BESTELD" AND every bonlijn of this bon has gereserv
                 EQ te-leveren, auto-transitions bon_herstel.stempel to
                 "IN HERSTELLING". Public so BonLijnReserveringBE can call
                 it within the same transaction as a reservation change.
                 No-op (silently returns) if any precondition isn't met -
                 this is a best-effort auto-transition, not a hard
                 validation gate.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID CheckAutoTransitionToInHerstelling( INPUT piBonnr AS INTEGER ):

        DEFINE BUFFER bfBon      FOR bon.
        DEFINE BUFFER bfBonlijn  FOR bonlijn.

        FIND FIRST bfBon NO-LOCK WHERE bfBon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bfBon OR bfBon.type NE "HERSTELLING":u THEN RETURN.

        FIND FIRST bon_herstel EXCLUSIVE-LOCK WHERE bon_herstel.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon_herstel OR bon_herstel.stempel NE "OND.BESTELD":u THEN RETURN.

        FOR EACH bfBonlijn NO-LOCK WHERE bfBonlijn.bonnr EQ piBonnr:
            IF bfBonlijn.gereserv NE bfBonlijn.te-leveren THEN RETURN.
        END.

        bon_herstel.stempel = "IN HERSTELLING":u.

    END METHOD.

END CLASS.

