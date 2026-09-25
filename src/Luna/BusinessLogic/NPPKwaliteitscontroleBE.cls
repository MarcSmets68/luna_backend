/*------------------------------------------------------------------------
    File        : NPPKwaliteitscontroleBE.cls
    Purpose     : Business Entity for the NPP "kwaliteitscontrole" (QC)
                  workflow that replaces legacy NPPQC.w / NPPQCDetail.w /
                  NPPQCAfkeur.w. Owns all DB access for this feature - the
                  WebHandler layer never touches bonlijn/bon_led/bon_led_qc
                  directly.
    Eligibility : A bonlijn row is "eligible" (queue-listed / resumable /
                  not-yet-terminal) when:
                      bonlijn.ledmontage    EQ TRUE
                  AND bonlijn.gereserv      EQ 0
                  AND bonlijn.montage-datum EQ ?
                  AND bonlijn.stempel       NE "D"
                  AND bonlijn.montage       EQ TRUE
                  AND bonlijn.swLed         EQ TRUE
                  The last two conditions (montage/swLed) were added after
                  verifying the legacy queue query in NPPQC.w's
                  "vul-montage" procedure - the original architect design
                  doc only listed the first four; legacy actually also
                  requires bonlijn.montage AND bonlijn.swLed, otherwise
                  the queue would surface bonlijn rows that are not LED
                  montage lines at all. Documented back into the design
                  doc per AGENTS.md ("fix the design doc too").
    bonnr+groepnr -> bonlijn resolution: bonlijn-x11 (bonnr, groepnr) is
                  NOT unique (verified against docs/db-analysis/
                  schema_dump.txt - "No|No|Yes" = not-unique/not-primary/
                  active), and legacy's own queue-building loop
                  (NPPQC.w "vul-montage") iterates FOR EACH bonlijn and
                  creates one queue row PER bonlijn ROW (bonnr+lijnnr), not
                  per bonnr+groepnr - so in theory several bonlijn rows can
                  share a groepnr. In practice only one such row is ever
                  flagged ledmontage=TRUE for a given bonnr+groepnr at a
                  time (that's the whole point of the eligibility flags
                  above - they represent "this specific montage step is
                  currently awaiting QC"), so FIND FIRST bonlijn matching
                  the full eligibility WHERE clause scoped to bonnr+groepnr
                  is used everywhere below to resolve the row. This is an
                  operational assumption, not a schema-enforced guarantee -
                  flagged here explicitly per AGENTS.md instead of silently
                  guessing.
    Profielgroep resolution: verified against NPPQCDetail.w's
                  "vul-controlelijst" procedure - it does NOT read
                  bonlijn.profielgroep directly (that field, despite
                  existing on bonlijn as "Werkveld tbv NPP", is unused by
                  this flow). It instead joins
                  bon_led(bonnr,groepnr,led_lijn=1).artnr -> art_profiel.artnr
                  and reads art_profiel.profielgroep. Implemented exactly
                  that way below (ResolveProfielgroep).
    swComplex resolution: bon_led(bonnr,groepnr,led_lijn=0,lijnnr=32).switch1,
                  defaulting to FALSE if not found - verified identical to
                  NPPQCDetail.w.
    Fallback checklist: verified byte-for-byte against NPPQCDetail.w's
                  "vul-controlelijst-standaard" procedure - 16 items,
                  lijnnr 100..1600 step 100, same omschr text/order/swInfo
                  flags as the architect's design doc. No differences
                  found.
    controle values: this API uses "OK"/"N.v.t."/"Fout"/"Te controleren"
                  (per the architect's design doc) rather than legacy's
                  own internal browse values ("CHECK"/"NIET VAN
                  TOEPASSING"/"FOUT"/"Te controleren") - a deliberate
                  remapping for the new API contract, not a port bug.
    Author(s)   : Devin (backend-coder)
    Created     : 2026-09-30
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.NPPKwaliteitscontroleBE:

    DEFINE TEMP-TABLE ttQueueItem NO-UNDO SERIALIZE-NAME "items":u
        FIELD bonnr                AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD groepnr               AS INTEGER   SERIALIZE-NAME "groepnr":u
        FIELD lijnnr                AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD klant                 AS CHARACTER SERIALIZE-NAME "klant":u
        FIELD profielgroep          AS CHARACTER SERIALIZE-NAME "profielgroep":u
        FIELD montageDatum          AS DATE      SERIALIZE-NAME "montageDatum":u
        FIELD hasInProgressSession  AS LOGICAL   SERIALIZE-NAME "hasInProgressSession":u
        FIELD inProgressByOther     AS LOGICAL   SERIALIZE-NAME "inProgressByOther":u.

    DEFINE TEMP-TABLE ttChecklistItem NO-UNDO SERIALIZE-NAME "items":u
        FIELD lijnnr   AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD omschr   AS CHARACTER SERIALIZE-NAME "omschr":u
        FIELD swInfo   AS LOGICAL   SERIALIZE-NAME "swInfo":u
        FIELD controle AS CHARACTER SERIALIZE-NAME "controle":u
        FIELD info     AS CHARACTER SERIALIZE-NAME "info":u
        INDEX idx-lijnnr IS PRIMARY lijnnr.

    /*------------------------------------------------------------------------------
        Purpose: Is there currently an eligible (not-yet-terminal) bonlijn
                 row for this bonnr+groepnr - see class header for the
                 exact eligibility criteria and the bonnr+groepnr ->
                 bonlijn resolution caveat.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL IsEligible( INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER ):

        FIND FIRST bonlijn NO-LOCK
            WHERE bonlijn.bonnr         EQ piBonnr
              AND bonlijn.groepnr       EQ piGroepnr
              AND bonlijn.ledmontage    EQ TRUE
              AND bonlijn.gereserv      EQ 0
              AND bonlijn.montage-datum EQ ?
              AND bonlijn.stempel       NE "D":u
              AND bonlijn.montage       EQ TRUE
              AND bonlijn.swLed         EQ TRUE NO-ERROR.

        RETURN AVAILABLE bonlijn.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Self-QC guard - is the calling user (pcKode) the same
                 person who assembled this LVB (bon_led led_lijn=100
                 lijnnr=7 comp=pcKode)? Re-checked on every write path,
                 not just session start, per design.
        Errors : AppError 403 if the caller is the assembler.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CheckSelfQc( INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER, INPUT pcKode AS CHARACTER ):

        FIND FIRST bon_led NO-LOCK
            WHERE bon_led.bonnr    EQ piBonnr
              AND bon_led.groepnr  EQ piGroepnr
              AND bon_led.led_lijn EQ 100
              AND bon_led.lijnnr   EQ 7
              AND bon_led.comp     EQ pcKode NO-ERROR.

        IF AVAILABLE bon_led THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                "Je hebt deze LVB zelf gemonteerd " + CHR(151) + " zelfcontrole is niet toegestaan":u, 403).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Resolves profielgroep via bon_led(led_lijn=1).artnr ->
                 art_profiel.profielgroep - see class header, verified
                 against NPPQCDetail.w's "vul-controlelijst" procedure.
                 Returns "":u if no join match is found.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER ResolveProfielgroep( INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER ):

        DEFINE VARIABLE cProfielgroep AS CHARACTER NO-UNDO INITIAL "":u.

        FIND FIRST bon_led NO-LOCK
            WHERE bon_led.bonnr    EQ piBonnr
              AND bon_led.groepnr  EQ piGroepnr
              AND bon_led.led_lijn EQ 1 NO-ERROR.

        IF AVAILABLE bon_led THEN
        DO:
            FIND FIRST art_profiel NO-LOCK WHERE art_profiel.artnr EQ bon_led.artnr NO-ERROR.
            IF AVAILABLE art_profiel THEN
                cProfielgroep = art_profiel.profielgroep.
        END.

        RETURN cProfielgroep.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Resolves swComplex via bon_led(led_lijn=0,lijnnr=32).switch1,
                 defaulting to FALSE - verified against NPPQCDetail.w.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL ResolveSwComplex( INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER ):

        FIND FIRST bon_led NO-LOCK
            WHERE bon_led.bonnr    EQ piBonnr
              AND bon_led.groepnr  EQ piGroepnr
              AND bon_led.led_lijn EQ 0
              AND bon_led.lijnnr   EQ 32 NO-ERROR.

        RETURN (IF AVAILABLE bon_led THEN bon_led.switch1 ELSE FALSE).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Fills ttChecklistItem with the 16-item fallback list, byte
                 -for-byte identical to NPPQCDetail.w's
                 "vul-controlelijst-standaard" procedure.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BuildFallbackChecklist():

        DEFINE VARIABLE iLijnnr AS INTEGER NO-UNDO INITIAL 0.

        DEFINE VARIABLE cOmschrList AS CHARACTER NO-UNDO EXTENT 16.
        DEFINE VARIABLE lSwInfoList AS LOGICAL   NO-UNDO EXTENT 16.
        DEFINE VARIABLE i           AS INTEGER   NO-UNDO.

        ASSIGN
            cOmschrList[1]  = "Kleur profiel":u
            cOmschrList[2]  = "Afwerking profiel ANO - LAK":u
            cOmschrList[3]  = "Type profiel":u
            cOmschrList[4]  = "Vermogen led strip":u
            cOmschrList[5]  = "Lichtkleur":u
            cOmschrList[6]  = "Lengte profiel en cover zijn juist":u
            cOmschrList[7]  = "Controle beschadigingen":u
            cOmschrList[8]  = "De correcte voeding(en)":u
            cOmschrList[9]  = "De aansluitdraden zijn gelabeld":u
            cOmschrList[10] = "Aansluitklemmen zijn gelabeld":u
            cOmschrList[11] = "Werkt het geheel?":u
            cOmschrList[12] = "Positie in- en opbouwspots":u
            cOmschrList[13] = "Toebehoren mee voorzien":u
            cOmschrList[14] = "Montagehandleiding is toegevoegd":u
            cOmschrList[15] = "Hangtag getekend en bevestigd":u
            cOmschrList[16] = "OK voor uitlevering":u
            lSwInfoList[4]  = TRUE
            lSwInfoList[5]  = TRUE
            .

        DO i = 1 TO 16:
            iLijnnr = i * 100.
            CREATE ttChecklistItem.
            ASSIGN
                ttChecklistItem.lijnnr   = iLijnnr
                ttChecklistItem.omschr   = cOmschrList[i]
                ttChecklistItem.swInfo   = lSwInfoList[i]
                ttChecklistItem.controle = "Te controleren":u
                ttChecklistItem.info     = "":u
                .
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Builds the checklist for a profielgroep/swComplex
                 combination - QC_controlepunten rows if any match, else
                 the standard fallback list. Always leaves ttChecklistItem
                 populated with default controle="Te controleren"/info="".
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BuildChecklist( INPUT pcProfielgroep AS CHARACTER, INPUT plSwComplex AS LOGICAL ):

        EMPTY TEMP-TABLE ttChecklistItem.

        IF CAN-FIND(FIRST QC_controlepunten
            WHERE QC_controlepunten.profielgroep EQ pcProfielgroep
              AND QC_controlepunten.swComplex    EQ plSwComplex) THEN
        DO:
            FOR EACH QC_controlepunten NO-LOCK
                WHERE QC_controlepunten.profielgroep EQ pcProfielgroep
                  AND QC_controlepunten.swComplex    EQ plSwComplex:

                CREATE ttChecklistItem.
                ASSIGN
                    ttChecklistItem.lijnnr   = QC_controlepunten.lijnnr
                    ttChecklistItem.omschr   = QC_controlepunten.omschr
                    ttChecklistItem.swInfo   = QC_controlepunten.swInfo
                    ttChecklistItem.controle = "Te controleren":u
                    ttChecklistItem.info     = "":u
                    .
            END.
        END.
        ELSE
            BuildFallbackChecklist().

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: For each item in the already-built ttChecklistItem,
                 overlays controle/info from any matching bon_led_qc row
                 for this bonnr/groepnr/datum/volgnr. Items with no
                 matching row keep their default "Te controleren"/"":u.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID MergeExistingRows(
        INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER, INPUT pdDatum AS DATE, INPUT piVolgnr AS INTEGER ):

        FOR EACH ttChecklistItem:

            FIND FIRST bon_led_qc NO-LOCK
                WHERE bon_led_qc.bonnr   EQ piBonnr
                  AND bon_led_qc.groepnr EQ piGroepnr
                  AND bon_led_qc.datum   EQ pdDatum
                  AND bon_led_qc.volgnr  EQ piVolgnr
                  AND bon_led_qc.lijnnr  EQ ttChecklistItem.lijnnr NO-ERROR.

            IF AVAILABLE bon_led_qc THEN
                ASSIGN
                    ttChecklistItem.controle = bon_led_qc.controle
                    ttChecklistItem.info     = bon_led_qc.info
                    .
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /npp/kwaliteitscontrole/queue - lists eligible
                 bonlijn groups, enriched with klant naam, profielgroep
                 and per-row resumability flags for the calling user.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetQueue( INPUT pcKode AS CHARACTER ):

        EMPTY TEMP-TABLE ttQueueItem.

        FOR EACH bonlijn NO-LOCK
            WHERE bonlijn.ledmontage    EQ TRUE
              AND bonlijn.gereserv      EQ 0
              AND bonlijn.montage-datum EQ ?
              AND bonlijn.stempel       NE "D":u
              AND bonlijn.montage       EQ TRUE
              AND bonlijn.swLed         EQ TRUE:

            CREATE ttQueueItem.
            ASSIGN
                ttQueueItem.bonnr       = bonlijn.bonnr
                ttQueueItem.groepnr     = bonlijn.groepnr
                ttQueueItem.lijnnr      = bonlijn.lijnnr
                ttQueueItem.montageDatum = bonlijn.montage-datum
                ttQueueItem.profielgroep = ResolveProfielgroep(bonlijn.bonnr, bonlijn.groepnr)
                .

            FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ bonlijn.bonnr NO-ERROR.
            ttQueueItem.klant = (IF AVAILABLE bon THEN bon.naam ELSE "":u).

            FIND LAST bon_led_qc NO-LOCK
                WHERE bon_led_qc.bonnr   EQ bonlijn.bonnr
                  AND bon_led_qc.groepnr EQ bonlijn.groepnr
                  AND bon_led_qc.datum   EQ TODAY NO-ERROR.

            IF AVAILABLE bon_led_qc THEN
                ASSIGN
                    ttQueueItem.hasInProgressSession = TRUE
                    ttQueueItem.inProgressByOther    = (bon_led_qc.id NE pcKode)
                    .
            ELSE
                ASSIGN
                    ttQueueItem.hasInProgressSession = FALSE
                    ttQueueItem.inProgressByOther    = FALSE
                    .
        END.

        RETURN TEMP-TABLE ttQueueItem:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: POST /npp/kwaliteitscontrole/{bonnr}/{groepnr}/session -
                 start-or-resume. See class header + design doc for the
                 exact ordering of checks.
        Errors : AppError 404 - not eligible / not found.
                 AppError 403 - self-QC guard.
                 AppError 409 - in-progress session owned by another user.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE StartOrResumeSession(
        INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER, INPUT pcKode AS CHARACTER,
        OUTPUT piVolgnr AS INTEGER, OUTPUT pdDatum AS DATE, OUTPUT plResumed AS LOGICAL ):

        DEFINE VARIABLE cProfielgroep AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lSwComplex    AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE iNieuwVolgnr  AS INTEGER   NO-UNDO.

        IF NOT IsEligible(piBonnr, piGroepnr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Bonlijn niet gevonden voor bon &1 groep &2":u, piBonnr, piGroepnr), 404).

        CheckSelfQc(piBonnr, piGroepnr, pcKode).

        pdDatum = TODAY.

        FIND LAST bon_led_qc NO-LOCK
            WHERE bon_led_qc.bonnr   EQ piBonnr
              AND bon_led_qc.groepnr EQ piGroepnr
              AND bon_led_qc.datum   EQ TODAY NO-ERROR.

        IF AVAILABLE bon_led_qc THEN
        DO:
            IF bon_led_qc.id NE pcKode THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Deze controle is momenteel in bewerking door &1":u, bon_led_qc.id), 409).

            piVolgnr  = bon_led_qc.volgnr.
            plResumed = TRUE.

            cProfielgroep = ResolveProfielgroep(piBonnr, piGroepnr).
            lSwComplex    = ResolveSwComplex(piBonnr, piGroepnr).

            BuildChecklist(cProfielgroep, lSwComplex).
            MergeExistingRows(piBonnr, piGroepnr, pdDatum, piVolgnr).

            RETURN TEMP-TABLE ttChecklistItem:HANDLE.
        END.

        /* No resumable session - allocate a new volgnr and build a fresh
           checklist (all items default to "Te controleren":u/"":u). */
        cProfielgroep = ResolveProfielgroep(piBonnr, piGroepnr).
        lSwComplex    = ResolveSwComplex(piBonnr, piGroepnr).

        BuildChecklist(cProfielgroep, lSwComplex).

        DO TRANSACTION:
            FIND LAST bon_led_qc EXCLUSIVE-LOCK
                WHERE bon_led_qc.bonnr   EQ piBonnr
                  AND bon_led_qc.groepnr EQ piGroepnr
                  AND bon_led_qc.datum   EQ TODAY NO-ERROR.

            iNieuwVolgnr = (IF AVAILABLE bon_led_qc THEN bon_led_qc.volgnr ELSE 0) + 1.
        END.

        piVolgnr  = iNieuwVolgnr.
        plResumed = FALSE.

        RETURN TEMP-TABLE ttChecklistItem:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /npp/kwaliteitscontrole/{bonnr}/{groepnr}/session -
                 read-only peek at today's session, does NOT allocate a
                 new volgnr.
        Errors : AppError 404 ("QC-sessie niet gevonden":u) - no session
                 for today.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE PeekSession(
        INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER,
        OUTPUT piVolgnr AS INTEGER, OUTPUT pdDatum AS DATE ):

        DEFINE VARIABLE cProfielgroep AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lSwComplex    AS LOGICAL   NO-UNDO.

        FIND LAST bon_led_qc NO-LOCK
            WHERE bon_led_qc.bonnr   EQ piBonnr
              AND bon_led_qc.groepnr EQ piGroepnr
              AND bon_led_qc.datum   EQ TODAY NO-ERROR.

        IF NOT AVAILABLE bon_led_qc THEN
            UNDO, THROW NEW Progress.Lang.AppError("QC-sessie niet gevonden":u, 404).

        piVolgnr = bon_led_qc.volgnr.
        pdDatum  = TODAY.

        cProfielgroep = ResolveProfielgroep(piBonnr, piGroepnr).
        lSwComplex    = ResolveSwComplex(piBonnr, piGroepnr).

        BuildChecklist(cProfielgroep, lSwComplex).
        MergeExistingRows(piBonnr, piGroepnr, pdDatum, piVolgnr).

        RETURN TEMP-TABLE ttChecklistItem:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Approve transaction - see design doc / class header.
                 Single DO TRANSACTION:, EXCLUSIVE-LOCK on bonlijn + upsert
                 of the bon_led led_lijn=100/lijnnr=8 marker row. No
                 stock/artlog writes.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApproveSession( INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER, INPUT pcKode AS CHARACTER ):

        DO TRANSACTION:

            FIND FIRST bonlijn EXCLUSIVE-LOCK
                WHERE bonlijn.bonnr         EQ piBonnr
                  AND bonlijn.groepnr       EQ piGroepnr
                  AND bonlijn.ledmontage    EQ TRUE
                  AND bonlijn.gereserv      EQ 0
                  AND bonlijn.montage-datum EQ ?
                  AND bonlijn.stempel       NE "D":u
                  AND bonlijn.montage       EQ TRUE
                  AND bonlijn.swLed         EQ TRUE NO-ERROR.

            IF NOT AVAILABLE bonlijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bonlijn niet gevonden voor bon &1 groep &2":u, piBonnr, piGroepnr), 404).

            ASSIGN
                bonlijn.besteld            = 0
                bonlijn.gereserv           = bonlijn.te-leveren
                bonlijn.effectief-gereserv = bonlijn.te-leveren
                bonlijn.montage-datum      = TODAY
                .

            FIND FIRST bon_led EXCLUSIVE-LOCK
                WHERE bon_led.bonnr    EQ piBonnr
                  AND bon_led.groepnr  EQ piGroepnr
                  AND bon_led.led_lijn EQ 100
                  AND bon_led.lijnnr   EQ 8 NO-ERROR.

            IF NOT AVAILABLE bon_led THEN
            DO:
                CREATE bon_led.
                ASSIGN
                    bon_led.bonnr    = piBonnr
                    bon_led.groepnr  = piGroepnr
                    bon_led.led_lijn = 100
                    bon_led.lijnnr   = 8
                    bon_led.soort    = "PRODUCTIESTAP":u
                    .
            END.

            ASSIGN
                bon_led.switch1 = TRUE
                bon_led.comp    = pcKode
                bon_led.datum   = TODAY
                bon_led.opm     = "QC KLAAR":u
                .

        END. /* DO TRANSACTION */

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Reject transaction - see design doc / class header.
                 Single DO TRANSACTION:, EXCLUSIVE-LOCK on bonlijn +
                 dead-code cleanup (led_lijn=0/lijnnr=44) + upsert of the
                 bon_led led_lijn=100/lijnnr=8 afkeuring marker row. No
                 stock/artlog writes.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID RejectSession(
        INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER, INPUT pcKode AS CHARACTER, INPUT pcOpmerking AS CHARACTER ):

        DO TRANSACTION:

            FIND FIRST bonlijn EXCLUSIVE-LOCK
                WHERE bonlijn.bonnr         EQ piBonnr
                  AND bonlijn.groepnr       EQ piGroepnr
                  AND bonlijn.ledmontage    EQ TRUE
                  AND bonlijn.gereserv      EQ 0
                  AND bonlijn.montage-datum EQ ?
                  AND bonlijn.stempel       NE "D":u
                  AND bonlijn.montage       EQ TRUE
                  AND bonlijn.swLed         EQ TRUE NO-ERROR.

            IF NOT AVAILABLE bonlijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bonlijn niet gevonden voor bon &1 groep &2":u, piBonnr, piGroepnr), 404).

            ASSIGN
                bonlijn.ledmontage         = FALSE
                bonlijn.besteld            = bonlijn.te-leveren
                bonlijn.gereserv           = 0
                bonlijn.effectief-gereserv = 0
                bonlijn.opm                = (IF bonlijn.opm NE "":u THEN bonlijn.opm + CHR(13) ELSE bonlijn.opm) + pcOpmerking
                .

            FIND FIRST bon_led EXCLUSIVE-LOCK
                WHERE bon_led.bonnr    EQ piBonnr
                  AND bon_led.groepnr  EQ piGroepnr
                  AND bon_led.led_lijn EQ 0
                  AND bon_led.lijnnr   EQ 44 NO-ERROR.

            IF AVAILABLE bon_led THEN
                DELETE bon_led.

            FIND FIRST bon_led EXCLUSIVE-LOCK
                WHERE bon_led.bonnr    EQ piBonnr
                  AND bon_led.groepnr  EQ piGroepnr
                  AND bon_led.led_lijn EQ 100
                  AND bon_led.lijnnr   EQ 8 NO-ERROR.

            IF NOT AVAILABLE bon_led THEN
            DO:
                CREATE bon_led.
                ASSIGN
                    bon_led.bonnr    = piBonnr
                    bon_led.groepnr  = piGroepnr
                    bon_led.led_lijn = 100
                    bon_led.lijnnr   = 8
                    bon_led.soort    = "PRODUCTIESTAP":u
                    .
            END.

            ASSIGN
                bon_led.switch1 = FALSE
                bon_led.comp    = pcKode
                bon_led.datum   = TODAY
                bon_led.opm     = SUBSTITUTE("AFKEURING door &1 &2":u, pcKode, STRING(TODAY, "99/99/9999":u)) + CHR(13) + pcOpmerking
                .

        END. /* DO TRANSACTION */

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: PUT /npp/kwaliteitscontrole/{bonnr}/{groepnr}/{volgnr}/
                 items/{lijnnr} - validates + upserts one checklist answer,
                 then runs the auto-completion check (separate, sequential
                 transaction - not nested in the upsert).
        Errors : AppError 400 - invalid controle / missing info.
                 AppError 403 - self-QC guard.
                 AppError 404 - session/lijnnr not found.
                 AppError 409 - session already terminal.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateItem(
        INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER, INPUT piVolgnr AS INTEGER, INPUT piLijnnr AS INTEGER,
        INPUT poBody AS JsonObject, INPUT pcKode AS CHARACTER,
        OUTPUT plSessionComplete AS LOGICAL, OUTPUT pcOutcome AS CHARACTER ):

        DEFINE VARIABLE cControle     AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cInfo         AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lEligible     AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE lHasRows      AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE cProfielgroep AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lSwComplex    AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE cOmschr       AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lSwInfo       AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE iTotalItems   AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iAnsweredCount AS INTEGER  NO-UNDO.

        plSessionComplete = FALSE.
        pcOutcome         = "":u.

        /* Step 2: controle validation - "Te controleren":u is the unset
           default only, never a client-supplied value. */
        cControle = "":u.
        IF poBody:Has("controle":u) AND NOT poBody:IsNull("controle":u) THEN
            cControle = poBody:GetCharacter("controle":u).

        IF LOOKUP(cControle, "OK,N.v.t.,Fout":u) EQ 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError("Ongeldige waarde voor controle":u, 400).

        /* Step 3: session existence/terminal check. */
        lEligible = IsEligible(piBonnr, piGroepnr).
        lHasRows  = CAN-FIND(FIRST bon_led_qc
            WHERE bon_led_qc.bonnr   EQ piBonnr
              AND bon_led_qc.groepnr EQ piGroepnr
              AND bon_led_qc.datum   EQ TODAY
              AND bon_led_qc.volgnr  EQ piVolgnr).

        IF NOT lEligible THEN
        DO:
            IF lHasRows THEN
                UNDO, THROW NEW Progress.Lang.AppError("Deze QC-sessie is al afgerond":u, 409).
            ELSE
                UNDO, THROW NEW Progress.Lang.AppError("QC-sessie niet gevonden":u, 404).
        END.

        /* Resolve the checklist to validate piLijnnr + fetch its
           omschr/swInfo (never trust the client body for omschr). */
        cProfielgroep = ResolveProfielgroep(piBonnr, piGroepnr).
        lSwComplex    = ResolveSwComplex(piBonnr, piGroepnr).

        BuildChecklist(cProfielgroep, lSwComplex).

        /* Total expected checklist size - needed for the auto-completion
           check below. Counted here, before ttChecklistItem gets reused
           further down to build this method's single-item response row. */
        iTotalItems = 0.
        FOR EACH ttChecklistItem:
            iTotalItems = iTotalItems + 1.
        END.

        FIND FIRST ttChecklistItem WHERE ttChecklistItem.lijnnr EQ piLijnnr NO-ERROR.
        IF NOT AVAILABLE ttChecklistItem THEN
            UNDO, THROW NEW Progress.Lang.AppError("QC-sessie niet gevonden":u, 404).

        ASSIGN
            cOmschr = ttChecklistItem.omschr
            lSwInfo = ttChecklistItem.swInfo
            .

        /* Step 4: self-QC guard, re-checked here - a client could call
           this endpoint directly with a guessed volgnr/lijnnr. */
        CheckSelfQc(piBonnr, piGroepnr, pcKode).

        /* Step 5: swInfo/info validation. */
        cInfo = "":u.
        IF poBody:Has("info":u) AND NOT poBody:IsNull("info":u) THEN
            cInfo = TRIM(poBody:GetCharacter("info":u)).

        IF lSwInfo AND cControle EQ "OK":u THEN
        DO:
            IF cInfo EQ "":u THEN
                UNDO, THROW NEW Progress.Lang.AppError("info is verplicht voor dit controlepunt":u, 400).
        END.
        ELSE
            cInfo = "":u.

        /* Step 6: upsert - own small transaction. */
        DO TRANSACTION:
            FIND FIRST bon_led_qc EXCLUSIVE-LOCK
                WHERE bon_led_qc.bonnr   EQ piBonnr
                  AND bon_led_qc.groepnr EQ piGroepnr
                  AND bon_led_qc.datum   EQ TODAY
                  AND bon_led_qc.volgnr  EQ piVolgnr
                  AND bon_led_qc.lijnnr  EQ piLijnnr NO-ERROR.

            IF NOT AVAILABLE bon_led_qc THEN
            DO:
                CREATE bon_led_qc.
                ASSIGN
                    bon_led_qc.bonnr   = piBonnr
                    bon_led_qc.groepnr = piGroepnr
                    bon_led_qc.datum   = TODAY
                    bon_led_qc.volgnr  = piVolgnr
                    bon_led_qc.lijnnr  = piLijnnr
                    bon_led_qc.omschr  = cOmschr
                    .
            END.

            ASSIGN
                bon_led_qc.controle = cControle
                bon_led_qc.info     = cInfo
                bon_led_qc.id       = pcKode
                .
        END. /* DO TRANSACTION */

        EMPTY TEMP-TABLE ttChecklistItem.
        CREATE ttChecklistItem.
        ASSIGN
            ttChecklistItem.lijnnr   = piLijnnr
            ttChecklistItem.omschr   = cOmschr
            ttChecklistItem.swInfo   = lSwInfo
            ttChecklistItem.controle = cControle
            ttChecklistItem.info     = cInfo
            .

        /* Step 7: auto-completion check - separate, sequential
           transaction, not nested inside the upsert above.
           BUG FIXED: "Te controleren" is the in-memory default for items
           that were never answered - such items never get a persisted
           bon_led_qc row at all (per the incremental-save design), so a
           CAN-FIND checking for a *persisted* "Te controleren" row would
           never find one, and the session would incorrectly auto-complete
           after answering just a single non-Fout item, regardless of how
           many of the other checklist items were still untouched. The
           correct check compares the number of OK/N.v.t. answered rows
           against the FULL checklist size (iTotalItems, computed above) -
           this also correctly keeps a session open while any item is
           "Fout", since a Fout row does not count toward the total. */
        iAnsweredCount = 0.
        FOR EACH bon_led_qc NO-LOCK
            WHERE bon_led_qc.bonnr   EQ piBonnr
              AND bon_led_qc.groepnr EQ piGroepnr
              AND bon_led_qc.datum   EQ TODAY
              AND bon_led_qc.volgnr  EQ piVolgnr
              AND (bon_led_qc.controle EQ "OK":u OR bon_led_qc.controle EQ "N.v.t.":u):
            iAnsweredCount = iAnsweredCount + 1.
        END.

        IF iTotalItems GT 0 AND iAnsweredCount GE iTotalItems THEN
        DO:
            ApproveSession(piBonnr, piGroepnr, pcKode).
            ASSIGN
                plSessionComplete = TRUE
                pcOutcome         = "approved":u
                .
        END.

        RETURN TEMP-TABLE ttChecklistItem:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: POST /npp/kwaliteitscontrole/{bonnr}/{groepnr}/{volgnr}/
                 afkeur - rejects the session, running the Reject
                 transaction.
        Errors : AppError 400 - opmerking missing/blank.
                 AppError 404 - session not found.
                 AppError 409 - session already terminal.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID Afkeuren(
        INPUT piBonnr AS INTEGER, INPUT piGroepnr AS INTEGER, INPUT piVolgnr AS INTEGER,
        INPUT poBody AS JsonObject, INPUT pcKode AS CHARACTER ):

        DEFINE VARIABLE cOpmerking AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lEligible  AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE lHasRows   AS LOGICAL   NO-UNDO.

        cOpmerking = "":u.
        IF poBody:Has("opmerking":u) AND NOT poBody:IsNull("opmerking":u) THEN
            cOpmerking = TRIM(poBody:GetCharacter("opmerking":u)).

        IF cOpmerking EQ "":u THEN
            UNDO, THROW NEW Progress.Lang.AppError("opmerking is verplicht bij afkeuring":u, 400).

        lEligible = IsEligible(piBonnr, piGroepnr).
        lHasRows  = CAN-FIND(FIRST bon_led_qc
            WHERE bon_led_qc.bonnr   EQ piBonnr
              AND bon_led_qc.groepnr EQ piGroepnr
              AND bon_led_qc.datum   EQ TODAY
              AND bon_led_qc.volgnr  EQ piVolgnr).

        IF NOT lEligible THEN
        DO:
            IF lHasRows THEN
                UNDO, THROW NEW Progress.Lang.AppError("Deze QC-sessie is al afgerond":u, 409).
            ELSE
                UNDO, THROW NEW Progress.Lang.AppError("QC-sessie niet gevonden":u, 404).
        END.

        RejectSession(piBonnr, piGroepnr, pcKode, cOpmerking).

    END METHOD.

END CLASS.

