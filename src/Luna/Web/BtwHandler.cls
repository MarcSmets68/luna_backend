/*------------------------------------------------------------------------
    File        : BtwHandler.cls
    Purpose     : Test-only WebHandler exposing Luna.BusinessLogic.
                  BtwBerekeningBE:BerekenBtw() (Iteratie B, BTW/VAT
                  calculation engine). Thin HTTP layer only - request
                  parsing, response formatting and HTTP status mapping.
                  All calculation logic lives in BtwBerekeningBE.
    Syntax      : POST /web/btw/bereken
                  Request body: {"regels": [{"btwKode","bedrag",
                                 "totaalRecupel"}, ...], "swRegime": bool,
                                 "swPrijsRecup": bool, "typeKorting": "",
                                 "documentKortingPercentage": n,
                                 "documentKortingBedrag": n}
                  Response 200: {"totaal": {"regimeToegepast",
                                 "totaalBasis", "totBtw", "totaalInclBtw"},
                                 "groepen": [{"btwKode", "percentage",
                                 "basis", "btwBedrag"}, ...]}
                  Errors (same {"error":{"message","code"}} envelope as
                  Luna.Web.PricingHandler):
                    400 - malformed JSON body, missing/empty "regels",
                          "swRegime"/"swPrijsRecup" missing or not boolean,
                          unrecognized typeKorting, or >2 unique btw-kodes
                          (mapped from BtwBerekeningBE's AppError).
                    404 - unknown btw-kode (mapped from BtwBerekeningBE's
                          AppError).
                    500 - fallback for anything unexpected (no ABL stack
                          trace ever reaches the client).
    Author(s)   : Devin
    Created     : 2026-09-27
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.JsonDataType.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.BtwBerekeningBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.BtwHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/btw":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the path segments after the mount point, e.g.
                 "/btw/bereken" -> "bereken".
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
            /* Same rationale as Luna.Web.PricingHandler:GetJsonBody -
               convert a raw JSON-parser lexical error into a clean
               AppError 400 instead of letting it escape as an uncaught
               framework 500. */
            IF TYPE-OF(oError, Progress.Lang.AppError) THEN
                UNDO, THROW oError.

            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Malformed JSON request body: &1":u, oError:GetMessage(1)), 400).
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Reads a required LOGICAL field from the request body.
        Errors : Throws AppError 400 if missing or not a JSON boolean.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL GetRequiredLogical( INPUT poBody AS JsonObject, INPUT pcKey AS CHARACTER ):

        DEFINE VARIABLE lValue AS LOGICAL NO-UNDO.

        IF NOT poBody:Has(pcKey) OR poBody:GetType(pcKey) NE JsonDataType:BOOLEAN THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Missing/invalid required boolean field '&1'":u, pcKey), 400).

        lValue = poBody:GetLogical(pcKey) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Field '&1' must be boolean":u, pcKey), 400).

        RETURN lValue.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Reads an optional DECIMAL field from the request body,
                 defaulting to 0 if absent.
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
        Purpose: Reads the optional "typeKorting" field, defaulting to ""
                 (no discount) if absent.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GetOptionalTypeKorting( INPUT poBody AS JsonObject ):

        IF NOT poBody:Has("typeKorting":u) THEN
            RETURN "":u.

        RETURN TRIM(poBody:GetCharacter("typeKorting":u)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validates and returns the "regels" JsonArray from the
                 request body.
        Errors : Throws AppError 400 if missing, not an array, or empty.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonArray GetRegelsArray( INPUT poBody AS JsonObject ):

        DEFINE VARIABLE oRegels AS JsonArray NO-UNDO.

        IF NOT poBody:Has("regels":u) OR poBody:GetType("regels":u) NE JsonDataType:ARRAY THEN
            UNDO, THROW NEW Progress.Lang.AppError("Missing/invalid required field 'regels' (must be a non-empty array)":u, 400).

        oRegels = poBody:GetJsonArray("regels":u).

        IF oRegels:Length EQ 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError("Field 'regels' must not be empty":u, 400).

        RETURN oRegels.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Populates a ttBtwInvoerLijn buffer (obtained from
                 BtwBerekeningBE:GetInvoerLijnenHandle()) from the "regels"
                 JsonArray.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID PopulateInvoerLijnen( INPUT phInvoerLijnen AS HANDLE, INPUT poRegels AS JsonArray ):

        DEFINE VARIABLE hBuffer AS HANDLE    NO-UNDO.
        DEFINE VARIABLE oRegel  AS JsonObject NO-UNDO.
        DEFINE VARIABLE iIdx    AS INTEGER    NO-UNDO.

        hBuffer = phInvoerLijnen:DEFAULT-BUFFER-HANDLE.

        DO iIdx = 1 TO poRegels:Length:

            oRegel = poRegels:GetJsonObject(iIdx).

            hBuffer:BUFFER-CREATE().
            hBuffer:BUFFER-FIELD("btwKode":u):BUFFER-VALUE = (IF oRegel:Has("btwKode":u) THEN oRegel:GetCharacter("btwKode":u) ELSE "":u).
            hBuffer:BUFFER-FIELD("bedrag":u):BUFFER-VALUE = (IF oRegel:Has("bedrag":u) THEN oRegel:GetDecimal("bedrag":u) ELSE 0).
            hBuffer:BUFFER-FIELD("totaalRecupel":u):BUFFER-VALUE = (IF oRegel:Has("totaalRecupel":u) THEN oRegel:GetDecimal("totaalRecupel":u) ELSE 0).

        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Serializes the dsBtwResultaat dataset handle to the flat
                 {"totaal": {...}, "groepen": [...]} shape required by the
                 API contract (WRITE-JSON on a ProDataSet handle wraps the
                 output under the dataset's own top-level key, so this
                 unwraps it).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson    AS LONGCHAR          NO-UNDO.
        DEFINE VARIABLE oParser   AS ObjectModelParser NO-UNDO.
        DEFINE VARIABLE oOuter    AS JsonObject        NO-UNDO.
        DEFINE VARIABLE oInner    AS JsonObject        NO-UNDO.
        DEFINE VARIABLE oTotaalArr AS JsonArray        NO-UNDO.
        DEFINE VARIABLE oGroepenArr AS JsonArray       NO-UNDO.
        DEFINE VARIABLE oResult   AS JsonObject        NO-UNDO.
        DEFINE VARIABLE cOuterKey AS CHARACTER         NO-UNDO EXTENT.

        phResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE).

        oParser = NEW ObjectModelParser().
        oOuter  = CAST(oParser:Parse(lcJson), JsonObject).

        cOuterKey = oOuter:GetNames().
        oInner    = oOuter:GetJsonObject(cOuterKey[1]).

        oTotaalArr = oInner:GetJsonArray("totaal":u).

        /* WRITE-JSON omits a child temp-table's property entirely (rather
           than emitting an empty array) when it has 0 rows - this is the
           swRegime = FALSE case, where ttBtwGroep is deliberately left
           empty (see BtwBerekeningBE class header). Normalize that to an
           empty JSON array so "groepen" is always present in the response. */
        IF oInner:Has("groepen":u) THEN
            oGroepenArr = oInner:GetJsonArray("groepen":u).
        ELSE
            oGroepenArr = NEW JsonArray().

        oResult = NEW JsonObject().
        oResult:Add("totaal":u, oTotaalArr:GetJsonObject(1)).
        oResult:Add("groepen":u, oGroepenArr).

        RETURN oResult.

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
        Purpose: Maps an AppError raised by BtwBerekeningBE (400/404) to an
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
        Purpose: POST /btw/bereken - calculate a BTW result for a set of
                 input lines.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cRemainder                    AS CHARACTER       NO-UNDO.
        DEFINE VARIABLE oReqBody                      AS JsonObject      NO-UNDO.
        DEFINE VARIABLE oRegels                       AS JsonArray       NO-UNDO.
        DEFINE VARIABLE lSwRegime                     AS LOGICAL         NO-UNDO.
        DEFINE VARIABLE lSwPrijsRecup                 AS LOGICAL         NO-UNDO.
        DEFINE VARIABLE cTypeKorting                  AS CHARACTER       NO-UNDO.
        DEFINE VARIABLE dDocumentKortingBedrag         AS DECIMAL         NO-UNDO.
        DEFINE VARIABLE dDocumentKortingPercentage     AS DECIMAL         NO-UNDO.
        DEFINE VARIABLE oService                      AS BtwBerekeningBE NO-UNDO.
        DEFINE VARIABLE hInvoerLijnen                  AS HANDLE          NO-UNDO.
        DEFINE VARIABLE hResult                        AS HANDLE          NO-UNDO.
        DEFINE VARIABLE oBody                          AS JsonObject      NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).

        IF cRemainder NE "bereken":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /btw/bereken, got &1":u, cRemainder)).
            RETURN 0.
        END.

        oReqBody = GetJsonBody(poRequest).

        oRegels       = GetRegelsArray(oReqBody).
        lSwRegime     = GetRequiredLogical(oReqBody, "swRegime":u).
        lSwPrijsRecup = GetRequiredLogical(oReqBody, "swPrijsRecup":u).
        cTypeKorting  = GetOptionalTypeKorting(oReqBody).
        dDocumentKortingBedrag     = GetOptionalDecimal(oReqBody, "documentKortingBedrag":u).
        dDocumentKortingPercentage = GetOptionalDecimal(oReqBody, "documentKortingPercentage":u).

        oService      = NEW BtwBerekeningBE().
        hInvoerLijnen = oService:GetInvoerLijnenHandle().
        PopulateInvoerLijnen(hInvoerLijnen, oRegels).

        hResult = oService:BerekenBtw(hInvoerLijnen, lSwRegime, lSwPrijsRecup,
            cTypeKorting, dDocumentKortingBedrag, dDocumentKortingPercentage).
        oBody   = ResultHandleToJson(hResult).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /* Handler for unsupported HTTP methods on this endpoint. */
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /btw":u).
        RETURN 0.
    END METHOD.

    /* Handler for unimplemented HTTP methods on this endpoint. */
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /btw":u).
        RETURN 0.
    END METHOD.

END CLASS.
