/*------------------------------------------------------------------------
    File        : KlantAdresBE.cls
    Purpose     : Business Entity for the "klant-adr" (customer address)
                  table - a child of `klant` (linked via klnr), backing the
                  "adressen" list on the extended klant info tab. Full CRUD.
    Field map (JSON key -> klant-adr column):
                  klnr        -> klnr        (PK, immutable, from parent klant)
                  lijnnr      -> lijnnr      (PK, from body on create or
                                              auto-allocated, immutable)
                  naam        -> naam
                  naam1       -> naam1
                  adres       -> adres
                  postnr      -> postnr
                  stad        -> stad
                  standaard   -> standaard
    Syntax      : Called from Luna.Web.KlantHandler (GET/POST/PUT/DELETE
                  /web/klant/{klnr}/adres and
                  /web/klant/{klnr}/adres/{lijnnr})
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes. Callers are
                  expected to have already validated that the parent klant
                  (klnr) exists - see EnsureKlantExists.
                  "standaard" exclusivity: setting standaard = TRUE on
                  create/update clears standaard on every OTHER klant-adr
                  row for that klnr, in the same transaction. Setting it to
                  FALSE (or omitting it) never touches other rows. Deleting
                  the standaard row does NOT auto-promote another row - zero
                  standaard rows for a klnr is an accepted state.
    Author(s)   : Devin
    Created     : 2026-08-27
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.KlantAdresBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results (get/create/update) the WebHandler unwraps the
       first (and only) entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttKlantAdr NO-UNDO SERIALIZE-NAME 'items':u
        FIELD klnr      AS INTEGER   SERIALIZE-NAME 'klnr':u
        FIELD lijnnr    AS INTEGER   SERIALIZE-NAME 'lijnnr':u
        FIELD naam      AS CHARACTER SERIALIZE-NAME 'naam':u
        FIELD naam1     AS CHARACTER SERIALIZE-NAME 'naam1':u
        FIELD adres     AS CHARACTER SERIALIZE-NAME 'adres':u
        FIELD postnr    AS CHARACTER SERIALIZE-NAME 'postnr':u
        FIELD stad      AS CHARACTER SERIALIZE-NAME 'stad':u
        FIELD standaard AS LOGICAL   SERIALIZE-NAME 'standaard':u
        INDEX idx-lijnnr IS PRIMARY klnr lijnnr.

    /*------------------------------------------------------------------------------
        Purpose: Throws AppError 404 if the parent klant doesn't exist.
                 Called at the start of every method here so klant-adr CRUD
                 never silently operates on/under a non-existent customer.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureKlantExists( INPUT piKlnr AS INTEGER ):

        FIND FIRST klant NO-LOCK WHERE klant.klnr EQ piKlnr NO-ERROR.

        IF NOT AVAILABLE klant THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE('Klant &1 not found':u, piKlnr), 404).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Copies the fields from a `klant-adr` buffer into a
                 ttKlantAdr row, for use by every read/write method below.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbKlantAdr FOR klant-adr, BUFFER pbTt FOR ttKlantAdr ):

        ASSIGN
            pbTt.klnr      = pbKlantAdr.klnr
            pbTt.lijnnr    = pbKlantAdr.lijnnr
            pbTt.naam      = pbKlantAdr.naam
            pbTt.naam1     = pbKlantAdr.naam1
            pbTt.adres     = pbKlantAdr.adres
            pbTt.postnr    = pbKlantAdr.postnr
            pbTt.stad      = pbKlantAdr.stad
            pbTt.standaard = pbKlantAdr.standaard
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field (except `standaard` - see
                 ApplyStandaard) present in the JSON request body onto the
                 given `klant-adr` buffer. Fields absent from the body are
                 left untouched, so this also works for partial updates.
                 `klnr`/`lijnnr` are never touched here - they are set once
                 on create and are immutable.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbKlantAdr FOR klant-adr ):

        IF poBody:Has('naam':u)   THEN pbKlantAdr.naam   = poBody:GetCharacter('naam':u).
        IF poBody:Has('naam1':u)  THEN pbKlantAdr.naam1  = poBody:GetCharacter('naam1':u).
        IF poBody:Has('adres':u)  THEN pbKlantAdr.adres  = poBody:GetCharacter('adres':u).
        IF poBody:Has('postnr':u) THEN pbKlantAdr.postnr = poBody:GetCharacter('postnr':u).
        IF poBody:Has('stad':u)   THEN pbKlantAdr.stad   = poBody:GetCharacter('stad':u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies `standaard` from the JSON body (if present) onto
                 the given `klant-adr` buffer, and - only when it's being
                 set to TRUE - clears `standaard` on every OTHER klant-adr
                 row for the same klnr in the same transaction. Uses a
                 separate named buffer (bOther) for that sweep so it never
                 collides with pbKlantAdr, which may itself be an alias of
                 the default klant-adr buffer (e.g. when called from
                 Create/UpdateKlantAdres).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyStandaard( INPUT poBody AS JsonObject, BUFFER pbKlantAdr FOR klant-adr ):

        DEFINE BUFFER bOther FOR klant-adr.
        DEFINE VARIABLE lStandaard AS LOGICAL NO-UNDO.

        IF NOT poBody:Has('standaard':u) THEN RETURN.

        lStandaard = poBody:GetLogical('standaard':u).
        pbKlantAdr.standaard = lStandaard.

        IF lStandaard THEN
        DO:
            FOR EACH bOther EXCLUSIVE-LOCK
                WHERE bOther.klnr EQ pbKlantAdr.klnr
                  AND bOther.lijnnr NE pbKlantAdr.lijnnr
                  AND bOther.standaard EQ TRUE:
                bOther.standaard = FALSE.
            END.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns every klant-adr row for the given klnr, ordered by
                 lijnnr.
        Notes  : NO-LOCK read-only.
        Errors : AppError code 404 - the parent klnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetKlantAdressen( INPUT piKlnr AS INTEGER ):

        EnsureKlantExists( piKlnr ).

        EMPTY TEMP-TABLE ttKlantAdr.

        FOR EACH klant-adr NO-LOCK WHERE klant-adr.klnr EQ piKlnr BY klant-adr.lijnnr:
            CREATE ttKlantAdr.
            CopyToTt( BUFFER klant-adr, BUFFER ttKlantAdr ).
        END.

        RETURN TEMP-TABLE ttKlantAdr:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single klant-adr row by klnr+lijnnr, or an empty
                 ttKlantAdr if it doesn't exist (the WebHandler turns that
                 into a 404).
        Errors : AppError code 404 - the parent klnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetKlantAdres( INPUT piKlnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureKlantExists( piKlnr ).

        EMPTY TEMP-TABLE ttKlantAdr.

        FIND FIRST klant-adr NO-LOCK
            WHERE klant-adr.klnr EQ piKlnr
              AND klant-adr.lijnnr EQ piLijnnr NO-ERROR.

        IF AVAILABLE klant-adr THEN
        DO:
            CREATE ttKlantAdr.
            CopyToTt( BUFFER klant-adr, BUFFER ttKlantAdr ).
        END.

        RETURN TEMP-TABLE ttKlantAdr:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new klant-adr row under the given klnr.
                 - If `lijnnr` is omitted from the body: auto-allocated as
                   MAX(lijnnr for this klnr, default 0) + 10.
                 - If `lijnnr` is provided: must be a positive integer and
                   must not already exist for that klnr.
        Errors : AppError code 404 - the parent klnr doesn't exist.
                 AppError code 400 - adres/postnr/stad missing or blank; or
                 lijnnr invalid (explicit mode).
                 AppError code 409 - (explicit mode) lijnnr already exists
                 for this klnr.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateKlantAdres( INPUT piKlnr AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iLijnnr    AS INTEGER NO-UNDO.
        DEFINE VARIABLE lHasLijnnr AS LOGICAL NO-UNDO.

        EnsureKlantExists( piKlnr ).

        EMPTY TEMP-TABLE ttKlantAdr.

        IF NOT poBody:Has('adres':u)  OR poBody:GetCharacter('adres':u)  EQ '':u OR
           NOT poBody:Has('postnr':u) OR poBody:GetCharacter('postnr':u) EQ '':u OR
           NOT poBody:Has('stad':u)   OR poBody:GetCharacter('stad':u)   EQ '':u THEN
            UNDO, THROW NEW Progress.Lang.AppError('adres, postnr and stad are required':u, 400).

        lHasLijnnr = poBody:Has('lijnnr':u).

        IF lHasLijnnr THEN
        DO:
            iLijnnr = poBody:GetInteger('lijnnr':u) NO-ERROR.
            IF iLijnnr EQ ? OR iLijnnr LE 0 THEN
                UNDO, THROW NEW Progress.Lang.AppError('lijnnr must be a positive integer':u, 400).
        END.

        DO TRANSACTION:
            IF lHasLijnnr THEN
            DO:
                FIND FIRST klant-adr EXCLUSIVE-LOCK
                    WHERE klant-adr.klnr EQ piKlnr
                      AND klant-adr.lijnnr EQ iLijnnr NO-ERROR.
                IF AVAILABLE klant-adr THEN
                    UNDO, THROW NEW Progress.Lang.AppError(
                        SUBSTITUTE('Adres &1/&2 already exists':u, piKlnr, iLijnnr), 409).
            END.
            ELSE
            DO:
                FIND LAST klant-adr EXCLUSIVE-LOCK
                    WHERE klant-adr.klnr EQ piKlnr NO-ERROR.

                iLijnnr = (IF AVAILABLE klant-adr THEN klant-adr.lijnnr ELSE 0) + 10.
            END.

            CREATE klant-adr.
            ASSIGN
                klant-adr.klnr   = piKlnr
                klant-adr.lijnnr = iLijnnr
                .

            ApplyFields( INPUT poBody, BUFFER klant-adr ).
            ApplyStandaard( INPUT poBody, BUFFER klant-adr ).

            CREATE ttKlantAdr.
            CopyToTt( BUFFER klant-adr, BUFFER ttKlantAdr ).
        END.

        RETURN TEMP-TABLE ttKlantAdr:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing klant-adr row. Only fields present in
                 the JSON body are changed (partial update); `klnr`/`lijnnr`
                 are immutable.
        Errors : AppError code 404 - the parent klnr doesn't exist, or the
                 lijnnr doesn't exist under it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateKlantAdres(
        INPUT piKlnr   AS INTEGER,
        INPUT piLijnnr AS INTEGER,
        INPUT poBody   AS JsonObject ):

        EnsureKlantExists( piKlnr ).

        EMPTY TEMP-TABLE ttKlantAdr.

        DO TRANSACTION:
            FIND FIRST klant-adr EXCLUSIVE-LOCK
                WHERE klant-adr.klnr EQ piKlnr
                  AND klant-adr.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE klant-adr THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE('Adres &1/&2 not found':u, piKlnr, piLijnnr), 404).

            ApplyFields( INPUT poBody, BUFFER klant-adr ).
            ApplyStandaard( INPUT poBody, BUFFER klant-adr ).

            CREATE ttKlantAdr.
            CopyToTt( BUFFER klant-adr, BUFFER ttKlantAdr ).
        END.

        RETURN TEMP-TABLE ttKlantAdr:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a klant-adr row by klnr+lijnnr. Does NOT auto-
                 promote another row to standaard if the deleted row was the
                 standaard one - zero standaard rows is an accepted state.
        Errors : AppError code 404 - the parent klnr doesn't exist, or the
                 lijnnr doesn't exist under it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteKlantAdres( INPUT piKlnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureKlantExists( piKlnr ).

        DO TRANSACTION:
            FIND FIRST klant-adr EXCLUSIVE-LOCK
                WHERE klant-adr.klnr EQ piKlnr
                  AND klant-adr.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE klant-adr THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE('Adres &1/&2 not found':u, piKlnr, piLijnnr), 404).

            DELETE klant-adr.
        END.

    END METHOD.

END CLASS.
