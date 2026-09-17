/*------------------------------------------------------------------------
    File        : BonLijnAutoReserveringBE.cls
    Purpose     : Automatic stock reservation triggered on bonlijn create
                  (Iteratie C, "automatische voorraadreservering bij POST
                  /web/bon/{bonnr}/lijn"). Separate class from the existing
                  manual reservation flow (Luna.BusinessLogic.
                  BonLijnReserveringBE, which remains unchanged and is
                  still used for the explicit/manual reservation endpoint)
                  - this class only fires from BonLijnBE:CreateBonLijn, is
                  never invoked directly from a WebHandler, and never opens
                  its own transaction (it always runs inside the caller's
                  DO TRANSACTION block).
    Logica      : ReserveerBijCreate(bonlijn, bon) - see method header for
                  the exact skip/clamp algorithm. Shortfalls (not enough
                  stock) are NOT an error - bonlijn.gereserv simply ends up
                  lower than bonlijn.te-leveren.
    Notes       : Deviation from the original design doc: the design doc
                  referenced Luna.BusinessLogic.BonBE:ApplyBomReservationDelta
                  as the precedent for the groepnr/off_aantal lookup
                  pattern. That method does not exist on `main` (it only
                  exists on the unmerged feature/orderbeheer-fase2 branch,
                  which this feature must not touch/depend on per the git
                  isolation rules). The equivalent lookup pattern DOES
                  already exist on `main` inside
                  Luna.BusinessLogic.BonBE:ReleaseBomReservations (the
                  groepnr<>0 -> FIND FIRST bonlijn OF bon WHERE groepnr EQ
                  ... AND subtotaal -> off_aantal block) - that is the
                  pattern duplicated here, per the "accepted duplication,
                  no refactor" instruction. If/when feature/orderbeheer-fase2
                  merges and introduces ApplyBomReservationDelta, this
                  duplicated block should be reconciled with it, but that is
                  out of scope for this iteration.
                  Also: bonlijn_productie's actual schema (see
                  docs/db-analysis/schema_dump.txt) has both `blijnnr` and
                  `lijnnr` fields (unique index on bonnr+blijnnr+lijnnr).
                  `blijnnr` is used here to store the parent bonlijn's
                  lijnnr, and `lijnnr` is used for the oplopend
                  sub-lijnnummer - this matches the design doc's intent
                  ("lijnnr van de parent bonlijn" + "oplopend
                  sub-lijnnummer") but not its literal field-name wording,
                  since bonlijn_productie has no single field that could
                  hold both. The component description is taken from
                  artikel.omschr-n (there is no plain `artikel.omschr`
                  field - omschr-n is the existing convention used
                  elsewhere, e.g. Luna.BusinessLogic.StockAvailabilityBE).
    Syntax      : Called from Luna.BusinessLogic.BonLijnBE:CreateBonLijn,
                  inside its existing DO TRANSACTION block, right after
                  ApplyFields() and before the ttBonLijn snapshot copy.
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. Runs entirely
                  within the caller's transaction (no DO TRANSACTION here);
                  writes use EXCLUSIVE-LOCK as required for a write.
    Author(s)   : Devin
    Created     : 2026-09-20
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.BonLijnAutoReserveringBE:

    /*------------------------------------------------------------------------------
        Purpose: Automatically reserves stock for a newly created bonlijn.
                 Skips silently (no error) when:
                   - the line is a non-item line (subtotaal/kolomtitel/
                     infolijn),
                   - the line is on hold (hold = TRUE),
                   - te-leveren <= 0,
                   - artnr is blank,
                   - the artikel doesn't exist, or isn't stock-tracked
                     (artikel.stock = FALSE).
                 Otherwise reserves MIN(te-leveren, beschikbaar) against
                 artikel.besteld-kl (beschikbaar = MAX(0, aantal -
                 besteld-kl - gereserveerd)), stores the reserved amount on
                 bonlijn.gereserv, and - for a BOM/"gemengd" artikel
                 (soort = TRUE) - additionally reserves each artlijn
                 component via ReserveerBomComponenten.
        Notes  : No own transaction - runs inside the caller's (BonLijnBE:
                 CreateBonLijn) DO TRANSACTION block.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID ReserveerBijCreate( BUFFER pbBonlijn FOR bonlijn, BUFFER pbBon FOR bon ):

        DEFINE VARIABLE dBeschikbaarTop AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dReserveerTop   AS DECIMAL NO-UNDO.

        IF pbBonlijn.subtotaal OR pbBonlijn.kolomtitel OR pbBonlijn.infolijn THEN RETURN.
        IF pbBonlijn.hold THEN RETURN.
        IF pbBonlijn.te-leveren LE 0 THEN RETURN.
        IF pbBonlijn.artnr EQ "":u THEN RETURN.

        FIND FIRST artikel EXCLUSIVE-LOCK WHERE artikel.artnr EQ pbBonlijn.artnr NO-ERROR.
        IF NOT AVAILABLE artikel OR NOT artikel.stock THEN
        DO:
            RELEASE artikel.
            RETURN.
        END.

        dBeschikbaarTop = MAX(0, artikel.aantal - artikel.besteld-kl - artikel.gereserveerd).
        dReserveerTop   = MAX(0, MIN(pbBonlijn.te-leveren, dBeschikbaarTop)).

        ASSIGN
            artikel.besteld-kl = artikel.besteld-kl + dReserveerTop
            pbBonlijn.gereserv = dReserveerTop
            .

        IF artikel.soort THEN
            ReserveerBomComponenten( BUFFER artikel, BUFFER pbBonlijn, BUFFER pbBon, dReserveerTop ).

        RELEASE artikel.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Reserves stock for each artlijn component (one level deep,
                 no recursion even if a component itself has soort = TRUE -
                 same OV-7-style rule as StockAvailabilityBE) of a BOM/
                 "gemengd" top artikel, and records the result as a
                 bonlijn_productie row per component. dOffAantal is looked
                 up via the same groepnr/subtotaal pattern as
                 Luna.BusinessLogic.BonBE:ReleaseBomReservations (see the
                 class-header Notes for why this is duplicated rather than
                 shared).
        Notes  : Component shortfalls are not an error - a component with
                 no stock-tracking or not found simply reserves 0
                 (dComponentGereserveerd = 0), and a bonlijn_productie row
                 is still created recording aantal (benodigd) vs. gereserv
                 (0 in that case).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ReserveerBomComponenten(
        BUFFER pbArtikel FOR artikel,
        BUFFER pbBonlijn FOR bonlijn,
        BUFFER pbBon     FOR bon,
        INPUT  pdReserveerTop AS DECIMAL ):

        DEFINE VARIABLE dOffAantal              AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dBenodigd               AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dBeschikbaarComp        AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dComponentGereserveerd  AS DECIMAL NO-UNDO.
        DEFINE VARIABLE iSubLijnnr              AS INTEGER NO-UNDO.

        DEFINE BUFFER bfBonlijn      FOR bonlijn.
        DEFINE BUFFER bfCompArtikel  FOR artikel.

        /* Same groepnr/off_aantal lookup pattern as
           Luna.BusinessLogic.BonBE:ReleaseBomReservations - see class-
           header Notes for why this is duplicated here rather than
           extracted into a shared helper. */
        IF pbBonlijn.groepnr NE 0 THEN
        DO:
            FIND FIRST bfBonlijn OF pbBon
                WHERE bfBonlijn.groepnr EQ pbBonlijn.groepnr
                  AND bfBonlijn.subtotaal NO-LOCK NO-ERROR.
            dOffAantal = (IF AVAILABLE bfBonlijn THEN bfBonlijn.off_aantal ELSE 1).
        END.
        ELSE dOffAantal = 1.
        IF dOffAantal = 0 THEN dOffAantal = 1.

        iSubLijnnr = 0.

        FOR EACH artlijn OF pbArtikel NO-LOCK:

            iSubLijnnr = iSubLijnnr + 1.

            dBenodigd = IF artlijn.swVast THEN (artlijn.aantal * dOffAantal)
                                           ELSE (pdReserveerTop * artlijn.aantal).

            FIND FIRST bfCompArtikel EXCLUSIVE-LOCK WHERE bfCompArtikel.artnr EQ artlijn.l-artnr NO-ERROR.

            IF AVAILABLE bfCompArtikel AND bfCompArtikel.stock THEN
            DO:
                dBeschikbaarComp       = MAX(0, bfCompArtikel.aantal - bfCompArtikel.pbesteld-kl - bfCompArtikel.gereserveerd).
                dComponentGereserveerd = MAX(0, MIN(dBenodigd, dBeschikbaarComp)).
                bfCompArtikel.pbesteld-kl = bfCompArtikel.pbesteld-kl + dComponentGereserveerd.
            END.
            ELSE dComponentGereserveerd = 0.

            CREATE bonlijn_productie.
            ASSIGN
                bonlijn_productie.bonnr   = pbBonlijn.bonnr
                bonlijn_productie.blijnnr = pbBonlijn.lijnnr
                bonlijn_productie.lijnnr  = iSubLijnnr
                bonlijn_productie.artnr   = artlijn.l-artnr
                bonlijn_productie.aantal  = dBenodigd
                bonlijn_productie.gereserv = dComponentGereserveerd
                bonlijn_productie.omschr  = (IF AVAILABLE bfCompArtikel THEN bfCompArtikel.omschr-n ELSE "":u)
                .

            RELEASE bfCompArtikel.
        END.

    END METHOD.

END CLASS.
