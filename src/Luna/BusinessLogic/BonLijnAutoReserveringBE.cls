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
    Notes       : Correction (bon-auto-reservering reconciliation, see
                  docs/architecture/bon-auto-reservering-design.md §3): an
                  earlier version of this comment claimed
                  Luna.BusinessLogic.BonBE:ApplyBomReservationDelta "does
                  not exist on main". That was stale - it DOES exist on
                  main (and is already reused by AnnuleerBon and
                  Luna.BusinessLogic.BonLijnReserveringBE) - it just isn't
                  the right tool for THIS method's job. ApplyBomReservationDelta
                  is a pure delta propagator for a caller that has already
                  decided the exact quantity to move (manual reserve /
                  annuleer); ReserveerBomComponenten below is a
                  provisioning + production-row-seeding step that must
                  independently determine per-component availability
                  (create-time is shortfall-tolerant) and leave an
                  auditable bonlijn_productie trail - forcing both jobs
                  into one method would need extra behavior-toggling flags
                  on the shared, already-relied-upon ApplyBomReservationDelta.
                  The design doc explicitly decided NOT to unify these two
                  BOM walks (depth 1 vs. 2, different side effects) -
                  see §3 for the full reasoning; this is a deliberate,
                  named, deferred follow-up, not an oversight. What IS
                  shared now: the groepnr/off_aantal lookup block below has
                  been extracted into Luna.BusinessLogic.BonBE:GetOffAantal
                  (PUBLIC), removing the actual duplication risk (a bug fix
                  landing in one copy and not the other) without touching
                  either method's depth or side-effect behavior.
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
USING Luna.BusinessLogic.BonBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.BonLijnAutoReserveringBE:

    /*------------------------------------------------------------------------------
        Purpose: Automatically reserves stock for a newly created bonlijn.
                 Skips silently (no error) when:
                   - the line is a non-item line (subtotaal/kolomtitel/
                     infolijn),
                   - the line is on hold (hold = TRUE),
                   - the parent bon is geparkeerd (bon.geparkeerd = TRUE) -
                     added per bon-auto-reservering design doc §4,
                     `bonlijn.hold` and `bon.geparkeerd` are separate
                     concepts and must be checked independently,
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
        IF pbBon.geparkeerd THEN RETURN.
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
                 (0 in that case). The groepnr/off_aantal lookup is done
                 via Luna.BusinessLogic.BonBE:GetOffAantal (PUBLIC, shared
                 with ApplyBomReservationDelta) - see class-header Notes
                 (design doc §3) for why this is now shared rather than
                 duplicated.
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
        DEFINE VARIABLE oBonBE                  AS BonBE   NO-UNDO.

        DEFINE BUFFER bfCompArtikel  FOR artikel.

        oBonBE     = NEW BonBE().
        dOffAantal = oBonBE:GetOffAantal( BUFFER pbBon, BUFFER pbBonlijn ).

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
