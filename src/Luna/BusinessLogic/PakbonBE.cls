/*------------------------------------------------------------------------
    File        : PakbonBE.cls
    Purpose     : Business Entity for the "pakbon" (packing slip) table -
                  full CRUD for a curated core subset of fields, mirroring
                  Luna.BusinessLogic.BonBE's pattern (pagination, filters,
                  server-generated PK). `pakbon` has 67 fields in total;
                  only the subset below is exposed via the API.
    Field map (JSON key -> pakbon column):
                  paknr           -> paknr        (PK, server-generated, not writable via API)
                  stempel         -> stempel
                  datum           -> datum
                  klnr            -> klnr
                  naam            -> naam
                  naam1           -> naam1
                  adres           -> adres
                  postnr          -> postnr
                  stad            -> stad
                  lnaam           -> lnaam
                  ladres          -> ladres
                  lpostnr         -> lpostnr
                  lstad           -> lstad
                  munt            -> munt
                  nBedrag         -> n-bedrag
                  bBedrag         -> b-bedrag
                  totBtw          -> tot-btw
                  uRef            -> u-ref
                  opm             -> opm
                  swProforma      -> swProforma
                  facnr           -> facnr
                  batchnr         -> batchnr
                  validatie       -> validatie
                  afgedrukt       -> afgedrukt
                  afgehaald       -> afgehaald     (not writable via normal PUT - see AfhalenPakbon)
                  afgehaaldId     -> afgehaald-id  (not writable via normal PUT)
                  afgehaaldDatum  -> afgehaald-datum (not writable via normal PUT)
                  afgehaaldUur    -> afgehaald-uur (not writable via normal PUT)
                  compleet        -> compleet
                  tracknr         -> tracknr
                  verzending      -> verzending
                  projectnr       -> projectnr     (bare passthrough, no project-integration logic)
    Notes       : facnr/projectnr are bare passthrough fields - the
                  facturatie-aggregatie (EUR125 threshold) and Project
                  integration logic are explicitly out of scope here.
    Syntax      : Called from Luna.Web.PakbonHandler (/web/pakbon...)
    Author(s)   : Devin
    Created     : 2026-09-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.PakbonBE:

    DEFINE TEMP-TABLE ttPakbon NO-UNDO SERIALIZE-NAME "items":u
        FIELD paknr          AS INTEGER   SERIALIZE-NAME "paknr":u
        FIELD stempel        AS CHARACTER SERIALIZE-NAME "stempel":u
        FIELD datum          AS DATE      SERIALIZE-NAME "datum":u
        FIELD klnr           AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD naam           AS CHARACTER SERIALIZE-NAME "naam":u
        FIELD naam1          AS CHARACTER SERIALIZE-NAME "naam1":u
        FIELD adres          AS CHARACTER SERIALIZE-NAME "adres":u
        FIELD postnr         AS CHARACTER SERIALIZE-NAME "postnr":u
        FIELD stad           AS CHARACTER SERIALIZE-NAME "stad":u
        FIELD lnaam          AS CHARACTER SERIALIZE-NAME "lnaam":u
        FIELD ladres         AS CHARACTER SERIALIZE-NAME "ladres":u
        FIELD lpostnr        AS CHARACTER SERIALIZE-NAME "lpostnr":u
        FIELD lstad          AS CHARACTER SERIALIZE-NAME "lstad":u
        FIELD munt           AS CHARACTER SERIALIZE-NAME "munt":u
        FIELD nBedrag        AS DECIMAL   SERIALIZE-NAME "nBedrag":u
        FIELD bBedrag        AS DECIMAL   SERIALIZE-NAME "bBedrag":u
        FIELD totBtw         AS DECIMAL   SERIALIZE-NAME "totBtw":u
        FIELD uRef           AS CHARACTER SERIALIZE-NAME "uRef":u
        FIELD opm            AS CHARACTER SERIALIZE-NAME "opm":u
        FIELD swProforma     AS LOGICAL   SERIALIZE-NAME "swProforma":u
        FIELD facnr          AS INTEGER   SERIALIZE-NAME "facnr":u
        FIELD batchnr        AS INTEGER   SERIALIZE-NAME "batchnr":u
        FIELD validatie      AS LOGICAL   SERIALIZE-NAME "validatie":u
        FIELD afgedrukt      AS LOGICAL   SERIALIZE-NAME "afgedrukt":u
        FIELD afgehaald      AS LOGICAL   SERIALIZE-NAME "afgehaald":u
        FIELD afgehaaldId    AS CHARACTER SERIALIZE-NAME "afgehaaldId":u
        FIELD afgehaaldDatum AS DATE      SERIALIZE-NAME "afgehaaldDatum":u
        FIELD afgehaaldUur   AS CHARACTER SERIALIZE-NAME "afgehaaldUur":u
        FIELD compleet       AS LOGICAL   SERIALIZE-NAME "compleet":u
        FIELD tracknr        AS CHARACTER SERIALIZE-NAME "tracknr":u
        FIELD verzending     AS DATE      SERIALIZE-NAME "verzending":u
        FIELD projectnr      AS INTEGER   SERIALIZE-NAME "projectnr":u
        INDEX idx-paknr IS PRIMARY paknr DESCENDING.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbPakbon FOR pakbon, BUFFER pbTt FOR ttPakbon ):

        ASSIGN
            pbTt.paknr          = pbPakbon.paknr
            pbTt.stempel        = pbPakbon.stempel
            pbTt.datum          = pbPakbon.datum
            pbTt.klnr           = pbPakbon.klnr
            pbTt.naam           = pbPakbon.naam
            pbTt.naam1          = pbPakbon.naam1
            pbTt.adres          = pbPakbon.adres
            pbTt.postnr         = pbPakbon.postnr
            pbTt.stad           = pbPakbon.stad
            pbTt.lnaam          = pbPakbon.lnaam
            pbTt.ladres         = pbPakbon.ladres
            pbTt.lpostnr        = pbPakbon.lpostnr
            pbTt.lstad          = pbPakbon.lstad
            pbTt.munt           = pbPakbon.munt
            pbTt.nBedrag        = pbPakbon.n-bedrag
            pbTt.bBedrag        = pbPakbon.b-bedrag
            pbTt.totBtw         = pbPakbon.tot-btw
            pbTt.uRef           = pbPakbon.u-ref
            pbTt.opm            = pbPakbon.opm
            pbTt.swProforma     = pbPakbon.swProforma
            pbTt.facnr          = pbPakbon.facnr
            pbTt.batchnr        = pbPakbon.batchnr
            pbTt.validatie      = pbPakbon.validatie
            pbTt.afgedrukt      = pbPakbon.afgedrukt
            pbTt.afgehaald      = pbPakbon.afgehaald
            pbTt.afgehaaldId    = pbPakbon.afgehaald-id
            pbTt.afgehaaldDatum = pbPakbon.afgehaald-datum
            pbTt.afgehaaldUur   = pbPakbon.afgehaald-uur
            pbTt.compleet       = pbPakbon.compleet
            pbTt.tracknr        = pbPakbon.tracknr
            pbTt.verzending     = pbPakbon.verzending
            pbTt.projectnr      = pbPakbon.projectnr
            .

    END METHOD.

    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbPakbon FOR pakbon ):

        IF poBody:Has("stempel":u)    THEN pbPakbon.stempel   = poBody:GetCharacter("stempel":u).
        IF poBody:Has("datum":u)      THEN pbPakbon.datum     = poBody:GetDate("datum":u).
        IF poBody:Has("klnr":u)       THEN pbPakbon.klnr      = poBody:GetInteger("klnr":u).
        IF poBody:Has("naam":u)       THEN pbPakbon.naam      = poBody:GetCharacter("naam":u).
        IF poBody:Has("naam1":u)      THEN pbPakbon.naam1     = poBody:GetCharacter("naam1":u).
        IF poBody:Has("adres":u)      THEN pbPakbon.adres     = poBody:GetCharacter("adres":u).
        IF poBody:Has("postnr":u)     THEN pbPakbon.postnr    = poBody:GetCharacter("postnr":u).
        IF poBody:Has("stad":u)       THEN pbPakbon.stad      = poBody:GetCharacter("stad":u).
        IF poBody:Has("lnaam":u)      THEN pbPakbon.lnaam     = poBody:GetCharacter("lnaam":u).
        IF poBody:Has("ladres":u)     THEN pbPakbon.ladres    = poBody:GetCharacter("ladres":u).
        IF poBody:Has("lpostnr":u)    THEN pbPakbon.lpostnr   = poBody:GetCharacter("lpostnr":u).
        IF poBody:Has("lstad":u)      THEN pbPakbon.lstad     = poBody:GetCharacter("lstad":u).
        IF poBody:Has("munt":u)       THEN pbPakbon.munt      = poBody:GetCharacter("munt":u).
        IF poBody:Has("nBedrag":u)    THEN pbPakbon.n-bedrag  = poBody:GetDecimal("nBedrag":u).
        IF poBody:Has("bBedrag":u)    THEN pbPakbon.b-bedrag  = poBody:GetDecimal("bBedrag":u).
        IF poBody:Has("totBtw":u)     THEN pbPakbon.tot-btw   = poBody:GetDecimal("totBtw":u).
        IF poBody:Has("uRef":u)       THEN pbPakbon.u-ref     = poBody:GetCharacter("uRef":u).
        IF poBody:Has("opm":u)        THEN pbPakbon.opm       = poBody:GetCharacter("opm":u).
        IF poBody:Has("swProforma":u) THEN pbPakbon.swProforma = poBody:GetLogical("swProforma":u).
        IF poBody:Has("facnr":u)      THEN pbPakbon.facnr     = poBody:GetInteger("facnr":u).
        IF poBody:Has("batchnr":u)    THEN pbPakbon.batchnr   = poBody:GetInteger("batchnr":u).
        IF poBody:Has("validatie":u)  THEN pbPakbon.validatie = poBody:GetLogical("validatie":u).
        IF poBody:Has("afgedrukt":u)  THEN pbPakbon.afgedrukt = poBody:GetLogical("afgedrukt":u).
        IF poBody:Has("compleet":u)   THEN pbPakbon.compleet  = poBody:GetLogical("compleet":u).
        IF poBody:Has("tracknr":u)    THEN pbPakbon.tracknr   = poBody:GetCharacter("tracknr":u).
        IF poBody:Has("verzending":u) THEN pbPakbon.verzending = poBody:GetDate("verzending":u).
        IF poBody:Has("projectnr":u)  THEN pbPakbon.projectnr = poBody:GetInteger("projectnr":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Paged/filtered list of pakbon rows, newest paknr first.
                 Same "no exact total count, hasMore" approach as BonBE.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetPakbonnen(
        INPUT  piKlnr     AS INTEGER,
        INPUT  pcStempel  AS CHARACTER,
        INPUT  pcPaknr    AS CHARACTER,
        INPUT  pcNaam     AS CHARACTER,
        INPUT  piProjectnr AS INTEGER,
        INPUT  piPage     AS INTEGER,
        INPUT  piPageSize AS INTEGER,
        OUTPUT plHasMore  AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttPakbon.

        ASSIGN
            pcStempel = TRIM(pcStempel)
            pcPaknr   = TRIM(pcPaknr)
            pcNaam    = UPPER(TRIM(pcNaam))
            iSkip     = (piPage - 1) * piPageSize
            iSeen     = 0
            iTaken    = 0
            plHasMore = FALSE
            .

        FOR EACH pakbon NO-LOCK
            WHERE (piKlnr LE 0 OR pakbon.klnr EQ piKlnr)
              AND (pcStempel EQ "":u OR pakbon.stempel EQ pcStempel)
              AND (pcPaknr   EQ "":u OR STRING(pakbon.paknr) BEGINS pcPaknr)
              AND (pcNaam    EQ "":u OR INDEX(UPPER(pakbon.naam), pcNaam) GT 0)
              AND (piProjectnr LE 0 OR pakbon.projectnr EQ piProjectnr)
            BY pakbon.paknr DESCENDING:

            iSeen = iSeen + 1.

            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttPakbon.
            CopyToTt( BUFFER pakbon, BUFFER ttPakbon ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttPakbon:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetPakbon( INPUT piPaknr AS INTEGER ):

        EMPTY TEMP-TABLE ttPakbon.

        FIND FIRST pakbon NO-LOCK WHERE pakbon.paknr EQ piPaknr NO-ERROR.

        IF AVAILABLE pakbon THEN
        DO:
            CREATE ttPakbon.
            CopyToTt( BUFFER pakbon, BUFFER ttPakbon ).
        END.

        RETURN TEMP-TABLE ttPakbon:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a pakbon. paknr is computed server-side as (last
                 paknr, via pakbon-x1) + 1, under the same
                 EXCLUSIVE-LOCK/transaction as the CREATE.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreatePakbon( INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iNewPaknr AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttPakbon.

        DO TRANSACTION:
            FIND LAST pakbon USE-INDEX pakbon-x1 EXCLUSIVE-LOCK NO-ERROR.

            iNewPaknr = (IF AVAILABLE pakbon THEN pakbon.paknr ELSE 0) + 1.

            CREATE pakbon.
            ASSIGN pakbon.paknr = iNewPaknr.

            ApplyFields( INPUT poBody, BUFFER pakbon ).

            CREATE ttPakbon.
            CopyToTt( BUFFER pakbon, BUFFER ttPakbon ).
        END.

        RETURN TEMP-TABLE ttPakbon:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE UpdatePakbon( INPUT piPaknr AS INTEGER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttPakbon.

        DO TRANSACTION:
            FIND FIRST pakbon EXCLUSIVE-LOCK WHERE pakbon.paknr EQ piPaknr NO-ERROR.
            IF NOT AVAILABLE pakbon THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Pakbon &1 not found":u, piPaknr), 404).

            ApplyFields( INPUT poBody, BUFFER pakbon ).

            CREATE ttPakbon.
            CopyToTt( BUFFER pakbon, BUFFER ttPakbon ).
        END.

        RETURN TEMP-TABLE ttPakbon:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeletePakbon( INPUT piPaknr AS INTEGER ):

        FIND FIRST pakbon NO-LOCK WHERE pakbon.paknr EQ piPaknr NO-ERROR.
        IF NOT AVAILABLE pakbon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Pakbon &1 not found":u, piPaknr), 404).

        IF CAN-FIND(FIRST paklijn NO-LOCK WHERE paklijn.paknr EQ piPaknr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Pakbon &1 has related paklijn rows and cannot be deleted":u, piPaknr), 409).

        DO TRANSACTION:
            FIND FIRST pakbon EXCLUSIVE-LOCK WHERE pakbon.paknr EQ piPaknr NO-ERROR.
            IF NOT AVAILABLE pakbon THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Pakbon &1 not found":u, piPaknr), 404).

            DELETE pakbon.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Marks a pakbon as afgehaald (picked up): sets afgehaald
                 = true, afgehaaldId from the body, afgehaaldDatum =
                 TODAY, afgehaaldUur = STRING(TIME, "HH:MM:SS").
        Errors : AppError 404 - not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE AfhalenPakbon( INPUT piPaknr AS INTEGER, INPUT pcAfgehaaldId AS CHARACTER ):

        EMPTY TEMP-TABLE ttPakbon.

        DO TRANSACTION:
            FIND FIRST pakbon EXCLUSIVE-LOCK WHERE pakbon.paknr EQ piPaknr NO-ERROR.
            IF NOT AVAILABLE pakbon THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Pakbon &1 not found":u, piPaknr), 404).

            ASSIGN
                pakbon.afgehaald        = TRUE
                pakbon.afgehaald-id     = pcAfgehaaldId
                pakbon.afgehaald-datum  = TODAY
                pakbon.afgehaald-uur    = STRING(TIME, "HH:MM:SS":u)
                .

            CREATE ttPakbon.
            CopyToTt( BUFFER pakbon, BUFFER ttPakbon ).
        END.

        RETURN TEMP-TABLE ttPakbon:HANDLE.

    END METHOD.

END CLASS.

