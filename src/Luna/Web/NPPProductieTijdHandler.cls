/*------------------------------------------------------------------------
    File        : NPPProductieTijdHandler.cls
    Purpose     : WebHandler for GET /web/npp/productietijd[?programma=X] -
                  read-only dump of the productietijd rows (Start/Pauze/
                  Herstart/Stop/Afgewerkt registrations from the legacy NPP
                  UI) of the last 12 months. All logic lives in
                  Luna.BusinessLogic.NPPProductieTijdBE.
    Syntax      : GET /web/npp/productietijd
                  GET /web/npp/productietijd?programma=PRODUCTIE
                  GET /web/npp/productietijd?alleenTijdacties=true
    Author(s)   : Devin
    Created     : 2026-10-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Luna.BusinessLogic.NPPProductieTijdBE.
USING Luna.Web.Util.QueryParamHelper.
USING Luna.BusinessLogic.AuthGuard.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.NPPProductieTijdHandler INHERITS WebHandler:

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

    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cProgramma AS CHARACTER           NO-UNDO.
        DEFINE VARIABLE lAlleenTijd AS LOGICAL            NO-UNDO.
        DEFINE VARIABLE oService   AS NPPProductieTijdBE NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        cProgramma = TRIM(QueryParamHelper:GetQueryValue(poRequest, "programma":u)).

        lAlleenTijd = (TRIM(QueryParamHelper:GetQueryValue(poRequest, "alleenTijdacties":u)) EQ "true":u).

        oService = NEW NPPProductieTijdBE().

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oService:GetProductieTijden(cProgramma, lAlleenTijd)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            WriteErrorResponse(INTEGER(StatusCodeEnum:InternalServerError), oAppError:GetMessage(1)).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /npp/productietijd":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /npp/productietijd":u).
        RETURN 0.
    END METHOD.

END CLASS.
