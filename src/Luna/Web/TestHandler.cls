/*------------------------------------------------------------------------
    File        : TestHandler.cls
    Purpose     : Smoke-test WebHandler for the Luna PASOE backend. Confirms
                  the WEB transport is reachable and that the LunaNew
                  database connection is up.
    Syntax      : GET /web/test
    Description : Thin WebHandler only - no business logic here. If this
                  ever needs real logic, move it to a Business Entity.
    Author(s)   : Devin
    Created     : 2026-08-10
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.TestHandler INHERITS WebHandler:

    /*------------------------------------------------------------------------------
        Purpose: Default handler for the HTTP GET method. Returns a small JSON
                 payload confirming the backend and database connectivity.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oResponse    AS OpenEdge.Net.HTTP.IHttpResponse NO-UNDO.
        DEFINE VARIABLE oWriter      AS WebResponseWriter               NO-UNDO.
        DEFINE VARIABLE oBody        AS JsonObject                      NO-UNDO.
        DEFINE VARIABLE lDbConnected AS LOGICAL                         NO-UNDO.

        lDbConnected = CONNECTED("LunaNew":u).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "ok":u).
        oBody:Add("message":u, "Luna backend test endpoint is up":u).
        oBody:Add("database":u, "LunaNew":u).
        oBody:Add("databaseConnected":u, lDbConnected).
        oBody:Add("timestamp":u, ISO-DATE(NOW)).

        ASSIGN
            oResponse             = NEW OpenEdge.Web.WebResponse()
            oResponse:StatusCode  = INTEGER(StatusCodeEnum:OK)
            oResponse:Entity      = oBody
            oResponse:ContentType = "application/json":u
            .

        oWriter = NEW WebResponseWriter(oResponse).
        oWriter:Open().
        oWriter:Close().

        RETURN 0.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unsupported HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        UNDO, THROW NEW Progress.Lang.AppError("Method not allowed on /test":u, 0).
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        UNDO, THROW NEW Progress.Lang.AppError("Method not implemented on /test":u, 0).
    END METHOD.

END CLASS.
