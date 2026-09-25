/*------------------------------------------------------------------------
    File        : NPPStockBewegingHandler.cls
    Purpose     : WebHandler for booking a manual stock movement
                  (correctie/ontvangst/transfer) against an article - see
                  Luna.BusinessLogic.StockBewegingBE for all
                  validation/booking logic. This handler only reads the
                  X-Auth-Token header, validates the session, parses the
                  JSON body, delegates to the BE, and reshapes the
                  returned result temp-table into the documented response
                  shape.
    Syntax      : POST /web/npp/stockbeweging
                  Body: {"artnr":..., "movementType":..., "aantal":...,
                         "opm":..., "nieuwMagazijn":...}
                  Response 200: {"artikel": {"artnr","voorraad","magazijn"},
                                 "artlog": {"artnr","lijnnr","datum","uur",
                                            "beweging","aantal","stock",
                                            "opm","id"}}
    Description : Thin WebHandler only - no business logic, no direct DB
                  access. Auth follows Luna.Web.LogoutHandler's
                  X-Auth-Token idiom (the standard Authorization header
                  never reaches this layer on this PASOE instance - see
                  that class's GetAuthToken comment). Error-status
                  allowlist is "400,401,404,409":u - this is the first
                  handler in this family needing auth, hence 401 added to
                  the usual sibling-handler "400,404,409" set.
    Author(s)   : Devin
    Created     : 2026-09-19
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Net.HTTP.HttpHeader.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.AuthBE.
USING Luna.BusinessLogic.StockBewegingBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.NPPStockBewegingHandler INHERITS WebHandler:

    /* Extracts the session token from the X-Auth-Token header - mirrors
       Luna.Web.LogoutHandler:GetAuthToken exactly (see that class for why
       this is a custom header and not the standard Authorization one).
       Returns "":u if the header is absent/blank. */
    METHOD PRIVATE CHARACTER GetAuthToken( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oHeader AS HttpHeader NO-UNDO.
        DEFINE VARIABLE cValue  AS CHARACTER  NO-UNDO.

        IF NOT poRequest:HasHeader("X-Auth-Token":u) THEN
            RETURN "":u.

        oHeader = CAST(poRequest:GetHeader("X-Auth-Token":u), HttpHeader).
        cValue  = oHeader:Value.

        IF cValue EQ ? THEN
            RETURN "":u.

        RETURN TRIM(cValue).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the request body entity into a JsonObject.
        Errors : Throws AppError 400 if the body is missing/not a JSON
                 object, or malformed JSON (mirrors Luna.Web.BonHandler:
                 GetJsonBody's non-AppError-to-400 conversion for the
                 lazy-deserialization-on-access case).
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
        Purpose: Serializes the ttStockBewegingResult result handle (from
                 StockBewegingBE) to a JsonObject shaped as {"items": [...]}.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR          NO-UNDO.
        DEFINE VARIABLE oParser AS ObjectModelParser  NO-UNDO.

        phResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE).

        oParser = NEW ObjectModelParser().

        RETURN CAST(oParser:Parse(lcJson), JsonObject).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Reshapes the single row of the BE's result temp-table
                 (as an "items"-wrapped JsonObject) into the documented
                 /npp/stockbeweging response shape - legitimate response
                 formatting, not business logic.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject BuildResponseBody( INPUT poRawResult AS JsonObject ):

        DEFINE VARIABLE oItems    AS JsonArray  NO-UNDO.
        DEFINE VARIABLE oRow      AS JsonObject NO-UNDO.
        DEFINE VARIABLE oArtikel  AS JsonObject NO-UNDO.
        DEFINE VARIABLE oArtlog   AS JsonObject NO-UNDO.
        DEFINE VARIABLE oResult   AS JsonObject NO-UNDO.

        oItems = poRawResult:GetJsonArray("items":u).
        oRow   = oItems:GetJsonObject(1).

        oArtikel = NEW JsonObject().
        oArtikel:Add("artnr":u, oRow:GetCharacter("artnr":u)).
        oArtikel:Add("voorraad":u, oRow:GetDecimal("voorraad":u)).
        oArtikel:Add("magazijn":u, oRow:GetCharacter("magazijn":u)).

        oArtlog = NEW JsonObject().
        oArtlog:Add("artnr":u, oRow:GetCharacter("artnr":u)).
        oArtlog:Add("lijnnr":u, oRow:GetInteger("lijnnr":u)).
        oArtlog:Add("datum":u, oRow:GetCharacter("datum":u)).
        oArtlog:Add("uur":u, oRow:GetCharacter("uur":u)).
        oArtlog:Add("beweging":u, oRow:GetCharacter("beweging":u)).
        oArtlog:Add("aantal":u, oRow:GetDecimal("artlogAantal":u)).
        oArtlog:Add("stock":u, oRow:GetDecimal("stock":u)).
        oArtlog:Add("opm":u, oRow:GetCharacter("opm":u)).
        oArtlog:Add("id":u, oRow:GetCharacter("gebruikerId":u)).

        oResult = NEW JsonObject().
        oResult:Add("artikel":u, oArtikel).
        oResult:Add("artlog":u, oArtlog).

        RETURN oResult.

    END METHOD.

    /* Writes a JSON response with the given status code.
       CORS headers - allow the frontend (localhost:3000) to call this
       endpoint with the X-Auth-Token header, same pattern as
       Luna.Web.LogoutHandler (missing here initially, which broke every
       call from an actual browser with a CORS preflight error - curl-
       based testing never exercises the browser's preflight OPTIONS
       request, so this was missed until a real browser hit it). */
    METHOD PRIVATE VOID WriteJsonResponse( INPUT piStatusCode AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE oResponse AS OpenEdge.Net.HTTP.IHttpResponse NO-UNDO.
        DEFINE VARIABLE oWriter   AS WebResponseWriter               NO-UNDO.
        DEFINE VARIABLE oHeader   AS OpenEdge.Net.HTTP.HttpHeader    NO-UNDO.

        ASSIGN
            oResponse             = NEW OpenEdge.Web.WebResponse()
            oResponse:StatusCode  = piStatusCode
            oResponse:Entity      = poBody
            oResponse:ContentType = "application/json":u
            .

        oHeader = NEW OpenEdge.Net.HTTP.HttpHeader("Access-Control-Allow-Origin":u, "http://localhost:3000":u).
        oResponse:SetHeader(oHeader).

        oHeader = NEW OpenEdge.Net.HTTP.HttpHeader("Access-Control-Allow-Methods":u, "POST, OPTIONS":u).
        oResponse:SetHeader(oHeader).

        oHeader = NEW OpenEdge.Net.HTTP.HttpHeader("Access-Control-Allow-Headers":u, "Content-Type, X-Auth-Token":u).
        oResponse:SetHeader(oHeader).

        oWriter = NEW WebResponseWriter(oResponse).
        oWriter:Open().
        oWriter:Close().

    END METHOD.

    /* OPTIONS /npp/stockbeweging - CORS preflight request handler.
       Mirrors Luna.Web.LogoutHandler:HandleOptions. */
    METHOD OVERRIDE PROTECTED INTEGER HandleOptions( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oBody AS JsonObject NO-UNDO.

        oBody = NEW JsonObject().
        oBody:Add("message":u, "CORS preflight OK":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

    END METHOD.

    /* Writes a JSON error response: {"error": {"message": ..., "code": n}}. */
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

    /* Maps an AppError raised by AuthBE/StockBewegingBE (400/401/404/409)
       to an HTTP status code, defaulting unrecognized codes to 500 so no
       ABL stack trace ever leaks to the client. Extends the usual
       sibling-handler "400,404,409" allowlist with 401 - this is the
       first handler in this family needing auth. */
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,401,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: POST /npp/stockbeweging - validates the X-Auth-Token
                 session, parses the JSON body, and delegates the booking
                 to Luna.BusinessLogic.StockBewegingBE:BoekBeweging. All
                 business-rule validation lives in the BE, not here.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cToken     AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE cKode      AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE iNiveau    AS INTEGER        NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject     NO-UNDO.
        DEFINE VARIABLE oAuthBE    AS AuthBE         NO-UNDO.
        DEFINE VARIABLE oService   AS StockBewegingBE NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE         NO-UNDO.
        DEFINE VARIABLE oRawResult AS JsonObject     NO-UNDO.
        DEFINE VARIABLE oResponse  AS JsonObject     NO-UNDO.

        cToken  = GetAuthToken(poRequest).
        oAuthBE = NEW AuthBE().

        IF NOT oAuthBE:ValidateToken(cToken, OUTPUT cKode, OUTPUT iNiveau) THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:Unauthorized), "Ongeldige of verlopen sessie":u).
            RETURN 0.
        END.

        oBody = GetJsonBody(poRequest).

        oService = NEW StockBewegingBE().
        hResult  = oService:BoekBeweging(oBody, cKode).

        oRawResult = ResultHandleToJson(hResult).
        oResponse  = BuildResponseBody(oRawResult).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oResponse).

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
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /npp/stockbeweging":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /npp/stockbeweging":u).
        RETURN 0.
    END METHOD.

END CLASS.
