/*------------------------------------------------------------------------
    File        : StockBewegingBE.cls
    Purpose     : Business Entity for booking manual stock movements
                  (correcties, ontvangst, transfer extern/intern) against
                  `artikel` + an append-only `artlog` ledger row. Deliberately
                  named without an "NPP" prefix - this is caller-agnostic
                  core stock-ledger logic (architect's explicit decision),
                  even though only Luna.Web.NPPStockBewegingHandler calls it
                  today.
    Movement-type mapping (exact, no deviation - see design doc):
                  correctie_plus   -> artlog.beweging "S", artikel.aantal +aantal
                  correctie_min    -> artlog.beweging "S", artikel.aantal -aantal (negative-stock guard)
                  correctie_gelijk -> artlog.beweging "S", artikel.aantal set to aantal (absolute)
                  ontvangst        -> artlog.beweging "O", artikel.aantal +aantal
                  transfer_extern  -> artlog.beweging "E", artikel.aantal -aantal (negative-stock guard)
                  transfer_intern  -> artlog.beweging "T", artikel.aantal unchanged, artikel.magazijn -> nieuwMagazijn
                  "L"/"P"/"V" are used elsewhere in the legacy system for
                  unrelated flows and must never be reused here.
    Errors      : AppError 400 - validation failures (see per-method
                  comments below for the exact order/messages).
                  AppError 404 - artnr not found.
                  AppError 409 - negative-stock guard tripped
                  (correctie_min / transfer_extern only).
    Description : Owns all DB access for this feature - no direct DB
                  access is allowed from the WebHandler layer. All pure
                  input validation happens BEFORE any DB access/lock; the
                  artikel EXCLUSIVE-LOCK + artlog lijnnr EXCLUSIVE-LOCK
                  (for the concurrency-safe lijnnr) + all writes happen
                  inside a single DO TRANSACTION: block.
    Author(s)   : Devin
    Created     : 2026-09-19
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.StockBewegingBE:

    DEFINE TEMP-TABLE ttStockBewegingResult NO-UNDO SERIALIZE-NAME "items":u
        FIELD artnr        AS CHARACTER
        FIELD voorraad     AS DECIMAL
        FIELD magazijn     AS CHARACTER
        FIELD lijnnr        AS INTEGER
        FIELD datum        AS DATE
        FIELD uur          AS CHARACTER
        FIELD beweging     AS CHARACTER
        FIELD artlogAantal AS DECIMAL
        FIELD stock        AS DECIMAL
        FIELD opm          AS CHARACTER
        FIELD gebruikerId  AS CHARACTER.

    /*------------------------------------------------------------------------------
        Purpose: Validation step 1 - movementType must be one of the 6
                 supported values.
        Errors : AppError 400 ("Ongeldig of ontbrekend movementType":u).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ValidateMovementType( INPUT pcMovementType AS CHARACTER ):

        IF LOOKUP(pcMovementType, "correctie_plus,correctie_min,correctie_gelijk,ontvangst,transfer_extern,transfer_intern":u) EQ 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError("Ongeldig of ontbrekend movementType":u, 400).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validation steps 3-4 for the 5 "operator opm" movement
                 types (everything except transfer_intern) - aantal
                 present/parseable/sign-checked, opm length-checked.
        Errors : AppError 400, exact messages per the design doc.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DECIMAL ValidateAantalAndOpm(
        INPUT poBody AS JsonObject, INPUT pcMovementType AS CHARACTER, OUTPUT pcOpm AS CHARACTER ):

        DEFINE VARIABLE dAantal AS DECIMAL NO-UNDO.

        IF NOT poBody:Has("aantal":u) OR poBody:IsNull("aantal":u) THEN
            UNDO, THROW NEW Progress.Lang.AppError("aantal is verplicht":u, 400).

        dAantal = poBody:GetDecimal("aantal":u) NO-ERROR.

        IF ERROR-STATUS:ERROR THEN
            UNDO, THROW NEW Progress.Lang.AppError("Ongeldige waarde voor aantal":u, 400).

        IF pcMovementType EQ "correctie_gelijk":u THEN
        DO:
            IF dAantal LT 0 THEN
                UNDO, THROW NEW Progress.Lang.AppError("aantal mag niet negatief zijn":u, 400).
        END.
        ELSE
        DO:
            IF dAantal LE 0 THEN
                UNDO, THROW NEW Progress.Lang.AppError("aantal moet groter dan 0 zijn":u, 400).
        END.

        pcOpm = "":u.
        IF poBody:Has("opm":u) AND NOT poBody:IsNull("opm":u) THEN
            pcOpm = poBody:GetCharacter("opm":u).

        IF LENGTH(pcOpm) GT 30 THEN
            UNDO, THROW NEW Progress.Lang.AppError("Opmerking mag maximaal 30 tekens bevatten":u, 400).

        IF LENGTH(pcOpm) LT 10 THEN
            UNDO, THROW NEW Progress.Lang.AppError("Opmerking moet minstens 10 tekens bevatten":u, 400).

        RETURN dAantal.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validation step 5 for transfer_intern - nieuwMagazijn
                 present and within the artikel.magazijn field width
                 (CHARACTER X(10) - confirmed against
                 docs/db-analysis/schema_dump.txt).
        Errors : AppError 400, exact messages per the design doc.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER ValidateNieuwMagazijn( INPUT poBody AS JsonObject ):

        DEFINE VARIABLE cNieuwMagazijn AS CHARACTER NO-UNDO.

        cNieuwMagazijn = "":u.
        IF poBody:Has("nieuwMagazijn":u) AND NOT poBody:IsNull("nieuwMagazijn":u) THEN
            cNieuwMagazijn = TRIM(poBody:GetCharacter("nieuwMagazijn":u)).

        IF cNieuwMagazijn EQ "":u THEN
            UNDO, THROW NEW Progress.Lang.AppError("nieuwMagazijn is verplicht voor transfer intern":u, 400).

        IF LENGTH(cNieuwMagazijn) GT 10 THEN
            UNDO, THROW NEW Progress.Lang.AppError("nieuwMagazijn is te lang":u, 400).

        RETURN cNieuwMagazijn.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Also defensively re-checks the opm length cap (>30) for
                 transfer_intern even though the operator-supplied opm is
                 ignored for that type - per step 4's "applies to ALL
                 types defensively" rule. transfer_intern's own opm is
                 always auto-generated ("Transfer: <oud> -> <nieuw>"),
                 which by construction never exceeds 30 chars given the
                 X(10) magazijn cap, but the raw operator-supplied opm (if
                 any) in the request body is still checked here so a
                 caller sending a garbage opm on this type gets a clean
                 400 instead of it being silently ignored either way.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ValidateOpmLengthDefensive( INPUT poBody AS JsonObject ):

        DEFINE VARIABLE cOpm AS CHARACTER NO-UNDO.

        cOpm = "":u.
        IF poBody:Has("opm":u) AND NOT poBody:IsNull("opm":u) THEN
            cOpm = poBody:GetCharacter("opm":u).

        IF LENGTH(cOpm) GT 30 THEN
            UNDO, THROW NEW Progress.Lang.AppError("Opmerking mag maximaal 30 tekens bevatten":u, 400).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Main entry point - validates the request body (steps
                 1-5, all before any DB access/lock), then books the
                 movement atomically: artikel EXCLUSIVE-LOCK, negative-
                 stock guard, concurrency-safe lijnnr via a LAST artlog
                 EXCLUSIVE-LOCK on artlog-x1 (artnr, lijnnr) inside the
                 SAME transaction, artikel.aantal/magazijn update, CREATE
                 artlog, all inside one DO TRANSACTION: block.
        Errors : AppError 400 - see step comments below.
                 AppError 404 ("Artikel &1 not found":u) - artnr not found.
                 AppError 409 ("Onvoldoende voorraad ...":u) - negative
                 stock guard (correctie_min / transfer_extern only).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE BoekBeweging( INPUT poBody AS JsonObject, INPUT pcGebruikerKode AS CHARACTER ):

        DEFINE VARIABLE cArtnr         AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cMovementType  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dAantal        AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE cOpm           AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cNieuwMagazijn AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cBeweging      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dDelta         AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE dNieuwAantal   AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE cOudMagazijn   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iNieuwLijnnr   AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cArtlogOpm     AS CHARACTER NO-UNDO.

        /* Step 1: movementType. */
        cMovementType = "":u.
        IF poBody:Has("movementType":u) AND NOT poBody:IsNull("movementType":u) THEN
            cMovementType = poBody:GetCharacter("movementType":u).

        ValidateMovementType(cMovementType).

        /* Step 2: artnr. */
        cArtnr = "":u.
        IF poBody:Has("artnr":u) AND NOT poBody:IsNull("artnr":u) THEN
            cArtnr = TRIM(poBody:GetCharacter("artnr":u)).

        IF cArtnr EQ "":u THEN
            UNDO, THROW NEW Progress.Lang.AppError("artnr is verplicht":u, 400).

        /* Steps 3-5: type-specific validation, all before any DB access. */
        IF cMovementType EQ "transfer_intern":u THEN
        DO:
            ValidateOpmLengthDefensive(poBody).
            cNieuwMagazijn = ValidateNieuwMagazijn(poBody).
            dAantal        = 0.
            cOpm           = "":u.
        END.
        ELSE
        DO:
            dAantal = ValidateAantalAndOpm(poBody, cMovementType, OUTPUT cOpm).
        END.

        /* Step 6/7 + booking: all inside one transaction. */
        DO TRANSACTION:

            FIND FIRST artikel EXCLUSIVE-LOCK WHERE artikel.artnr EQ cArtnr NO-ERROR.

            IF NOT AVAILABLE artikel THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Artikel &1 not found":u, cArtnr), 404).

            /* Compute signed delta + resulting artikel.aantal, per the
               mapping table. */
            CASE cMovementType:
                WHEN "correctie_plus":u THEN
                    ASSIGN
                        cBeweging    = "S":u
                        dDelta       = dAantal
                        dNieuwAantal = artikel.aantal + dAantal
                        .
                WHEN "correctie_min":u THEN
                    ASSIGN
                        cBeweging    = "S":u
                        dDelta       = 0 - dAantal
                        dNieuwAantal = artikel.aantal - dAantal
                        .
                WHEN "correctie_gelijk":u THEN
                    ASSIGN
                        cBeweging    = "S":u
                        dDelta       = dAantal - artikel.aantal
                        dNieuwAantal = dAantal
                        .
                WHEN "ontvangst":u THEN
                    ASSIGN
                        cBeweging    = "O":u
                        dDelta       = dAantal
                        dNieuwAantal = artikel.aantal + dAantal
                        .
                WHEN "transfer_extern":u THEN
                    ASSIGN
                        cBeweging    = "E":u
                        dDelta       = 0 - dAantal
                        dNieuwAantal = artikel.aantal - dAantal
                        .
                WHEN "transfer_intern":u THEN
                    ASSIGN
                        cBeweging    = "T":u
                        dDelta       = 0
                        dNieuwAantal = artikel.aantal
                        .
            END CASE.

            /* Negative-stock guard - correctie_min / transfer_extern only,
               checked BEFORE writing anything. */
            IF (cMovementType EQ "correctie_min":u OR cMovementType EQ "transfer_extern":u)
                AND dNieuwAantal LT 0 THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Onvoldoende voorraad voor deze boeking (huidige voorraad: &1)":u, STRING(artikel.aantal)), 409).

            /* Concurrency-safe lijnnr - LAST artlog row for this artnr,
               EXCLUSIVE-LOCK, inside the same transaction as the artikel
               EXCLUSIVE-LOCK above. artlog-x1 (artnr, lijnnr) confirmed
               unique against docs/db-analysis/schema_dump.txt (same index
               ArtlogBE's class header documents for this artnr/lijnnr
               access pattern). Do NOT use NO-LOCK here. */
            FIND LAST artlog EXCLUSIVE-LOCK WHERE artlog.artnr EQ cArtnr
                USE-INDEX artlog-x1 NO-ERROR.

            iNieuwLijnnr = (IF AVAILABLE artlog THEN artlog.lijnnr ELSE 0) + 1.

            /* transfer_intern: capture the OLD magazijn for the
               auto-generated remark BEFORE overwriting it. */
            IF cMovementType EQ "transfer_intern":u THEN
                cOudMagazijn = artikel.magazijn.

            /* Update artikel.aantal (always) and artikel.magazijn (only
               for transfer_intern). */
            IF cMovementType EQ "transfer_intern":u THEN
                ASSIGN
                    artikel.aantal   = dNieuwAantal
                    artikel.magazijn = cNieuwMagazijn
                    .
            ELSE
                artikel.aantal = dNieuwAantal.

            IF cMovementType EQ "transfer_intern":u THEN
                cArtlogOpm = SUBSTITUTE("Transfer: &1 -> &2":u, cOudMagazijn, cNieuwMagazijn).
            ELSE
                cArtlogOpm = cOpm.

            CREATE artlog.
            ASSIGN
                artlog.artnr    = cArtnr
                artlog.lijnnr   = iNieuwLijnnr
                artlog.datum    = TODAY
                artlog.uur      = STRING(TIME, "HH:MM:SS":u)
                artlog.docnr    = "":u
                artlog.omschr   = artikel.omschr-n
                artlog.kllev    = 0
                artlog.naam     = "":u
                artlog.beweging = cBeweging
                artlog.aantal   = dDelta
                artlog.aprijs   = artikel.aprijs
                artlog.munt     = artikel.munt
                artlog.koers    = 1
                artlog.opm      = cArtlogOpm
                artlog.id       = pcGebruikerKode
                artlog.stock    = artikel.aantal /* post-write */
                .

            EMPTY TEMP-TABLE ttStockBewegingResult.
            CREATE ttStockBewegingResult.
            ASSIGN
                ttStockBewegingResult.artnr        = artikel.artnr
                ttStockBewegingResult.voorraad     = artikel.aantal
                ttStockBewegingResult.magazijn     = artikel.magazijn
                ttStockBewegingResult.lijnnr       = artlog.lijnnr
                ttStockBewegingResult.datum        = artlog.datum
                ttStockBewegingResult.uur          = artlog.uur
                ttStockBewegingResult.beweging     = artlog.beweging
                ttStockBewegingResult.artlogAantal = artlog.aantal
                ttStockBewegingResult.stock        = artlog.stock
                ttStockBewegingResult.opm          = artlog.opm
                ttStockBewegingResult.gebruikerId  = artlog.id
                .

        END. /* DO TRANSACTION - commits here */

        RETURN TEMP-TABLE ttStockBewegingResult:HANDLE.

    END METHOD.

END CLASS.
