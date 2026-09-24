/*------------------------------------------------------------------------
    File        : BonLijnReserveringBE.cls
    Purpose     : Business Entity backing
                  POST /web/bon/{bonnr}/lijn/{lijnnr}/reservering - stock
                  reservation adjustment for a single bonlijn. delta > 0
                  reserves stock, delta < 0 releases it. Resulting
                  bonlijn.gereserv must stay within [0, te-leveren].
                  Reuses Luna.BusinessLogic.BonBE:ApplyBomReservationDelta
                  for the BOM (artlijn) sub-component walk on
                  "gemengd"/BOM articles (artikel.soort EQ TRUE) - no
                  duplication of that walk.
    Effects (all in one transaction):
                  1. bonlijn.gereserv += delta (validated into [0, te-leveren])
                  2. artikel.gereserveerd += delta (on bonlijn.artnr)
                  3. for a BOM article: ApplyBomReservationDelta(delta)
                  4. if bon.type EQ "HERSTELLING": calls
                     BonHerstelBE:CheckAutoTransitionToInHerstelling
    Syntax      : Called from Luna.Web.BonHandler
                  (POST /web/bon/{bonnr}/lijn/{lijnnr}/reservering)
    Author(s)   : Devin
    Created     : 2026-09-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Luna.BusinessLogic.BonBE.
USING Luna.BusinessLogic.BonHerstelBE.
USING Luna.BusinessLogic.BonLijnBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.BonLijnReserveringBE:

    /* Deliberately an instance attribute, not a method-local variable. This
       BE is fetched via BonLijnBE:GetBonLijn() at the end of
       ApplyReservering() and its temp-table HANDLE is returned to the
       caller (BonHandler) for serialization. A method-local BonLijnBE
       variable would be the only reference keeping that object (and its
       instance temp-table) alive; ABL reference-counts objects, so the
       object - and the temp-table backing the returned HANDLE - would be
       destroyed the instant ApplyReservering() returns and the local
       variable goes out of scope, *before* BonHandler gets a chance to
       call WRITE-JSON on it ("Invalid handle... points to a deleted
       object" (3135), "Cannot access the WRITE-JSON attribute..." (3140) -
       reproduced live 2026-09-24). Storing it as an instance attribute
       instead ties its lifetime to THIS-OBJECT, which stays alive for as
       long as BonHandler's own local BonLijnReserveringBE variable does -
       i.e. through the rest of HandlePost(), well past the WRITE-JSON
       call. See the identical fix/explanation in
       Luna.BusinessLogic.BonLijnReserveringBevestigingBE, which had the
       same bug. */
    DEFINE PRIVATE VARIABLE oBonLijnBE AS BonLijnBE NO-UNDO.

    /*------------------------------------------------------------------------------
        Purpose: Applies a reservation delta to a bonlijn and returns the
                 full, updated bonlijn (same shape as
                 BonLijnBE:GetBonLijn).
        Errors : AppError 404 - bon or bonlijn not found.
                 AppError 400 - resulting gereserv would fall outside
                                [0, te-leveren].
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE ApplyReservering( INPUT piBonnr AS INTEGER, INPUT piLijnnr AS INTEGER, INPUT pdDelta AS DECIMAL ):

        DEFINE VARIABLE dNewGereserv AS DECIMAL NO-UNDO.
        DEFINE VARIABLE oBonBE       AS BonBE         NO-UNDO.
        DEFINE VARIABLE oBonHerstel  AS BonHerstelBE  NO-UNDO.
        DEFINE VARIABLE hResult      AS HANDLE        NO-UNDO.

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

        oBonBE = NEW BonBE().

        DO TRANSACTION:
            FIND FIRST bonlijn EXCLUSIVE-LOCK
                WHERE bonlijn.bonnr  EQ piBonnr
                  AND bonlijn.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bonlijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bonlijn &1/&2 not found":u, piBonnr, piLijnnr), 404).

            dNewGereserv = bonlijn.gereserv + pdDelta.

            IF dNewGereserv LT 0 THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Resulting gereserv &1 would drop below 0 for bonlijn &2/&3":u,
                        dNewGereserv, piBonnr, piLijnnr), 400).

            IF dNewGereserv GT bonlijn.te-leveren THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Resulting gereserv &1 would exceed teLeveren &2 for bonlijn &3/&4":u,
                        dNewGereserv, bonlijn.te-leveren, piBonnr, piLijnnr), 400).

            bonlijn.gereserv = dNewGereserv.

            FIND FIRST artikel EXCLUSIVE-LOCK WHERE artikel.artnr EQ bonlijn.artnr NO-ERROR.
            IF AVAILABLE artikel THEN
            DO:
                artikel.gereserveerd = artikel.gereserveerd + pdDelta.

                IF artikel.soort THEN
                    oBonBE:ApplyBomReservationDelta( BUFFER artikel, BUFFER bonlijn, BUFFER bon, pdDelta ).
            END.
            RELEASE artikel.

            IF bon.type EQ "HERSTELLING":u THEN
            DO:
                oBonHerstel = NEW BonHerstelBE().
                oBonHerstel:CheckAutoTransitionToInHerstelling( piBonnr ).
            END.
        END.

        oBonLijnBE = NEW BonLijnBE().
        hResult    = oBonLijnBE:GetBonLijn( piBonnr, piLijnnr ).

        RETURN hResult.

    END METHOD.

END CLASS.

