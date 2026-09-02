/*------------------------------------------------------------------------
    File        : AiSearchHandler.cls
    Purpose     : Thin WebHandler for the AI-powered natural-language
                  search feature. Parses the JSON request body (`prompt`),
                  does the two pieces of HTTP-level input validation the
                  design contract calls out explicitly (empty/missing,
                  over the 500-character cap), calls
                  Luna.BusinessLogic.AiSearchBE:ExecuteSearch for
                  EVERYTHING else (Gemini calls, whitelist validation,
                  entity dispatch, aggregation, summary generation/anti-
                  hallucination check), and stitches the meta handle +
                  items handle it returns into the single documented
                  response body - same "handle -> WRITE-JSON -> JsonObject
                  -> merge" pattern Luna.Web.DashboardHandler already uses
                  for its 3 handles. No business logic, no DB access, no
                  Gemini calls here.
    Syntax      : POST /web/ai-search  (no auth required, matches the
                  other list endpoints)
    Description : {"prompt": "..."} in, one of resultType
                  results/no_results/clarification out (all 200 OK) - see
                  Luna.BusinessLogic.AiSearchBE class header for the full
                  contract. 400 for a bad prompt, 502 if Gemini stage 1
                  fails, 500 for anything unexpected. A stage-2 (summary)
                  failure never surfaces here - AiSearchBE always falls
                  back to a deterministic template summary internally.
    Author(s)   : Devin
    Created     : 2026-09-01
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.AiSearchBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.AiSearchHandler INHERITS WebHandler:

    /*------------------------------------------------------------------------------
        Purpose: Parses the request body entity into a JsonObject - same
                 pattern/rationale as Luna.Web.BonHandler:GetJsonBody (see
                 that class for the full BOM/malformed-JSON regression note).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject GetJsonBody( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oEntity AS Progress.Lang.Object NO-UNDO.

        oEntity = poRequest:Entity.

        IF NOT VALID-OBJECT(oEntity) OR NOT TYPE-OF(oEntity, JsonObject) THEN
            UNDO, THROW NEW Progress.Lang.AppError("Request body must be a JSON object":u, 400).

        RETURN CAST(oEntity, JsonObject).

        CATCH oError AS Progress.Lang.Error:
            IF TYPE-OF(oError, Progress.Lang.AppError) THEN
                UNDO, THROW oError.

            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Malformed JSON request body: &1":u, oError:GetMessage(1)), 400).
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Serializes a temp-table result handle to a JsonObject.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR          NO-UNDO.
        DEFINE VARIABLE oParser AS ObjectModelParser NO-UNDO.

        phResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE).

        oParser = NEW ObjectModelParser().

        RETURN CAST(oParser:Parse(lcJson), JsonObject).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Writes a JSON response with the given status code.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID WriteJsonResponse( INPUT piStatusCode AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE oResponse AS OpenEdge.Net.HTTP.IHttpResponse NO-UNDO.
        DEFINE VARIABLE oWriter   AS WebResponseWriter               NO-UNDO.

        ASSIGN
            oResponse             = NEW OpenEdge.Web.WebResponse()
            oResponse:StatusCode  = piStatusCode
            oResponse:Entity      = poBody
            oResponse:ContentType = "application/json":u
            .

        oWriter = NEW WebResponseWriter(oResponse).
        oWriter:Open().
        oWriter:Close().

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Writes a JSON error response: {"error": {"message": "...", "code": n}}.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID WriteErrorResponse( INPUT piStatusCode AS INTEGER, INPUT pcMessage AS CHARACTER ):

        DEFINE VARIABLE oError AS JsonObject NO-UNDO.
        DEFINE VARIABLE oBody  AS JsonObject NO-UNDO.

        oError = NEW JsonObject().
        oError:Add("message":u, pcMessage).
        oError:Add("code":u, piStatusCode).

        oBody = NEW JsonObject().
        oBody:Add("error":u, oError).

        WriteJsonResponse(piStatusCode, oBody).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Maps an AppError raised by AiSearchBE (400 bad prompt,
                 502 Gemini stage-1 failure) to its HTTP status, defaulting
                 anything else to 500 so no ABL stack trace ever leaks to
                 the client - same pattern as every other handler's
                 HandleAppError.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,502":u) EQ 0 THEN
        DO:
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).
            WriteErrorResponse(iStatus, "Er is een fout opgetreden bij het verwerken van je zoekopdracht.":u).
            RETURN.
        END.

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a JsonObject field as character, or ? if it's
                 absent, JSON null, or of a different type - never throws.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GetCharOrNull( INPUT poObj AS JsonObject, INPUT pcKey AS CHARACTER ):

        DEFINE VARIABLE cVal AS CHARACTER NO-UNDO.

        IF NOT poObj:Has(pcKey) THEN
            RETURN ?.

        cVal = poObj:GetCharacter(pcKey) NO-ERROR.

        RETURN cVal.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: POST /ai-search - {"prompt": "..."} in, the documented
                 results/no_results/clarification response shape out. All
                 business logic lives in AiSearchBE:ExecuteSearch - this
                 method only parses the body, does the two HTTP-level
                 checks the design contract calls out (empty prompt, >500
                 chars), and stitches the meta+items handles into one body.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oReqBody   AS JsonObject  NO-UNDO.
        DEFINE VARIABLE cPrompt    AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE oService   AS AiSearchBE  NO-UNDO.
        DEFINE VARIABLE hMeta      AS HANDLE      NO-UNDO.
        DEFINE VARIABLE hItems     AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oMetaBody  AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oMetaRow   AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItemsBody AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oParser    AS ObjectModelParser NO-UNDO.
        DEFINE VARIABLE cIntentRaw AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE oIntent    AS Progress.Lang.Object NO-UNDO.

        oReqBody = GetJsonBody(poRequest).

        cPrompt = IF oReqBody:Has("prompt":u) THEN TRIM(oReqBody:GetCharacter("prompt":u)) ELSE "":u.
        IF cPrompt EQ ? THEN cPrompt = "":u.

        IF cPrompt EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "prompt is required":u).
            RETURN 0.
        END.

        IF LENGTH(cPrompt) GT 500 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "prompt is too long (max 500 characters)":u).
            RETURN 0.
        END.

        oService = NEW AiSearchBE().
        oService:ExecuteSearch(cPrompt, OUTPUT hMeta, OUTPUT hItems).

        oMetaBody  = ResultHandleToJson(hMeta).
        oMetaRow   = oMetaBody:GetJsonArray("meta":u):GetJsonObject(1).
        oItemsBody = ResultHandleToJson(hItems).

        cIntentRaw = GetCharOrNull(oMetaRow, "intent":u).
        oIntent    = ?.
        IF cIntentRaw NE ? THEN
        DO:
            oParser = NEW ObjectModelParser().
            oIntent = oParser:Parse(cIntentRaw) NO-ERROR.
        END.

        oBody = NEW JsonObject().
        oBody:Add("queryText":u, GetCharOrNull(oMetaRow, "queryText":u)).
        oBody:Add("resultType":u, GetCharOrNull(oMetaRow, "resultType":u)).
        oBody:Add("entity":u, GetCharOrNull(oMetaRow, "entity":u)).

        IF VALID-OBJECT(oIntent) THEN
            oBody:Add("intent":u, CAST(oIntent, JsonObject)).
        ELSE
            oBody:Add("intent":u, STRING(?)).

        oBody:Add("items":u, oItemsBody:GetJsonArray("items":u)).
        oBody:Add("page":u, oMetaRow:GetInteger("page":u)).
        oBody:Add("pageSize":u, oMetaRow:GetInteger("pageSize":u)).
        oBody:Add("hasMore":u, oMetaRow:GetLogical("hasMore":u)).
        oBody:Add("summary":u, GetCharOrNull(oMetaRow, "summary":u)).
        oBody:Add("clarificationQuestion":u, GetCharOrNull(oMetaRow, "clarificationQuestion":u)).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unsupported HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /ai-search":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /ai-search":u).
        RETURN 0.
    END METHOD.

END CLASS.

