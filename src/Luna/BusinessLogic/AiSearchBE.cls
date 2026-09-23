/*------------------------------------------------------------------------
    File        : AiSearchBE.cls
    Purpose     : Business Entity for the AI-powered natural-language
                  search feature (POST /web/ai-search). Orchestrates:
                    1. Gemini (Luna.BusinessLogic.GeminiGateway) translates
                       the Dutch prompt into a strict-JSON "intent"
                       (entity/filters/aggregation/confidence).
                    2. ValidateIntentAgainstWhitelist checks that intent -
                       pure ABL, no LLM, no DB - against a hardcoded
                       whitelist of entities/fields/operators. This is the
                       ONLY gate between LLM output and the database: an
                       intent that doesn't pass is never used to query
                       anything, it just produces a "clarification" result.
                    3. A validated intent is translated into the EXISTING
                       typed parameters of the matching entity Business
                       Entity (BonBE/OfferteBE/KlantBE/ArtikelBE/FactuurBE/
                       BestelorderBE) - the LLM's text never reaches a
                       WHERE clause; only whitelisted field/operator/value
                       combinations do, through those BEs' own parameters.
                    4. Aggregates (count/sum/avg/min/max) are computed
                       here in ABL, deterministically, from the rows those
                       BEs returned - the LLM never calculates a number.
                    5. Gemini generates a short NL summary from a minimal,
                       already-authorized payload (aggregates + <=20
                       sample rows, fields already visible in `items`).
                       ValidateSummaryAgainstData re-checks every number in
                       that summary against the supplied data and discards
                       it (falling back to a deterministic template) on
                       any mismatch.
    Whitelist   : Hardcoded ABL temp-tables (ttWhitelistEntity/
                  ttWhitelistField), populated once per instance in the
                  constructor - NOT a new DB table, no schema change.
                  Deliberately scoped to fields/operators that the
                  existing entity BEs already expose as typed parameters
                  today (verified against their actual method signatures -
                  see the "Divergences from the original design doc"
                  note below); fields the architect's design listed but
                  that the underlying BE doesn't (yet) accept as a filter
                  are simply left off the whitelist for this iteration, so
                  a prompt implying them safely falls back to
                  "clarification" instead of silently being ignored.
    Divergences from the original design doc (docs/architecture -
    AI-search ontwerp), found while wiring this up against the real BEs:
                  - bon: `verzonden` (eq) needed a new parameter on
                    Luna.BusinessLogic.BonBE:GetBonnen (added, additive,
                    mirrors the existing `geparkeerd` tri-state filter) -
                    the flagship "openstaande orders" example needs both.
                    `datum`/`levDatum` are NOT in the whitelist - GetBonnen
                    has no date filter at all today; adding range-query
                    support there is out of scope for this iteration.
                  - offerte: `passief`/`verkocht`/`verloren` are NOT in the
                    whitelist - Luna.BusinessLogic.OfferteBE:GetOffertes
                    has no such parameters today (only klnr/offgroep/offnr/
                    naam). `bedrag`/`btw` aggregation is still supported.
                  - factuur: `datum` only supports the `eq` operator
                    (GetFacturen takes a single pdDatum, not a range) -
                    `range` on datum is NOT in the whitelist for factuur.
                  - artikel: `omschrijving` is deliberately NOT whitelisted
                    (matches the architect's note - existing 15.000-row
                    scan-depth cap/performance hotspot on
                    ArtikelBE:GetArtikelen, not to be made worse here).
                  These are the only differences from the original design
                  doc; every other entity/field/operator combination below
                  matches it. Flagging to the architect for a follow-up
                  design update rather than letting doc and code drift.
    Anti-hallucination check (ValidateSummaryAgainstData): a best-effort
                  sanity check, not a mathematically perfect one - it
                  compares the DIGITS of every number-like token in the
                  generated summary against the digits of every allowed
                  number (aggregates + sample field values), ignoring
                  decimal/thousands punctuation and skipping single-digit
                  tokens (to avoid false positives on incidental small
                  numbers in NL phrasing). Good enough to catch a model
                  inventing a materially different number; not a
                  guarantee against every conceivable false negative.
    Privacy note: see Luna.BusinessLogic.GeminiGateway class header - the
                  prompt and a small, already-authorized data sample are
                  sent to Google's external Gemini API. Deliberate,
                  approved tradeoff for this feature.
    Syntax      : Called from Luna.Web.AiSearchHandler (POST /web/ai-search)
    Description : Owns all DB access for this feature (via the existing
                  entity BEs) and all whitelist/aggregation/anti-
                  hallucination logic - no direct DB access and no
                  business logic in the WebHandler layer. NO-LOCK reads
                  only (delegated to the entity BEs).
    Author(s)   : Devin
    Created     : 2026-09-01
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.GeminiGateway.
USING Luna.BusinessLogic.BonBE.
USING Luna.BusinessLogic.OfferteBE.
USING Luna.BusinessLogic.KlantBE.
USING Luna.BusinessLogic.ArtikelBE.
USING Luna.BusinessLogic.FactuurBE.
USING Luna.BusinessLogic.BestelorderBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.AiSearchBE:

    DEFINE PRIVATE VARIABLE oGemini AS GeminiGateway NO-UNDO.

    /* Entity BE instances used by the Dispatch* methods below MUST be
       kept alive as instance fields here, not as local variables inside
       each Dispatch* method. The temp-tables those BEs return (ttBon,
       ttKlant, etc.) are instance-scoped to their owning BE object - if
       the only reference to that object is a local variable inside
       DispatchBon/DispatchKlant/etc., the object (and its temp-table)
       gets garbage-collected as soon as the Dispatch* method returns,
       making the returned HANDLE dangling by the time ComputeAggregates
       uses it further up the call stack in ExecuteSearch (observed as
       "Invalid handle (3135)" / "Cannot access DEFAULT-BUFFER-HANDLE
       (3140)" during testing). Keeping the BE instance referenced here,
       for the lifetime of this AiSearchBE instance (which spans the
       whole ExecuteSearch call, same as how WebHandlers like BonHandler
       keep their own oService field alive for the whole request), keeps
       the temp-table alive long enough to be used and serialized. */
    DEFINE PRIVATE VARIABLE oBonBEInstance         AS BonBE         NO-UNDO.
    DEFINE PRIVATE VARIABLE oOfferteBEInstance     AS OfferteBE     NO-UNDO.
    DEFINE PRIVATE VARIABLE oKlantBEInstance       AS KlantBE       NO-UNDO.
    DEFINE PRIVATE VARIABLE oArtikelBEInstance     AS ArtikelBE     NO-UNDO.
    DEFINE PRIVATE VARIABLE oFactuurBEInstance     AS FactuurBE     NO-UNDO.
    DEFINE PRIVATE VARIABLE oBestelorderBEInstance AS BestelorderBE NO-UNDO.

    /* Hardcoded whitelist - see class header. NOT a DB table. */
    DEFINE TEMP-TABLE ttWhitelistEntity NO-UNDO
        FIELD entity                 AS CHARACTER
        FIELD requiresSelectiveFilter AS LOGICAL
        FIELD maxPageSize            AS INTEGER
        FIELD aggFieldsCsv           AS CHARACTER
        INDEX idx-entity IS UNIQUE entity.

    DEFINE TEMP-TABLE ttWhitelistField NO-UNDO
        FIELD entity       AS CHARACTER
        FIELD fieldName    AS CHARACTER
        FIELD operatorsCsv AS CHARACTER
        FIELD isIndexed    AS LOGICAL
        INDEX idx-entity-field IS UNIQUE entity fieldName.

    /* Single-row result for the WebHandler - unwrapped there the same
       way DashboardHandler unwraps ttStatCards. `intent` is the
       validated intent, re-serialized to a JSON string (kept as a blob
       rather than a nested ProDataSet - see design doc). `items` is NOT
       part of this temp-table - the WebHandler stitches in the item
       handle returned separately by ExecuteSearch, same pattern as
       DashboardHandler does with 3 handles today. */
    DEFINE TEMP-TABLE ttAiSearchMeta NO-UNDO SERIALIZE-NAME "meta":u
        FIELD queryText            AS CHARACTER SERIALIZE-NAME "queryText":u
        FIELD resultType           AS CHARACTER SERIALIZE-NAME "resultType":u
        FIELD entity               AS CHARACTER SERIALIZE-NAME "entity":u
        FIELD intentJson           AS CHARACTER SERIALIZE-NAME "intent":u
        FIELD pageNr               AS INTEGER   SERIALIZE-NAME "page":u
        FIELD pageSize             AS INTEGER   SERIALIZE-NAME "pageSize":u
        FIELD hasMore              AS LOGICAL   SERIALIZE-NAME "hasMore":u
        FIELD summary              AS CHARACTER SERIALIZE-NAME "summary":u
        FIELD clarificationQuestion AS CHARACTER SERIALIZE-NAME "clarificationQuestion":u.

    /* Used for the `items` key when there is no entity result to return
       (clarification / no_results) - always empty, never CREATEd into. */
    DEFINE TEMP-TABLE ttEmptyItems NO-UNDO SERIALIZE-NAME "items":u
        FIELD unused AS CHARACTER SERIALIZE-HIDDEN.

    CONSTRUCTOR PUBLIC AiSearchBE():
        oGemini = NEW GeminiGateway().
        InitWhitelist().
    END CONSTRUCTOR.

    /*------------------------------------------------------------------------------
        Purpose: Populates the hardcoded whitelist temp-tables. See class
                 header for the "Divergences from the original design doc"
                 note - this is intentionally narrower than the original
                 architect design in a few places, matched to what the
                 underlying entity BEs actually support today.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID InitWhitelist():

        EMPTY TEMP-TABLE ttWhitelistEntity.
        EMPTY TEMP-TABLE ttWhitelistField.

        CREATE ttWhitelistEntity.
        ASSIGN
            ttWhitelistEntity.entity                 = "bon":u
            ttWhitelistEntity.requiresSelectiveFilter = TRUE
            ttWhitelistEntity.maxPageSize            = 50
            ttWhitelistEntity.aggFieldsCsv           = "bedrag":u
            .
        CREATE ttWhitelistEntity.
        ASSIGN
            ttWhitelistEntity.entity                 = "offerte":u
            ttWhitelistEntity.requiresSelectiveFilter = TRUE
            ttWhitelistEntity.maxPageSize            = 50
            ttWhitelistEntity.aggFieldsCsv           = "bedrag,btw":u
            .
        CREATE ttWhitelistEntity.
        ASSIGN
            ttWhitelistEntity.entity                 = "klant":u
            ttWhitelistEntity.requiresSelectiveFilter = TRUE
            ttWhitelistEntity.maxPageSize            = 50
            ttWhitelistEntity.aggFieldsCsv           = "saldo":u
            .
        CREATE ttWhitelistEntity.
        ASSIGN
            ttWhitelistEntity.entity                 = "artikel":u
            ttWhitelistEntity.requiresSelectiveFilter = TRUE
            ttWhitelistEntity.maxPageSize            = 50
            ttWhitelistEntity.aggFieldsCsv           = "voorraad,aankoopprijs,verkoopprijs":u
            .
        CREATE ttWhitelistEntity.
        ASSIGN
            ttWhitelistEntity.entity                 = "factuur":u
            ttWhitelistEntity.requiresSelectiveFilter = TRUE
            ttWhitelistEntity.maxPageSize            = 50
            ttWhitelistEntity.aggFieldsCsv           = "totaal,nBedrag,totBtw":u
            .
        CREATE ttWhitelistEntity.
        ASSIGN
            ttWhitelistEntity.entity                 = "bestelorder":u
            ttWhitelistEntity.requiresSelectiveFilter = TRUE
            ttWhitelistEntity.maxPageSize            = 50
            ttWhitelistEntity.aggFieldsCsv           = "bedrag":u
            .

        /* bon - matches Luna.BusinessLogic.BonBE:GetBonnen parameters. */
        AddField("bon":u, "klnr":u,       "eq":u,       TRUE).
        AddField("bon":u, "bonnr":u,      "prefix":u,   TRUE).
        AddField("bon":u, "type":u,       "eq":u,       FALSE).
        AddField("bon":u, "naam":u,       "contains":u, FALSE).
        AddField("bon":u, "geparkeerd":u, "eq":u,       FALSE).
        AddField("bon":u, "verzonden":u,  "eq":u,       FALSE).

        /* offerte - matches Luna.BusinessLogic.OfferteBE:GetOffertes. */
        AddField("offerte":u, "klnr":u,  "eq":u,       TRUE).
        AddField("offerte":u, "offnr":u, "prefix":u,   TRUE).
        AddField("offerte":u, "naam":u,  "contains":u, FALSE).

        /* klant - matches Luna.BusinessLogic.KlantBE:GetKlant/GetKlanten. */
        AddField("klant":u, "klnr":u, "eq":u,       TRUE).
        AddField("klant":u, "naam":u, "contains":u, FALSE).

        /* artikel - matches Luna.BusinessLogic.ArtikelBE:GetArtikelen.
           omschrijving deliberately NOT whitelisted - see class header. */
        AddField("artikel":u, "artnr":u, "prefix":u, TRUE).
        AddField("artikel":u, "groep":u, "eq":u,     FALSE).

        /* factuur - matches Luna.BusinessLogic.FactuurBE:GetFacturen.
           datum only supports eq (no range) - see class header. */
        AddField("factuur":u, "klnr":u,      "eq":u,       TRUE).
        AddField("factuur":u, "datum":u,     "eq":u,       TRUE).
        AddField("factuur":u, "projectnr":u, "eq":u,       TRUE).
        AddField("factuur":u, "naam":u,      "contains":u, FALSE).

        /* bestelorder - matches Luna.BusinessLogic.BestelorderBE:GetBestelorders. */
        AddField("bestelorder":u, "levnr":u, "eq":u,       TRUE).
        AddField("bestelorder":u, "ordnr":u, "prefix":u,   FALSE).
        AddField("bestelorder":u, "naam":u,  "contains":u, FALSE).

    END METHOD.

    METHOD PRIVATE VOID AddField(
        INPUT pcEntity AS CHARACTER, INPUT pcField AS CHARACTER,
        INPUT pcOperatorsCsv AS CHARACTER, INPUT plIndexed AS LOGICAL ):

        CREATE ttWhitelistField.
        ASSIGN
            ttWhitelistField.entity       = pcEntity
            ttWhitelistField.fieldName    = pcField
            ttWhitelistField.operatorsCsv = pcOperatorsCsv
            ttWhitelistField.isIndexed    = plIndexed
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Main entry point - see class header for the full
                 orchestration. Always produces a meta handle (ttAiSearchMeta,
                 1 row) and an items handle (either an entity BE's own
                 result temp-table, or the always-empty ttEmptyItems for
                 clarification/no_results) - never throws for anything the
                 design contract maps to a 200 (clarification/no_results
                 are 200s, not errors). Only throws AppError for the
                 documented HTTP error cases (400 - bad prompt, 502 -
                 stage 1 Gemini failure).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID ExecuteSearch(
        INPUT  pcPrompt AS CHARACTER,
        OUTPUT phMeta   AS HANDLE,
        OUTPUT phItems  AS HANDLE ):

        DEFINE VARIABLE cIntentRaw  AS CHARACTER         NO-UNDO.
        DEFINE VARIABLE oParser     AS ObjectModelParser NO-UNDO.
        DEFINE VARIABLE oIntent     AS JsonObject        NO-UNDO.
        DEFINE VARIABLE oFilters    AS JsonArray         NO-UNDO.
        DEFINE VARIABLE cEntity     AS CHARACTER         NO-UNDO.
        DEFINE VARIABLE cAggType    AS CHARACTER         NO-UNDO.
        DEFINE VARIABLE cAggField   AS CHARACTER         NO-UNDO.
        DEFINE VARIABLE cClarMsg    AS CHARACTER         NO-UNDO.
        DEFINE VARIABLE lValid      AS LOGICAL           NO-UNDO.
        DEFINE VARIABLE iPageSize   AS INTEGER           NO-UNDO INITIAL 25.
        DEFINE VARIABLE lHasMore    AS LOGICAL           NO-UNDO INITIAL FALSE.
        DEFINE VARIABLE hItems      AS HANDLE            NO-UNDO.
        DEFINE VARIABLE oAggregates AS JsonObject        NO-UNDO.
        DEFINE VARIABLE iCount      AS INTEGER           NO-UNDO.
        DEFINE VARIABLE cSummary    AS CHARACTER         NO-UNDO INITIAL ?.
        DEFINE VARIABLE cSummaryRaw AS CHARACTER         NO-UNDO.
        DEFINE VARIABLE oItemsRoot  AS JsonObject        NO-UNDO.
        DEFINE VARIABLE oItemsArr   AS JsonArray         NO-UNDO.
        DEFINE VARIABLE oSample     AS JsonArray         NO-UNDO.
        DEFINE VARIABLE lcItemsJson AS LONGCHAR          NO-UNDO.
        DEFINE VARIABLE i           AS INTEGER           NO-UNDO.

        pcPrompt = TRIM(pcPrompt).

        IF pcPrompt EQ "":u OR pcPrompt EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError("prompt is required":u, 400).

        IF LENGTH(pcPrompt) GT 500 THEN
            UNDO, THROW NEW Progress.Lang.AppError("prompt is too long (max 500 characters)":u, 400).

        /* STAGE 1 - Gemini prompt -> intent JSON. Failure here is a hard
           502 per the design contract. */
        TranslateOrThrow(pcPrompt, OUTPUT cIntentRaw).

        oParser = NEW ObjectModelParser().
        oIntent = CAST(oParser:Parse(cIntentRaw), JsonObject) NO-ERROR.

        IF NOT VALID-OBJECT(oIntent) THEN
        DO:
            /* Model returned something that isn't parseable JSON despite
               the JSON-only system instruction - the call itself
               succeeded, so this is "could not determine a concrete
               search", not a 502. */
            BuildClarificationResult(pcPrompt, GenericClarificationMessage(), OUTPUT phMeta, OUTPUT phItems).
            RETURN.
        END.

        lValid = ValidateIntentAgainstWhitelist(oIntent, OUTPUT cEntity, OUTPUT oFilters,
                     OUTPUT cAggType, OUTPUT cAggField, OUTPUT cClarMsg).

        IF NOT lValid THEN
        DO:
            BuildClarificationResult(pcPrompt, cClarMsg, OUTPUT phMeta, OUTPUT phItems).
            RETURN.
        END.

        FIND FIRST ttWhitelistEntity WHERE ttWhitelistEntity.entity EQ cEntity NO-ERROR.
        iPageSize = IF AVAILABLE ttWhitelistEntity THEN ttWhitelistEntity.maxPageSize ELSE 25.

        hItems = DispatchEntity(cEntity, oFilters, iPageSize, OUTPUT lHasMore).

        ComputeAggregates(hItems, cAggType, cAggField, OUTPUT oAggregates, OUTPUT iCount).

        IF iCount EQ 0 THEN
        DO:
            BuildNoResultsResult(pcPrompt, cEntity, oIntent, iPageSize, OUTPUT phMeta, OUTPUT phItems).
            RETURN.
        END.

        /* STAGE 2 - minimal, already-authorized payload: server-computed
           aggregates + at most 20 sample rows, using only the fields the
           user already sees in `items` (hItems IS the items response). */
        hItems:WRITE-JSON("LONGCHAR":u, lcItemsJson, TRUE).
        oItemsRoot = CAST(oParser:Parse(lcItemsJson), JsonObject).
        oItemsArr  = oItemsRoot:GetJsonArray("items":u).

        oSample = NEW JsonArray().
        DO i = 1 TO MINIMUM(20, oItemsArr:Length):
            oSample:Add(oItemsArr:GetJsonObject(i)).
        END.

        cSummaryRaw = GenerateSummaryOrNull(oAggregates, oSample).

        IF cSummaryRaw NE ? AND ValidateSummaryAgainstData(cSummaryRaw, oAggregates, oSample) THEN
            cSummary = cSummaryRaw.
        ELSE
            cSummary = BuildFallbackSummary(cEntity, iCount, cAggType, oAggregates).

        EMPTY TEMP-TABLE ttAiSearchMeta.
        CREATE ttAiSearchMeta.
        ASSIGN
            ttAiSearchMeta.queryText             = pcPrompt
            ttAiSearchMeta.resultType            = "results":u
            ttAiSearchMeta.entity                = cEntity
            ttAiSearchMeta.intentJson            = SerializeIntent(oIntent)
            ttAiSearchMeta.pageNr                = 1
            ttAiSearchMeta.pageSize              = iPageSize
            ttAiSearchMeta.hasMore               = lHasMore
            ttAiSearchMeta.summary               = cSummary
            ttAiSearchMeta.clarificationQuestion = ?
            .

        phMeta  = TEMP-TABLE ttAiSearchMeta:HANDLE.
        phItems = hItems.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Calls GeminiGateway:TranslateToIntent and maps ANY
                 AppError it throws (missing key, network failure,
                 timeout, empty response) to the exact user-facing Dutch
                 502 message from the design contract.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID TranslateOrThrow( INPUT pcPrompt AS CHARACTER, OUTPUT pcIntentRaw AS CHARACTER ):

        pcIntentRaw = oGemini:TranslateToIntent(pcPrompt).

        CATCH oError AS Progress.Lang.AppError:
            UNDO, THROW NEW Progress.Lang.AppError(
                "De AI-zoekfunctie is momenteel niet beschikbaar. Probeer het later opnieuw.":u, 502).
        END CATCH.

    END METHOD.

    METHOD PRIVATE CHARACTER GenericClarificationMessage():
        RETURN "Ik kon deze vraag niet omzetten naar een concrete zoekopdracht. Bedoel je orders, " +
               "offertes, klanten, artikelen, facturen of bestelorders? Voeg bv. een klant- of " +
               "ordernummer toe.":u.
    END METHOD.

    METHOD PRIVATE CHARACTER NonSelectiveClarificationMessage():
        RETURN "Deze zoekopdracht zou de hele database moeten doorzoeken. Kan je een klant-, " +
               "order- of artikelnummer toevoegen?":u.
    END METHOD.

    METHOD PRIVATE CHARACTER EntityPluralNl( INPUT pcEntity AS CHARACTER ):

        CASE pcEntity:
            WHEN "bon":u         THEN RETURN "orders":u.
            WHEN "offerte":u     THEN RETURN "offertes":u.
            WHEN "klant":u       THEN RETURN "klanten":u.
            WHEN "artikel":u     THEN RETURN "artikelen":u.
            WHEN "factuur":u     THEN RETURN "facturen":u.
            WHEN "bestelorder":u THEN RETURN "bestelorders":u.
        END CASE.

        RETURN "resultaten":u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Builds the {resultType: "clarification", entity: null,
                 intent: null, items: [], ...} response shape.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BuildClarificationResult(
        INPUT  pcPrompt AS CHARACTER,
        INPUT  pcMsg    AS CHARACTER,
        OUTPUT phMeta   AS HANDLE,
        OUTPUT phItems  AS HANDLE ):

        EMPTY TEMP-TABLE ttAiSearchMeta.
        EMPTY TEMP-TABLE ttEmptyItems.

        CREATE ttAiSearchMeta.
        ASSIGN
            ttAiSearchMeta.queryText             = pcPrompt
            ttAiSearchMeta.resultType            = "clarification":u
            ttAiSearchMeta.entity                = ?
            ttAiSearchMeta.intentJson            = ?
            ttAiSearchMeta.pageNr                = 1
            ttAiSearchMeta.pageSize              = 25
            ttAiSearchMeta.hasMore               = FALSE
            ttAiSearchMeta.summary               = ?
            ttAiSearchMeta.clarificationQuestion = pcMsg
            .

        phMeta  = TEMP-TABLE ttAiSearchMeta:HANDLE.
        phItems = TEMP-TABLE ttEmptyItems:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Builds the {resultType: "no_results", items: [], ...}
                 response shape - deterministic Dutch text, no second
                 Gemini call (design contract).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BuildNoResultsResult(
        INPUT  pcPrompt   AS CHARACTER,
        INPUT  pcEntity   AS CHARACTER,
        INPUT  poIntent   AS JsonObject,
        INPUT  piPageSize AS INTEGER,
        OUTPUT phMeta     AS HANDLE,
        OUTPUT phItems    AS HANDLE ):

        EMPTY TEMP-TABLE ttAiSearchMeta.
        EMPTY TEMP-TABLE ttEmptyItems.

        CREATE ttAiSearchMeta.
        ASSIGN
            ttAiSearchMeta.queryText             = pcPrompt
            ttAiSearchMeta.resultType            = "no_results":u
            ttAiSearchMeta.entity                = pcEntity
            ttAiSearchMeta.intentJson            = SerializeIntent(poIntent)
            ttAiSearchMeta.pageNr                = 1
            ttAiSearchMeta.pageSize              = piPageSize
            ttAiSearchMeta.hasMore               = FALSE
            ttAiSearchMeta.summary               = SUBSTITUTE("Er zijn geen &1 gevonden die aan deze zoekopdracht voldoen.":u,
                                                        EntityPluralNl(pcEntity))
            ttAiSearchMeta.clarificationQuestion = ?
            .

        phMeta  = TEMP-TABLE ttAiSearchMeta:HANDLE.
        phItems = TEMP-TABLE ttEmptyItems:HANDLE.

    END METHOD.

    METHOD PRIVATE CHARACTER SerializeIntent( INPUT poIntent AS JsonObject ):

        DEFINE VARIABLE lc AS LONGCHAR NO-UNDO.

        IF NOT VALID-OBJECT(poIntent) THEN
            RETURN ?.

        poIntent:WRITE(lc, FALSE).

        RETURN STRING(lc).

        CATCH oError AS Progress.Lang.Error:
            RETURN ?.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: STAGE 2 - builds the minimal payload ({aggregates,
                 sampleItems}) and calls GeminiGateway:GenerateSummary.
                 Never throws - returns ? on any failure so the caller
                 falls back to a deterministic template (design contract).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GenerateSummaryOrNull( INPUT poAggregates AS JsonObject, INPUT poSample AS JsonArray ):

        DEFINE VARIABLE oPayload AS JsonObject NO-UNDO.
        DEFINE VARIABLE lc       AS LONGCHAR   NO-UNDO.

        oPayload = NEW JsonObject().
        oPayload:Add("aggregates":u, poAggregates).
        oPayload:Add("sampleItems":u, poSample).
        oPayload:WRITE(lc, FALSE).

        RETURN oGemini:GenerateSummary(STRING(lc)).

        CATCH oError AS Progress.Lang.Error:
            RETURN ?.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Finds a filter for pcField in poFilters (the validated
                 intent's filter array) and returns its operator/value as
                 character. The system instruction given to Gemini
                 requires every filter value to be encoded as a JSON
                 string (even booleans/numbers), so GetCharacter is always
                 the right accessor here.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL GetFilter(INPUT poFilters AS JsonArray, INPUT pcField AS CHARACTER, OUTPUT pcOperator AS CHARACTER, OUTPUT pcValue AS CHARACTER):

        DEFINE VARIABLE iLoop AS INTEGER NO-UNDO.
        DEFINE VARIABLE oOneFilter AS JsonObject NO-UNDO.

        pcOperator = "":u.
        pcValue = "":u.

        IF NOT VALID-OBJECT(poFilters) THEN
            RETURN FALSE.

        DO iLoop = 1 TO poFilters:Length:
            oOneFilter = poFilters:GetJsonObject(iLoop).

            IF oOneFilter:Has("field":u) AND oOneFilter:GetCharacter("field":u) EQ pcField THEN
            DO:
                IF oOneFilter:Has("operator":u) THEN
                    pcOperator = oOneFilter:GetCharacter("operator":u) NO-ERROR.
                IF oOneFilter:Has("value":u) THEN
                    pcValue = oOneFilter:GetCharacter("value":u) NO-ERROR.
                IF pcOperator EQ ? THEN
                    pcOperator = "":u.
                IF pcValue EQ ? THEN
                    pcValue = "":u.
                RETURN TRUE.
            END.
        END.

        RETURN FALSE.

    END METHOD.

    METHOD PRIVATE CHARACTER NormalizeBoolFilter( INPUT pcValue AS CHARACTER ):

        DEFINE VARIABLE cVal AS CHARACTER NO-UNDO.

        cVal = LC(TRIM(pcValue)).

        IF LOOKUP(cVal, "true,1,yes,ja":u) GT 0 THEN
            RETURN "true":u.
        IF LOOKUP(cVal, "false,0,no,nee":u) GT 0 THEN
            RETURN "false":u.

        RETURN "":u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses a "YYYY-MM-DD" string into a DATE, or returns the
                 unknown value (?) if it isn't in that exact shape - used
                 for the factuur `datum` (eq) filter.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DATE ParseIsoDate( INPUT pcValue AS CHARACTER ):

        DEFINE VARIABLE iYear   AS INTEGER NO-UNDO.
        DEFINE VARIABLE iMonth  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iDay    AS INTEGER NO-UNDO.
        DEFINE VARIABLE dResult AS DATE    NO-UNDO.

        IF pcValue EQ ? OR LENGTH(pcValue) NE 10 THEN
            RETURN ?.

        IF SUBSTRING(pcValue, 5, 1) NE "-":u OR SUBSTRING(pcValue, 8, 1) NE "-":u THEN
            RETURN ?.

        iYear  = INTEGER(SUBSTRING(pcValue, 1, 4)) NO-ERROR.
        iMonth = INTEGER(SUBSTRING(pcValue, 6, 2)) NO-ERROR.
        iDay   = INTEGER(SUBSTRING(pcValue, 9, 2)) NO-ERROR.

        IF iYear EQ ? OR iMonth EQ ? OR iDay EQ ? THEN
            RETURN ?.

        dResult = DATE(iMonth, iDay, iYear) NO-ERROR.

        RETURN dResult.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Routes a validated entity + filter set to the matching
                 existing entity Business Entity, translating whitelisted
                 filters into that BE's own typed parameters. The LLM's
                 text never reaches a WHERE clause - only these typed
                 parameters do.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE HANDLE DispatchEntity(
        INPUT  pcEntity   AS CHARACTER,
        INPUT  poFilters  AS JsonArray,
        INPUT  piPageSize AS INTEGER,
        OUTPUT plHasMore  AS LOGICAL ):

        CASE pcEntity:
            WHEN "bon":u         THEN RETURN DispatchBon(poFilters, piPageSize, OUTPUT plHasMore).
            WHEN "offerte":u     THEN RETURN DispatchOfferte(poFilters, piPageSize, OUTPUT plHasMore).
            WHEN "klant":u       THEN RETURN DispatchKlant(poFilters, piPageSize, OUTPUT plHasMore).
            WHEN "artikel":u     THEN RETURN DispatchArtikel(poFilters, piPageSize, OUTPUT plHasMore).
            WHEN "factuur":u     THEN RETURN DispatchFactuur(poFilters, piPageSize, OUTPUT plHasMore).
            WHEN "bestelorder":u THEN RETURN DispatchBestelorder(poFilters, piPageSize, OUTPUT plHasMore).
        END CASE.

        plHasMore = FALSE.
        RETURN TEMP-TABLE ttEmptyItems:HANDLE.

    END METHOD.

    METHOD PRIVATE HANDLE DispatchBon( INPUT poFilters AS JsonArray, INPUT piPageSize AS INTEGER, OUTPUT plHasMore AS LOGICAL ):

        DEFINE VARIABLE cOp         AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cVal        AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iKlnr       AS INTEGER    NO-UNDO INITIAL 0.
        DEFINE VARIABLE cType       AS CHARACTER  NO-UNDO INITIAL "":u.
        DEFINE VARIABLE cBonnr      AS CHARACTER  NO-UNDO INITIAL "":u.
        DEFINE VARIABLE cNaam       AS CHARACTER  NO-UNDO INITIAL "":u.
        DEFINE VARIABLE cGeparkeerd AS CHARACTER  NO-UNDO INITIAL "":u.
        DEFINE VARIABLE cVerzonden  AS CHARACTER  NO-UNDO INITIAL "":u.

        IF GetFilter(poFilters, "klnr":u, OUTPUT cOp, OUTPUT cVal)       THEN iKlnr = INTEGER(cVal) NO-ERROR.
        IF GetFilter(poFilters, "type":u, OUTPUT cOp, OUTPUT cVal)       THEN cType = cVal.
        IF GetFilter(poFilters, "bonnr":u, OUTPUT cOp, OUTPUT cVal)      THEN cBonnr = cVal.
        IF GetFilter(poFilters, "naam":u, OUTPUT cOp, OUTPUT cVal)       THEN cNaam = cVal.
        IF GetFilter(poFilters, "geparkeerd":u, OUTPUT cOp, OUTPUT cVal) THEN cGeparkeerd = NormalizeBoolFilter(cVal).
        IF GetFilter(poFilters, "verzonden":u, OUTPUT cOp, OUTPUT cVal)  THEN cVerzonden = NormalizeBoolFilter(cVal).

        oBonBEInstance = NEW BonBE().

        RETURN oBonBEInstance:GetBonnen(iKlnr, cType, cBonnr, cNaam, 1, piPageSize, cGeparkeerd, cVerzonden, OUTPUT plHasMore).

    END METHOD.

    METHOD PRIVATE HANDLE DispatchOfferte( INPUT poFilters AS JsonArray, INPUT piPageSize AS INTEGER, OUTPUT plHasMore AS LOGICAL ):

        DEFINE VARIABLE cOp    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cVal   AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iKlnr  AS INTEGER    NO-UNDO INITIAL 0.
        DEFINE VARIABLE cOffnr AS CHARACTER  NO-UNDO INITIAL "":u.
        DEFINE VARIABLE cNaam  AS CHARACTER  NO-UNDO INITIAL "":u.

        IF GetFilter(poFilters, "klnr":u, OUTPUT cOp, OUTPUT cVal)  THEN iKlnr = INTEGER(cVal) NO-ERROR.
        IF GetFilter(poFilters, "offnr":u, OUTPUT cOp, OUTPUT cVal) THEN cOffnr = cVal.
        IF GetFilter(poFilters, "naam":u, OUTPUT cOp, OUTPUT cVal)  THEN cNaam = cVal.

        oOfferteBEInstance = NEW OfferteBE().

        RETURN oOfferteBEInstance:GetOffertes(iKlnr, "":u, cOffnr, cNaam, 1, piPageSize, OUTPUT plHasMore).

    END METHOD.

    METHOD PRIVATE HANDLE DispatchKlant( INPUT poFilters AS JsonArray, INPUT piPageSize AS INTEGER, OUTPUT plHasMore AS LOGICAL ):

        DEFINE VARIABLE cOp   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cVal  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iKlnr AS INTEGER   NO-UNDO INITIAL 0.
        DEFINE VARIABLE cNaam AS CHARACTER NO-UNDO INITIAL "":u.

        oKlantBEInstance = NEW KlantBE().

        IF GetFilter(poFilters, "klnr":u, OUTPUT cOp, OUTPUT cVal) THEN
        DO:
            iKlnr = INTEGER(cVal) NO-ERROR.
            plHasMore = FALSE.
            RETURN oKlantBEInstance:GetKlant(iKlnr).
        END.

        IF GetFilter(poFilters, "naam":u, OUTPUT cOp, OUTPUT cVal) THEN cNaam = cVal.

        RETURN oKlantBEInstance:GetKlanten(1, piPageSize, cNaam, FALSE, OUTPUT plHasMore).

    END METHOD.

    METHOD PRIVATE HANDLE DispatchArtikel( INPUT poFilters AS JsonArray, INPUT piPageSize AS INTEGER, OUTPUT plHasMore AS LOGICAL ):

        DEFINE VARIABLE cOp     AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cVal    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cArtnr  AS CHARACTER  NO-UNDO INITIAL "":u.
        DEFINE VARIABLE cGroep  AS CHARACTER  NO-UNDO INITIAL "":u.

        IF GetFilter(poFilters, "artnr":u, OUTPUT cOp, OUTPUT cVal) THEN cArtnr = cVal.
        IF GetFilter(poFilters, "groep":u, OUTPUT cOp, OUTPUT cVal) THEN cGroep = cVal.

        oArtikelBEInstance = NEW ArtikelBE().

        RETURN oArtikelBEInstance:GetArtikelen(cArtnr, "":u, cGroep, 1, piPageSize, "":u, FALSE, "":u, OUTPUT plHasMore).

    END METHOD.

    METHOD PRIVATE HANDLE DispatchFactuur( INPUT poFilters AS JsonArray, INPUT piPageSize AS INTEGER, OUTPUT plHasMore AS LOGICAL ):

        DEFINE VARIABLE cOp        AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cVal       AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iKlnr      AS INTEGER   NO-UNDO INITIAL 0.
        DEFINE VARIABLE cNaam      AS CHARACTER NO-UNDO INITIAL "":u.
        DEFINE VARIABLE dDatum     AS DATE      NO-UNDO.
        DEFINE VARIABLE iProjectnr AS INTEGER   NO-UNDO INITIAL 0.

        IF GetFilter(poFilters, "klnr":u, OUTPUT cOp, OUTPUT cVal)      THEN iKlnr = INTEGER(cVal) NO-ERROR.
        IF GetFilter(poFilters, "naam":u, OUTPUT cOp, OUTPUT cVal)      THEN cNaam = cVal.
        IF GetFilter(poFilters, "datum":u, OUTPUT cOp, OUTPUT cVal)     THEN dDatum = ParseIsoDate(cVal).
        IF GetFilter(poFilters, "projectnr":u, OUTPUT cOp, OUTPUT cVal) THEN iProjectnr = INTEGER(cVal) NO-ERROR.

        oFactuurBEInstance = NEW FactuurBE().

        RETURN oFactuurBEInstance:GetFacturen(iKlnr, cNaam, dDatum, iProjectnr, 1, piPageSize, OUTPUT plHasMore).

    END METHOD.

    METHOD PRIVATE HANDLE DispatchBestelorder( INPUT poFilters AS JsonArray, INPUT piPageSize AS INTEGER, OUTPUT plHasMore AS LOGICAL ):

        DEFINE VARIABLE cOp    AS CHARACTER     NO-UNDO.
        DEFINE VARIABLE cVal   AS CHARACTER     NO-UNDO.
        DEFINE VARIABLE iLevnr AS INTEGER       NO-UNDO INITIAL 0.
        DEFINE VARIABLE cOrdnr AS CHARACTER     NO-UNDO INITIAL "":u.
        DEFINE VARIABLE cNaam  AS CHARACTER     NO-UNDO INITIAL "":u.

        IF GetFilter(poFilters, "levnr":u, OUTPUT cOp, OUTPUT cVal) THEN iLevnr = INTEGER(cVal) NO-ERROR.
        IF GetFilter(poFilters, "ordnr":u, OUTPUT cOp, OUTPUT cVal) THEN cOrdnr = cVal.
        IF GetFilter(poFilters, "naam":u, OUTPUT cOp, OUTPUT cVal)  THEN cNaam = cVal.

        oBestelorderBEInstance = NEW BestelorderBE().

        RETURN oBestelorderBEInstance:GetBestelorders(iLevnr, cOrdnr, cNaam, "":u, "":u, 1, piPageSize, OUTPUT plHasMore).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validates a Gemini-produced intent against the hardcoded
                 whitelist - pure ABL, no LLM, no DB. See class header;
                 this is the only gate between LLM output and the
                 database. Returns FALSE (with pcClarificationMsg set) for
                 any of: unwhitelisted entity, confidence < 0.6,
                 clarificationNeeded = true, an unwhitelisted field/
                 operator combination, an unwhitelisted aggregation field,
                 or (requiresSelectiveFilter) no filter on an indexed=true
                 field.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL ValidateIntentAgainstWhitelist(
        INPUT  poIntent           AS JsonObject,
        OUTPUT pcEntity           AS CHARACTER,
        OUTPUT poFilters          AS JsonArray,
        OUTPUT pcAggType          AS CHARACTER,
        OUTPUT pcAggField         AS CHARACTER,
        OUTPUT pcClarificationMsg AS CHARACTER ):

        DEFINE VARIABLE dConfidence AS DECIMAL NO-UNDO.
        DEFINE VARIABLE lClarNeeded AS LOGICAL NO-UNDO.
        DEFINE VARIABLE oAgg AS JsonObject NO-UNDO.
        DEFINE VARIABLE lHasSelective AS LOGICAL NO-UNDO INITIAL FALSE.
        DEFINE VARIABLE iLoop AS INTEGER NO-UNDO.
        DEFINE VARIABLE oOneFilter AS JsonObject NO-UNDO.
        DEFINE VARIABLE cField AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cOperator AS CHARACTER NO-UNDO.

        ASSIGN
            pcEntity           = ?
            poFilters          = ?
            pcAggType          = "":u
            pcAggField         = "":u
            pcClarificationMsg = GenericClarificationMessage()
            .

        pcEntity = poIntent:GetCharacter("entity":u) NO-ERROR.

        IF pcEntity EQ ? OR NOT CAN-FIND(FIRST ttWhitelistEntity WHERE ttWhitelistEntity.entity EQ pcEntity) THEN
        DO:
            pcEntity = ?.
            RETURN FALSE.
        END.

        dConfidence = poIntent:GetDecimal("confidence":u) NO-ERROR.
        IF dConfidence EQ ? THEN dConfidence = 0.

        lClarNeeded = poIntent:GetLogical("clarificationNeeded":u) NO-ERROR.
        IF lClarNeeded EQ ? THEN lClarNeeded = FALSE.

        IF lClarNeeded OR dConfidence LT 0.6 THEN
        DO:
            pcEntity = ?.
            RETURN FALSE.
        END.

        IF poIntent:Has("filters":u) THEN
            poFilters = poIntent:GetJsonArray("filters":u) NO-ERROR.
        IF NOT VALID-OBJECT(poFilters) THEN
            poFilters = NEW JsonArray().

        DO iLoop = 1 TO poFilters:Length:
            oOneFilter = poFilters:GetJsonObject(iLoop).

            cField = "":u.
            cOperator = "":u.
            IF oOneFilter:Has("field":u) THEN
                cField = oOneFilter:GetCharacter("field":u) NO-ERROR.
            IF oOneFilter:Has("operator":u) THEN
                cOperator = oOneFilter:GetCharacter("operator":u) NO-ERROR.

            IF LOOKUP(cOperator, "eq,prefix,contains,range":u) EQ 0 THEN
            DO:
                pcEntity = ?.
                RETURN FALSE.
            END.

            FIND FIRST ttWhitelistField
                WHERE ttWhitelistField.entity    EQ pcEntity
                  AND ttWhitelistField.fieldName EQ cField NO-ERROR.

            IF NOT AVAILABLE ttWhitelistField THEN
            DO:
                pcEntity = ?.
                RETURN FALSE.
            END.

            IF LOOKUP(cOperator, ttWhitelistField.operatorsCsv) EQ 0 THEN
            DO:
                pcEntity = ?.
                RETURN FALSE.
            END.

            IF ttWhitelistField.isIndexed THEN
                lHasSelective = TRUE.
        END.

        IF poIntent:Has("aggregation":u) THEN
        DO:
            oAgg = poIntent:GetJsonObject("aggregation":u) NO-ERROR.

            IF VALID-OBJECT(oAgg) THEN
            DO:
                IF oAgg:Has("type":u)  THEN pcAggType  = oAgg:GetCharacter("type":u) NO-ERROR.
                IF oAgg:Has("field":u) THEN pcAggField = oAgg:GetCharacter("field":u) NO-ERROR.

                IF pcAggType  EQ ? THEN pcAggType  = "":u.
                IF pcAggField EQ ? THEN pcAggField = "":u.

                IF pcAggType NE "":u THEN
                DO:
                    IF LOOKUP(pcAggType, "count,sum,avg,min,max":u) EQ 0 THEN
                    DO:
                        pcEntity = ?.
                        RETURN FALSE.
                    END.

                    IF pcAggType NE "count":u THEN
                    DO:
                        FIND FIRST ttWhitelistEntity WHERE ttWhitelistEntity.entity EQ pcEntity NO-ERROR.
                        IF NOT AVAILABLE ttWhitelistEntity
                            OR LOOKUP(pcAggField, ttWhitelistEntity.aggFieldsCsv) EQ 0 THEN
                        DO:
                            pcEntity = ?.
                            RETURN FALSE.
                        END.
                    END.
                END.
            END.
        END.

        FIND FIRST ttWhitelistEntity WHERE ttWhitelistEntity.entity EQ pcEntity NO-ERROR.

        IF AVAILABLE ttWhitelistEntity AND ttWhitelistEntity.requiresSelectiveFilter AND NOT lHasSelective THEN
        DO:
            pcEntity           = ?.
            pcClarificationMsg = NonSelectiveClarificationMessage().
            RETURN FALSE.
        END.

        RETURN TRUE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deterministic (no LLM) count + optional sum/avg/min/max
                 over the rows an entity BE returned, using a generic
                 QUERY over the temp-table handle so this works for every
                 entity's ttXxx shape without a per-entity branch.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ComputeAggregates(
        INPUT  phItems      AS HANDLE,
        INPUT  pcAggType    AS CHARACTER,
        INPUT  pcAggField   AS CHARACTER,
        OUTPUT poAggregates AS JsonObject,
        OUTPUT piCount      AS INTEGER ):

        DEFINE VARIABLE hBuf    AS HANDLE  NO-UNDO.
        DEFINE VARIABLE hQuery  AS HANDLE  NO-UNDO.
        DEFINE VARIABLE hField  AS HANDLE  NO-UNDO.
        DEFINE VARIABLE dVal    AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dSum    AS DECIMAL NO-UNDO INITIAL 0.
        DEFINE VARIABLE dMin    AS DECIMAL NO-UNDO INITIAL ?.
        DEFINE VARIABLE dMax    AS DECIMAL NO-UNDO INITIAL ?.
        DEFINE VARIABLE lWantField AS LOGICAL NO-UNDO.

        piCount    = 0.
        lWantField = pcAggType NE "":u AND pcAggType NE "count":u AND pcAggField NE "":u.

        hBuf = phItems:DEFAULT-BUFFER-HANDLE.

        CREATE QUERY hQuery.
        hQuery:SET-BUFFERS(hBuf).
        hQuery:QUERY-PREPARE(SUBSTITUTE("FOR EACH &1 NO-LOCK":u, hBuf:NAME)).
        hQuery:QUERY-OPEN().
        hQuery:GET-FIRST().

        DO WHILE NOT hQuery:QUERY-OFF-END:

            piCount = piCount + 1.

            IF lWantField THEN
            DO:
                hField = hBuf:BUFFER-FIELD(pcAggField) NO-ERROR.
                IF VALID-HANDLE(hField) THEN
                DO:
                    dVal = DECIMAL(hField:BUFFER-VALUE) NO-ERROR.
                    IF dVal NE ? THEN
                    DO:
                        dSum = dSum + dVal.
                        IF dMin EQ ? OR dVal LT dMin THEN dMin = dVal.
                        IF dMax EQ ? OR dVal GT dMax THEN dMax = dVal.
                    END.
                END.
            END.

            hQuery:GET-NEXT().
        END.

        hQuery:QUERY-CLOSE().
        DELETE OBJECT hQuery.

        poAggregates = NEW JsonObject().
        poAggregates:Add("count":u, piCount).

        IF lWantField THEN
        DO:
            CASE pcAggType:
                WHEN "sum":u THEN poAggregates:Add("sum":u, dSum).
                WHEN "avg":u THEN poAggregates:Add("avg":u, IF piCount GT 0 THEN dSum / piCount ELSE 0).
                WHEN "min":u THEN poAggregates:Add("min":u, IF dMin EQ ? THEN 0 ELSE dMin).
                WHEN "max":u THEN poAggregates:Add("max":u, IF dMax EQ ? THEN 0 ELSE dMax).
            END CASE.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Anti-hallucination sanity check (design point 9) - see
                 the "Anti-hallucination check" note in the class header
                 for the digit-comparison approach and its known
                 simplifications.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL ValidateSummaryAgainstData(
        INPUT pcSummary    AS CHARACTER,
        INPUT poAggregates AS JsonObject,
        INPUT poSample     AS JsonArray ):

        DEFINE VARIABLE cAllowedSource AS CHARACTER NO-UNDO INITIAL "":u.
        DEFINE VARIABLE cAllowedTokens AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cSummaryTokens AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cNames         AS CHARACTER NO-UNDO EXTENT.
        DEFINE VARIABLE i              AS INTEGER   NO-UNDO.
        DEFINE VARIABLE j              AS INTEGER   NO-UNDO.
        DEFINE VARIABLE oItem          AS JsonObject NO-UNDO.
        DEFINE VARIABLE dVal           AS DECIMAL   NO-UNDO.

        cNames = poAggregates:GetNames().
        IF EXTENT(cNames) NE ? THEN
        DO i = 1 TO EXTENT(cNames):
            dVal = poAggregates:GetDecimal(cNames[i]) NO-ERROR.
            IF dVal NE ? THEN
                cAllowedSource = cAllowedSource + " ":u + STRING(dVal).
        END.

        IF VALID-OBJECT(poSample) THEN
        DO i = 1 TO poSample:Length:
            oItem = poSample:GetJsonObject(i).
            cNames = oItem:GetNames() NO-ERROR.
            IF EXTENT(cNames) NE ? THEN
            DO j = 1 TO EXTENT(cNames):
                dVal = oItem:GetDecimal(cNames[j]) NO-ERROR.
                IF dVal NE ? THEN
                    cAllowedSource = cAllowedSource + " ":u + STRING(dVal).
            END.
        END.

        cAllowedTokens = ExtractNumberDigits(cAllowedSource).
        cSummaryTokens = ExtractNumberDigits(pcSummary).

        IF cSummaryTokens EQ "":u THEN
            RETURN TRUE.

        DO i = 1 TO NUM-ENTRIES(cSummaryTokens):
            IF LOOKUP(ENTRY(i, cSummaryTokens), cAllowedTokens) EQ 0 THEN
                RETURN FALSE.
        END.

        RETURN TRUE.

        CATCH oError AS Progress.Lang.Error:
            /* Fail closed - discard the generated summary rather than
               risk shipping an unverified number. */
            RETURN FALSE.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Extracts every number-like token from pcText (a maximal
                 run of digits/'.'/',' that contains at least one digit)
                 and normalizes each to a pure digit string (thousands/
                 decimal punctuation stripped) - see the class header note
                 on why punctuation is ignored rather than parsed
                 positionally. Tokens shorter than 2 digits are skipped
                 (avoids false positives on incidental single digits in
                 NL phrasing). Returns a comma-separated list.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER ExtractNumberDigits( INPUT pcText AS CHARACTER ):

        DEFINE VARIABLE cResult   AS CHARACTER NO-UNDO INITIAL "":u.
        DEFINE VARIABLE cCur      AS CHARACTER NO-UNDO INITIAL "":u.
        DEFINE VARIABLE lHasDigit AS LOGICAL   NO-UNDO INITIAL FALSE.
        DEFINE VARIABLE i         AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cCh       AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cNorm     AS CHARACTER NO-UNDO.

        IF pcText EQ ? THEN
            RETURN "":u.

        DO i = 1 TO LENGTH(pcText):
            cCh = SUBSTRING(pcText, i, 1).

            IF (cCh GE "0":u AND cCh LE "9":u) OR cCh EQ ".":u OR cCh EQ ",":u THEN
            DO:
                cCur = cCur + cCh.
                IF cCh GE "0":u AND cCh LE "9":u THEN lHasDigit = TRUE.
            END.
            ELSE
            DO:
                IF lHasDigit THEN
                DO:
                    cNorm = NormalizeDigitsOnly(cCur).
                    IF LENGTH(cNorm) GE 2 THEN
                        cResult = cResult + (IF cResult EQ "":u THEN "":u ELSE ",":u) + cNorm.
                END.
                ASSIGN cCur = "":u lHasDigit = FALSE.
            END.
        END.

        IF lHasDigit THEN
        DO:
            cNorm = NormalizeDigitsOnly(cCur).
            IF LENGTH(cNorm) GE 2 THEN
                cResult = cResult + (IF cResult EQ "":u THEN "":u ELSE ",":u) + cNorm.
        END.

        RETURN cResult.

    END METHOD.

    METHOD PRIVATE CHARACTER NormalizeDigitsOnly( INPUT pcToken AS CHARACTER ):

        DEFINE VARIABLE cOut AS CHARACTER NO-UNDO INITIAL "":u.
        DEFINE VARIABLE i    AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cCh  AS CHARACTER NO-UNDO.

        DO i = 1 TO LENGTH(pcToken):
            cCh = SUBSTRING(pcToken, i, 1).
            IF cCh GE "0":u AND cCh LE "9":u THEN
                cOut = cOut + cCh.
        END.

        RETURN cOut.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deterministic fallback summary (design point 9) - used
                 whenever Gemini's stage-2 summary is unavailable or fails
                 the anti-hallucination check. Only ever uses numbers
                 already computed server-side in ComputeAggregates.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER BuildFallbackSummary(
        INPUT pcEntity     AS CHARACTER,
        INPUT piCount      AS INTEGER,
        INPUT pcAggType    AS CHARACTER,
        INPUT poAggregates AS JsonObject ):

        DEFINE VARIABLE cBase AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dSum  AS DECIMAL   NO-UNDO.

        cBase = SUBSTITUTE("Er zijn &1 resultaten gevonden":u, piCount).

        IF pcAggType EQ "sum":u AND VALID-OBJECT(poAggregates) AND poAggregates:Has("sum":u) THEN
        DO:
            dSum = poAggregates:GetDecimal("sum":u) NO-ERROR.
            IF dSum NE ? THEN
                RETURN SUBSTITUTE("&1, met een totaalbedrag van &2.":u, cBase, FormatEuro(dSum)).
        END.

        RETURN cBase + ".":u.

    END METHOD.

    METHOD PRIVATE CHARACTER FormatEuro( INPUT pdValue AS DECIMAL ):
        RETURN CHR(8364) + TRIM(STRING(pdValue, "->>>,>>>,>>9.99":u)).
    END METHOD.

END CLASS.

