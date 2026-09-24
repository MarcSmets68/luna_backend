/*------------------------------------------------------------------------
    File        : BonLijnReserveringBevestigingBE.cls
    Purpose     : Business Entity backing
                  POST /web/bon/{bonnr}/lijn/{lijnnr}/reservering/bevestig
                  - "confirms" (moves from pending to confirmed) the
                  ENTIRE currently-held reservation for a single bonlijn.
                  Kept separate from Luna.BusinessLogic.BonLijnReserveringBE
                  (which owns the existing delta-adjustment reservation
                  action) - mirrors the existing pattern of one focused BE
                  per sub-resource action. See
                  docs/architecture/bon-auto-reservering-design.md section 2 for
                  the full design.
    Logica      : All-or-nothing, NOT idempotent (Marc rejected the new
                  `bonlijn.gereserv-bevestigd` field that a partial/
                  idempotent design would have needed - see design doc
                  section 2.1). Single public method Bevestig(piBonnr, piLijnnr) -
                  no amount parameter. Effects (all in one transaction):
                  1. dAmount = bonlijn.gereserv (the entire currently-held
                     amount - no partial option).
                  2. FIND FIRST artikel EXCLUSIVE-LOCK WHERE artikel.artnr
                     EQ bonlijn.artnr (no-op if not found, same permissive
                     convention as the create/manual paths).
                  3. artikel.besteld-kl = MAX(0, artikel.besteld-kl - dAmount);
                     artikel.gereserveerd += dAmount.
                  4. No BOM sub-component walk - sub-components only ever
                     track the single pbesteld-kl bucket (never a
                     confirmed/pending split, per design doc section 1), so there
                     is nothing to move there on confirm. Do NOT "fix" this
                     by calling BonBE:ApplyBomReservationDelta here.
                  5. CheckAutoTransitionToInHerstelling is NOT called here -
                     confirming never changes bonlijn.gereserv (only WHERE
                     that amount is accounted for on artikel), so it cannot
                     change that check's outcome.
                  Known, accepted limitation (design doc section 2.1): calling
                  this twice on the same line silently double-increments
                  artikel.gereserveerd by the full bonlijn.gereserv amount
                  a second time - there is no stored field to detect
                  "already confirmed". Mitigation is client-side only
                  (hide/disable the Bevestigen button after first use) -
                  not server-guaranteed. This is a deliberate, documented
                  trade-off, not a bug to silently patch around here.
    Syntax      : Called from Luna.Web.BonHandler
                  (POST /web/bon/{bonnr}/lijn/{lijnnr}/reservering/bevestig)
    Description : Owns all DB access for this feature - no direct DB
                  access is allowed from the WebHandler layer. NO-LOCK for
                  the initial bon existence read, EXCLUSIVE-LOCK within a
                  transaction for the bonlijn/artikel writes.
    Author(s)   : Devin
    Created     : 2026-09-24
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Luna.BusinessLogic.BonLijnBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.BonLijnReserveringBevestigingBE:

    /*------------------------------------------------------------------------------
        Purpose: Confirms the entire currently-held reservation
                 (bonlijn.gereserv) for a single bonlijn, moving that
                 amount from artikel.besteld-kl (pending) to
                 artikel.gereserveerd (confirmed). Returns the full,
                 updated bonlijn (same shape as BonLijnBE:GetBonLijn) -
                 bonlijn.gereserv itself is unchanged by this call (only
                 WHERE it's accounted for on artikel changes).
        Errors : AppError 404 - bon or bonlijn not found.
                 AppError 409 - bonlijn.stempel EQ "D" (geleverd), same
                                message convention as PUT .../lijn/{lijnnr}.
        Notes  : 200 OK no-op (no error) if bonlijn.gereserv EQ 0 - nothing
                 to confirm, e.g. a subtotaal/kolomtitel/infolijn row or a
                 shortfall-to-zero line. Not idempotent otherwise - see
                 class header / design doc section 2.1.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE Bevestig( INPUT piBonnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        DEFINE VARIABLE dAmount    AS DECIMAL NO-UNDO.
        DEFINE VARIABLE oBonLijnBE AS BonLijnBE NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE NO-UNDO.

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

        DO TRANSACTION:
            FIND FIRST bonlijn EXCLUSIVE-LOCK
                WHERE bonlijn.bonnr  EQ piBonnr
                  AND bonlijn.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bonlijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bonlijn &1/&2 not found":u, piBonnr, piLijnnr), 404).

            IF bonlijn.stempel EQ "D":u THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bonlijn &1/&2 has stempel 'D' (geleverd) and cannot be updated":u,
                        piBonnr, piLijnnr), 409).

            IF bonlijn.gereserv GT 0 THEN
            DO:
                dAmount = bonlijn.gereserv.

                FIND FIRST artikel EXCLUSIVE-LOCK WHERE artikel.artnr EQ bonlijn.artnr NO-ERROR.
                IF AVAILABLE artikel THEN
                    ASSIGN
                        artikel.besteld-kl   = MAX(0, artikel.besteld-kl - dAmount)
                        artikel.gereserveerd = artikel.gereserveerd + dAmount
                        .
                RELEASE artikel.
            END.
        END.

        oBonLijnBE = NEW BonLijnBE().
        hResult    = oBonLijnBE:GetBonLijn( piBonnr, piLijnnr ).

        RETURN hResult.

    END METHOD.

END CLASS.
