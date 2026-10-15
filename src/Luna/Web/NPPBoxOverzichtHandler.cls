/*------------------------------------------------------------------------
    File        : NPPBoxOverzichtHandler.cls
    Purpose     : WebHandler for the NPP "Boxoverzicht" scan lookup -
                  GET /web/npp/boxoverzicht?scan=<rawScanValue> returns
                  the bon header (bonnr/groepnr/klant), a status remark
                  (opmerking), and the aggregated article list for the
                  scanned box label. See Luna.BusinessLogic.NPPBoxOverzichtBE
                  for all parsing/lookup/aggregation logic - this handler
                  only reads the "scan" query param and formats the
                  response/error envelope.
    Syntax      : GET /web/npp/boxoverzicht?scan=<rawScanValue>
    Description : Thin WebHandler only - no business logic here. Mirrors
                  Luna.Web.LakproductieHandler's AppError-to-HTTP-status
                  mapping convention: {"error":{"message":"...","code":n}},
                  HTTP status = code, 500 fallback for anything
                  unrecognized so no ABL stack trace ever leaks to the
                  client.
    Author(s)   : Devin
    Created     : 2026-09-17
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Luna.BusinessLogic.NPPBoxOverzichtBE.
USING Luna.Web.Util.QueryParamHelper.
USING Luna.BusinessLogic.AuthGuard.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.NPPBoxOverzichtHandler INHERITS WebHandler:

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
        Purpose: Maps an AppError raised by NPPBoxOverzichtBE (400/404) to
                 an HTTP status code, defaulting unrecognized codes to 500
                 so no ABL stack trace ever leaks to the client. Mirrors
                 Luna.Web.LakproductieHandler:HandleAppError.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Default handler for the HTTP GET method. Reads the
                 "scan" query param (pure HTTP validation - missing/blank
                 stays in the handler) and delegates the parse/lookup/
                 aggregation to Luna.BusinessLogic.NPPBoxOverzichtBE.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cScan   AS CHARACTER          NO-UNDO.
        DEFINE VARIABLE oService AS NPPBoxOverzichtBE NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject        NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        cScan = QueryParamHelper:GetQueryValue(poRequest, "scan":u).

        IF TRIM(cScan) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "Ontbrekende parameter 'scan'":u).
            RETURN 0.
        END.

        oService = NEW NPPBoxOverzichtBE().
        oBody    = oService:GetBoxOverzicht(cScan).

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
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /npp/boxoverzicht":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /npp/boxoverzicht":u).
        RETURN 0.
    END METHOD.

END CLASS.
