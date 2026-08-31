/*------------------------------------------------------------------------
    File        : DashboardHandler.cls
    Purpose     : WebHandler exposing the dashboard summary (stat cards,
                  recent activity, production this week) shown on the
                  Luna homepage.
    Syntax      : GET /web/dashboard
    Description : Thin WebHandler only - routing, response assembly and
                  formatting. No business logic and no direct DB access -
                  all of that lives in Luna.BusinessLogic.DashboardBE.
    Author(s)   : Devin
    Created     : 2026-08-12
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.DashboardBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.DashboardHandler INHERITS WebHandler:

    /*------------------------------------------------------------------------------
        Purpose: Serializes a result handle (from DashboardBE) to a
                 JsonObject shaped as {"items": [...]} / {"recentActivity":
                 [...]} / {"productionThisWeek": [...]} depending on the
                 temp-table's SERIALIZE-NAME.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR         NO-UNDO.
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
        Purpose: GET /dashboard - assembles statCards (single object),
                 recentActivity (array) and productionThisWeek (array) into
                 one response body.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService        AS DashboardBE NO-UNDO.
        DEFINE VARIABLE hStatCards      AS HANDLE      NO-UNDO.
        DEFINE VARIABLE hActivity       AS HANDLE      NO-UNDO.
        DEFINE VARIABLE hProduction     AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oStatCardsBody  AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oActivityBody   AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oProductionBody AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oBody           AS JsonObject  NO-UNDO.

        oService = NEW DashboardBE().

        hStatCards  = oService:GetStatCards().
        hActivity   = oService:GetRecentActivity(5).
        hProduction = oService:GetProductionThisWeek().

        oStatCardsBody  = ResultHandleToJson(hStatCards).
        oActivityBody   = ResultHandleToJson(hActivity).
        oProductionBody = ResultHandleToJson(hProduction).

        oBody = NEW JsonObject().
        oBody:Add("statCards":u, oStatCardsBody:GetJsonArray("items":u):GetJsonObject(1)).
        oBody:Add("recentActivity":u, oActivityBody:GetJsonArray("recentActivity":u)).
        oBody:Add("productionThisWeek":u, oProductionBody:GetJsonArray("productionThisWeek":u)).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unsupported HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /dashboard":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /dashboard":u).
        RETURN 0.
    END METHOD.

END CLASS.
