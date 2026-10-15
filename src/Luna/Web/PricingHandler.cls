/*------------------------------------------------------------------------
    File        : PricingHandler.cls
    Purpose     : Test-only WebHandler exposing Luna.BusinessLogic.
                  PricingEngineBE:BerekenPrijs() (Iteratie A, K1-K5 pricing
                  engine). Thin HTTP layer only - request parsing, response
                  formatting and HTTP status mapping. All calculation logic
                  lives in PricingEngineBE.
    Syntax      : POST /web/pricing/bereken
                  Request body: {"artnr": "...", "klnr": 10165,
                                 "aantal": 3, "typeKorting": "K1",
                                 "documentKorting": 0}
                  ("context" from the architect design doc is optional/
                  informational and adds nothing to the calculation - it
                  is deliberately not read here.)
                  Response 200: {"artnr", "klnr", "aantal", "vprijs",
                                 "aprijs", "korting", "kortingLocked",
                                 "promotieActief", "nettoPrijsToegepast",
                                 "uitverkoopToegepast"}
                  Errors (same {"error":{"message","code"}} envelope as
                  Luna.Web.BonHandler):
                    400 - typeKorting missing/not one of K1-K5 (mapped from
                          PricingEngineBE's AppError), or klnr/aantal
                          missing/non-numeric (checked here).
                    404 - artnr not found (mapped from PricingEngineBE's
                          AppError).
                    500 - fallback for anything unexpected (no ABL stack
                          trace ever reaches the client).
    Author(s)   : Devin
    Created     : 2026-09-20
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.PricingEngineBE.
USING Luna.BusinessLogic.AuthGuard.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.PricingHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/pricing":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the path segments after the mount point, e.g.
                 "/pricing/bereken" -> "bereken".
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GetPathRemainder( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cPathInfo AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRest     AS CHARACTER NO-UNDO.

        cPathInfo = poRequest:PathInfo.

        IF cPathInfo BEGINS cMountPoint THEN
            cRest = SUBSTRING(cPathInfo, LENGTH(cMountPoint) + 1).
        ELSE
            cRest = cPathInfo.

        cRest = TRIM(cRest, "/":u).

        RETURN cRest.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the request body entity into a JsonObject.
        Errors : Throws AppError 400 if the body is missing/not JSON/malformed.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject GetJsonBody( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oEntity AS Progress.Lang.Object NO-UNDO.

        oEntity = poRequest:Entity.

        IF NOT VALID-OBJECT(oEntity) OR NOT TYPE-OF(oEntity, JsonObject) THEN
            UNDO, THROW NEW Progress.Lang.AppError("Request body must be a JSON object":u, 400).

        RETURN CAST(oEntity, JsonObject).

        CATCH oError AS Progress.Lang.Error:
            /* Same rationale as Luna.Web.BonHandler:GetJsonBody - convert a
               raw JSON-parser lexical error into a clean AppError 400
               instead of letting it escape as an uncaught framework 500. */
            IF TYPE-OF(oError, Progress.Lang.AppError) THEN
                UNDO, THROW oError.

            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Malformed JSON request body: &1":u, oError:GetMessage(1)), 400).
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Reads a required INTEGER field from the request body.
        Errors : Throws AppError 400 if missing or not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER GetRequiredInteger( INPUT poBody AS JsonObject, INPUT pcKey AS CHARACTER ):

        DEFINE VARIABLE iValue AS INTEGER NO-UNDO.

        IF NOT poBody:Has(pcKey) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Missing required field '&1'":u, pcKey), 400).

        iValue = poBody:GetInteger(pcKey) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Field '&1' must be numeric":u, pcKey), 400).

        RETURN iValue.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Reads a required DECIMAL field from the request body.
        Errors : Throws AppError 400 if missing or not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DECIMAL GetRequiredDecimal( INPUT poBody AS JsonObject, INPUT pcKey AS CHARACTER ):

        DEFINE VARIABLE dValue AS DECIMAL NO-UNDO.

        IF NOT poBody:Has(pcKey) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Missing required field '&1'":u, pcKey), 400).

        dValue = poBody:GetDecimal(pcKey) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Field '&1' must be numeric":u, pcKey), 400).

        RETURN dValue.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Reads an optional DECIMAL field from the request body,
                 defaulting to 0 if absent (documentKorting is only
                 relevant for K3/K4/K5 - see PricingEngineBE:BepaalKorting).
        Errors : Throws AppError 400 if present but not numeric.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DECIMAL GetOptionalDecimal( INPUT poBody AS JsonObject, INPUT pcKey AS CHARACTER ):

        DEFINE VARIABLE dValue AS DECIMAL NO-UNDO.

        IF NOT poBody:Has(pcKey) THEN
            RETURN 0.

        dValue = poBody:GetDecimal(pcKey) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Field '&1' must be numeric":u, pcKey), 400).

        RETURN dValue.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Serializes a result handle (from PricingEngineBE) to a
                 JsonObject shaped as {"items": [...]}.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR          NO-UNDO.
        DEFINE VARIABLE oParser AS ObjectModelParser  NO-UNDO.

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
        Purpose: Maps an AppError raised by PricingEngineBE (400/404) to an
                 HTTP status code, defaulting unrecognized codes to 500 so
                 no ABL stack trace ever leaks to the client.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: POST /pricing/bereken - calculate a pricing result for one
                 artnr/klnr/aantal/typeKorting combination.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cRemainder       AS CHARACTER    NO-UNDO.
        DEFINE VARIABLE oReqBody         AS JsonObject   NO-UNDO.
        DEFINE VARIABLE cArtnr           AS CHARACTER    NO-UNDO.
        DEFINE VARIABLE iKlnr            AS INTEGER      NO-UNDO.
        DEFINE VARIABLE dAantal          AS DECIMAL      NO-UNDO.
        DEFINE VARIABLE cTypeKorting     AS CHARACTER    NO-UNDO.
        DEFINE VARIABLE dDocumentKorting AS DECIMAL      NO-UNDO.
        DEFINE VARIABLE oService         AS PricingEngineBE NO-UNDO.
        DEFINE VARIABLE hResult          AS HANDLE       NO-UNDO.
        DEFINE VARIABLE oBody            AS JsonObject   NO-UNDO.
        DEFINE VARIABLE oItems           AS JsonArray    NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        cRemainder = GetPathRemainder(poRequest).

        IF cRemainder NE "bereken":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /pricing/bereken, got &1":u, cRemainder)).
            RETURN 0.
        END.

        oReqBody = GetJsonBody(poRequest).

        IF NOT oReqBody:Has("artnr":u) OR TRIM(oReqBody:GetCharacter("artnr":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "Missing required field 'artnr'":u).
            RETURN 0.
        END.
        cArtnr = TRIM(oReqBody:GetCharacter("artnr":u)).

        iKlnr            = GetRequiredInteger(oReqBody, "klnr":u).
        dAantal          = GetRequiredDecimal(oReqBody, "aantal":u).
        dDocumentKorting = GetOptionalDecimal(oReqBody, "documentKorting":u).

        IF NOT oReqBody:Has("typeKorting":u) THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "Missing required field 'typeKorting'":u).
            RETURN 0.
        END.
        cTypeKorting = TRIM(oReqBody:GetCharacter("typeKorting":u)).

        oService = NEW PricingEngineBE().
        hResult  = oService:BerekenPrijs(cArtnr, iKlnr, dAantal, cTypeKorting, dDocumentKorting).
        oBody    = ResultHandleToJson(hResult).
        oItems   = oBody:GetJsonArray("pricing":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /* Handler for unsupported HTTP methods on this endpoint. */
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /pricing":u).
        RETURN 0.
    END METHOD.

    /* Handler for unimplemented HTTP methods on this endpoint. */
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /pricing":u).
        RETURN 0.
    END METHOD.

END CLASS.
