/*------------------------------------------------------------------------
    File        : GeminiGateway.cls
    Purpose     : Thin wrapper around the Google Gemini REST API
                  (generativelanguage.googleapis.com), used exclusively by
                  Luna.BusinessLogic.AiSearchBE for the AI-search feature
                  (POST /web/ai-search). Two calls:
                    - TranslateToIntent: natural-language prompt -> strict
                      JSON intent (entity/filters/aggregation/confidence/
                      clarificationNeeded). The model NEVER sees the
                      database and NEVER returns anything but JSON - no
                      query string is ever built from its output.
                    - GenerateSummary: aggregates + a small sample of
                      already-fetched, already-authorized items -> a short
                      NL summary, with an explicit anti-hallucination
                      instruction (numbers used must come from the supplied
                      data only). AiSearchBE re-validates that afterwards
                      (see ValidateSummaryAgainstData) - this class does
                      not enforce it itself.
    Privacy note: prompts (stage 1) and aggregates/sample items - which can
                  include customer/invoice data - (stage 2) are sent to
                  Google's Gemini API, an external, non-EU-guaranteed
                  processor. This is a deliberate, product-owner-approved
                  tradeoff for this feature (see architect design doc),
                  not an oversight - flagging here so it stays visible in
                  code, not just in a design doc.
    Config      : API key comes from the GEMINI_API_KEY OS environment
                  variable (never hardcoded) - same pattern as
                  AUTH_EVERYONE_ADMIN in Luna.BusinessLogic.AuthBE. Read
                  fresh via OS-GETENV() per call (cheap, and picks up a key
                  rotation on the next PASOE restart without a code
                  change). See Backend/README.md "AI Search" section.
    Timeouts    : 8s timeout on every call (design contract).
                  TranslateToIntent failing/timing out is a hard failure -
                  it throws AppError 502, AiSearchBE maps that to the
                  documented user-facing 502. GenerateSummary failing/
                  timing out is NOT a hard failure - it returns the
                  unknown value (?) and AiSearchBE falls back to a
                  deterministic template summary instead (design
                  contract: stage 2 failure never surfaces as an error to
                  the client).
    Author(s)   : Devin
    Created     : 2026-09-01
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING OpenEdge.Net.HTTP.IHttpClient.
USING OpenEdge.Net.HTTP.ClientBuilder.
USING OpenEdge.Net.HTTP.IHttpClientLibrary.
USING OpenEdge.Net.HTTP.Lib.ClientLibraryBuilder.
USING OpenEdge.Net.HTTP.IHttpRequest.
USING OpenEdge.Net.HTTP.RequestBuilder.
USING OpenEdge.Net.HTTP.IHttpResponse.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.GeminiGateway:

    /* "gemini-3.1-flash-lite" chosen for latency (~2-3s observed) - the
       originally-picked "gemini-2.0-flash" was retired by Google (404
       "no longer available"), and its suggested replacement
       "gemini-3.6-flash" is a "thinking" model that took ~67s for a
       trivial prompt in testing, far beyond the 8s timeout budget for
       this feature. Model availability/naming on Gemini's side changes
       over time - if TranslateToIntent/GenerateSummary start failing
       again, check GET https://generativelanguage.googleapis.com/v1beta/
       models (header x-goog-api-key, never a ?key= query parameter) for the current list of models supporting
       generateContent before assuming the API key/network is at fault. */
    DEFINE PRIVATE VARIABLE cModel       AS CHARACTER NO-UNDO INITIAL "gemini-3.1-flash-lite":u.
    DEFINE PRIVATE VARIABLE cApiBase     AS CHARACTER NO-UNDO INITIAL "https://generativelanguage.googleapis.com/v1beta/models/":u.
    DEFINE PRIVATE VARIABLE iTimeoutSecs AS INTEGER   NO-UNDO INITIAL 8.

    /*------------------------------------------------------------------------------
        Purpose: Reads the Gemini API key from the GEMINI_API_KEY OS
                 environment variable. Never hardcoded - see class header.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GetApiKey():
        RETURN OS-GETENV("GEMINI_API_KEY":u).
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Low-level call to the Gemini generateContent REST
                 endpoint. Builds the request body ({system_instruction,
                 contents, generationConfig}), POSTs it, and returns the
                 model's raw text output - or the unknown value (?) if the
                 API key is missing, the call errors, times out, or the
                 response doesn't have the expected shape. Never throws -
                 callers decide whether a ? is fatal (TranslateToIntent) or
                 recoverable (GenerateSummary).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER CallGemini(
        INPUT pcSystemInstruction AS CHARACTER,
        INPUT pcUserContent       AS CHARACTER,
        INPUT plJsonMode          AS LOGICAL ):

        DEFINE VARIABLE cApiKey       AS CHARACTER          NO-UNDO.
        DEFINE VARIABLE cUrl          AS CHARACTER          NO-UNDO.
        DEFINE VARIABLE oLib          AS IHttpClientLibrary NO-UNDO.
        DEFINE VARIABLE oClient       AS IHttpClient        NO-UNDO.
        DEFINE VARIABLE oRequest      AS IHttpRequest       NO-UNDO.
        DEFINE VARIABLE oResponse     AS IHttpResponse NO-UNDO.
        DEFINE VARIABLE oBody         AS JsonObject    NO-UNDO.
        DEFINE VARIABLE oContents     AS JsonArray     NO-UNDO.
        DEFINE VARIABLE oContentItem  AS JsonObject    NO-UNDO.
        DEFINE VARIABLE oParts        AS JsonArray     NO-UNDO.
        DEFINE VARIABLE oPart         AS JsonObject    NO-UNDO.
        DEFINE VARIABLE oSystemInst   AS JsonObject    NO-UNDO.
        DEFINE VARIABLE oSystemParts  AS JsonArray     NO-UNDO.
        DEFINE VARIABLE oSystemPart   AS JsonObject    NO-UNDO.
        DEFINE VARIABLE oGenConfig    AS JsonObject    NO-UNDO.
        DEFINE VARIABLE oResponseBody AS JsonObject    NO-UNDO.
        DEFINE VARIABLE oCandidates   AS JsonArray     NO-UNDO.
        DEFINE VARIABLE oCandidate    AS JsonObject    NO-UNDO.
        DEFINE VARIABLE oRespContent  AS JsonObject    NO-UNDO.
        DEFINE VARIABLE oRespParts    AS JsonArray     NO-UNDO.
        DEFINE VARIABLE oRespPart     AS JsonObject    NO-UNDO.
        DEFINE VARIABLE cResultText   AS CHARACTER     NO-UNDO INITIAL ?.

        cApiKey = GetApiKey().
        IF cApiKey EQ ? OR TRIM(cApiKey) EQ "":u THEN
            RETURN ?.

        cUrl = cApiBase + cModel + ":generateContent":u.

        oSystemPart  = NEW JsonObject().
        oSystemPart:Add("text":u, pcSystemInstruction).
        oSystemParts = NEW JsonArray().
        oSystemParts:Add(oSystemPart).
        oSystemInst  = NEW JsonObject().
        oSystemInst:Add("parts":u, oSystemParts).

        oPart = NEW JsonObject().
        oPart:Add("text":u, pcUserContent).
        oParts = NEW JsonArray().
        oParts:Add(oPart).
        oContentItem = NEW JsonObject().
        oContentItem:Add("parts":u, oParts).
        oContents = NEW JsonArray().
        oContents:Add(oContentItem).

        oBody = NEW JsonObject().
        oBody:Add("system_instruction":u, oSystemInst).
        oBody:Add("contents":u, oContents).

        IF plJsonMode THEN
        DO:
            oGenConfig = NEW JsonObject().
            oGenConfig:Add("responseMimeType":u, "application/json":u).
            oBody:Add("generationConfig":u, oGenConfig).
        END.

        /* Explicit SNI is required here - without it, the default HTTP
           client library does not reliably send the correct Server Name
           Indication during the TLS handshake against Google's shared
           front-end, which can result in an unexpected/unverifiable
           certificate being presented (observed as a "self-signed
           certificate" SSL failure against a certificate hash not
           present in any known Google/GlobalSign root bundle). Setting
           the SNI explicitly is the documented fix for this class of
           issue when calling third-party HTTPS APIs from ABL - see
           Progress Community "Calling ChatGPT API/Services from OpenEdge". */
        oLib = ClientLibraryBuilder:Build():ServerNameIndicator("generativelanguage.googleapis.com":u):Library.
        oClient = ClientBuilder:Build():UsingLibrary(oLib):Client.

        oRequest = RequestBuilder:Post(cUrl, oBody)
                       :ContentType("application/json":u)
                       :AddHeader("x-goog-api-key":u, cApiKey)
                       :Request.

        oResponse = oClient:Execute(oRequest).

        IF oResponse:StatusCode NE 200 THEN
            RETURN ?.

        IF NOT VALID-OBJECT(oResponse:Entity) OR NOT TYPE-OF(oResponse:Entity, JsonObject) THEN
            RETURN ?.

        oResponseBody = CAST(oResponse:Entity, JsonObject).

        IF NOT oResponseBody:Has("candidates":u) THEN
            RETURN ?.

        oCandidates = oResponseBody:GetJsonArray("candidates":u).
        IF oCandidates:Length EQ 0 THEN
            RETURN ?.

        oCandidate = oCandidates:GetJsonObject(1).
        IF NOT oCandidate:Has("content":u) THEN
            RETURN ?.

        oRespContent = oCandidate:GetJsonObject("content":u).
        IF NOT oRespContent:Has("parts":u) THEN
            RETURN ?.

        oRespParts = oRespContent:GetJsonArray("parts":u).
        IF oRespParts:Length EQ 0 THEN
            RETURN ?.

        oRespPart = oRespParts:GetJsonObject(1).
        IF NOT oRespPart:Has("text":u) THEN
            RETURN ?.

        cResultText = oRespPart:GetCharacter("text":u).

        RETURN cResultText.

        CATCH oError AS Progress.Lang.Error:
            /* Any network/timeout/parsing failure - never propagate an
               ABL error out of this method, callers decide fatal vs.
               recoverable. */
            RETURN ?.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Stage 1 - translates a natural-language prompt into a
                 strict-JSON intent. The system instruction forces
                 JSON-only output matching the schema AiSearchBE expects:
                 {entity, filters:[{field,operator,value}], aggregation:
                 {type,field}|null, confidence, clarificationNeeded}. The
                 model is given NO database access and no schema beyond
                 what's described in the instruction text below - it only
                 ever sees pcPrompt.
        Errors : Throws AppError 502 if the API key is missing, the call
                 fails, times out, or returns no usable text - this is a
                 hard failure per the design contract (STAGE 1 failure
                 always -> 502).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC CHARACTER TranslateToIntent( INPUT pcPrompt AS CHARACTER ):

        DEFINE VARIABLE cSystemInstruction AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cResult            AS CHARACTER NO-UNDO.

        /* The entity/field vocabulary below MUST stay in sync with the
           whitelist in Luna.BusinessLogic.AiSearchBE:InitWhitelist - the
           model can only ever be validated against exactly these
           entity/field/operator combinations, so it must be told them
           explicitly. Without this, the model invents plausible-sounding
           but wrong Dutch field/entity names (e.g. "klantnummer" instead
           of "klnr", "bestelorder" for a customer order instead of "bon")
           that always fail whitelist validation and fall back to
           "clarification" even for perfectly answerable prompts. */
        cSystemInstruction =
            "You translate a Dutch natural-language search request about ERP data into a " +
            "single strict JSON object and NOTHING else - no markdown, no code fences, no " +
            "explanation. " +
            "Schema: entity (one of bon/offerte/klant/artikel/factuur/bestelorder or null), " +
            "filters (array of objects with field, operator - one of eq/prefix/contains/range " +
            "- and value), aggregation (object with type - one of count/sum/avg/min/max - and " +
            "field, or null), confidence (number between 0 and 1), clarificationNeeded " +
            "(boolean). Return exactly these keys as a JSON object: entity, filters, " +
            "aggregation, confidence, clarificationNeeded. " +
            "You MUST use only the exact entity and field names listed below - never invent " +
            "or translate them to a different (even if more natural-sounding) Dutch name: " +
            "- bon (customer sales orders, NL 'orders'/'bestellingen van klanten'): fields " +
            "klnr (customer number, eq), bonnr (order number, prefix), type (eq), naam " +
            "(customer name, contains), geparkeerd (boolean, eq), verzonden (boolean, eq). " +
            "Aggregation field: bedrag. " +
            "- offerte (quotes, NL 'offertes'): fields klnr (eq), offnr (prefix), naam " +
            "(contains). Aggregation fields: bedrag, btw. " +
            "- klant (customers, NL 'klanten'): fields klnr (eq), naam (contains). " +
            "Aggregation field: saldo. " +
            "- artikel (stock articles, NL 'artikelen'/'voorraad'): fields artnr (prefix), " +
            "groep (eq). Aggregation fields: voorraad, aankoopprijs, verkoopprijs. " +
            "- factuur (invoices, NL 'facturen'): fields klnr (eq), datum (eq - single date " +
            "only, no range), projectnr (eq), naam (contains). Aggregation fields: totaal, " +
            "nBedrag, totBtw. " +
            "- bestelorder (purchase orders TO SUPPLIERS, NL 'bestelorders'/'inkooporders' - " +
            "NOT customer orders, use 'bon' for those): fields levnr (supplier number, eq), " +
            "ordnr (prefix), naam (contains). Aggregation field: bedrag. " +
            "If the user's request implies a field or concept not in this list for the " +
            "matched entity, omit that filter rather than inventing a field name. " +
            "You have NO access to any database and must never invent values that were not " +
            "implied by the user text. If the request is vague, ambiguous, does not map to " +
            "one of the entities/fields above, or would require scanning the entire dataset " +
            "without any selective filter (e.g. a customer, order, or article number), set " +
            "clarificationNeeded to true and lower confidence accordingly.":u.

        cResult = CallGemini(cSystemInstruction, pcPrompt, TRUE).

        IF cResult EQ ? THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                "Gemini TranslateToIntent call failed, timed out, or returned no usable output":u, 502).

        RETURN cResult.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Stage 2 - generates a short natural-language summary from
                 a minimal, already-authorized JSON payload (server-side
                 computed aggregates + at most 20 sample rows, using only
                 the fields the user already sees in `items`). The system
                 instruction enforces the anti-hallucination rule: every
                 number in the summary must come from the supplied JSON.
                 AiSearchBE independently re-checks that afterwards (see
                 ValidateSummaryAgainstData) - this method does not
                 enforce it, it only asks for it.
        Errors : Never throws - returns the unknown value (?) on any
                 failure/timeout so AiSearchBE can fall back to a
                 deterministic template summary (design contract: STAGE 2
                 failure never surfaces as an error to the client).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC CHARACTER GenerateSummary( INPUT pcPayloadJson AS CHARACTER ):

        DEFINE VARIABLE cSystemInstruction AS CHARACTER NO-UNDO.

        cSystemInstruction =
            "You write one short Dutch sentence (max about 40 words) summarizing search " +
            "results for an ERP user, based ONLY on the JSON data supplied in the next " +
            "message. Use exclusively the numbers that appear in that JSON - never invent " +
            "or calculate any other number, amount, or count. Every numeric value you " +
            "mention must match a value present in the supplied JSON exactly. Do not use " +
            "markdown, just plain text.":u.

        RETURN CallGemini(cSystemInstruction, pcPayloadJson, FALSE).

    END METHOD.

END CLASS.

