/******************** Rocky Classes ********************/
class Rocky {
    _handlers = null;

    // Settings:
    _timeout = 10;
    _strictRouting = false;
    _allowUnsecure = false;
    _accessControl = true;

    constructor(settings = {}) {
        if ("timeout" in settings) _timeout = settings.timeout;
        if ("allowUnsecure" in settings) _allowUnsecure = settings.allowUnsecure;
        if ("strictRouting" in settings) _strictRouting = settings.strictRouting;
        if ("accessControl" in settings) _accessConrol = settings.accessControl;

        _handlers = {
            authorize = _defaultAuthorizeHandler.bindenv(this),
            onUnauthorized = _defaultUnauthorizedHandler.bindenv(this),
            onTimeout = _defaultTimeoutHandler.bindenv(this),
            onNotFound = _defaultNotFoundHandler.bindenv(this),
            onException = _defaultExceptionHandler.bindenv(this),
        };

        http.onrequest(_onrequest.bindenv(this));
    }

    /************************** [ PUBLIC FUNCTIONS ] **************************/
    function on(verb, signature, callback) {
        // Register this signature and verb against the callback
        verb = verb.toupper();
        signature = signature.tolower();
        if (!(signature in _handlers)) _handlers[signature] <- {};

        local routeHandler = Rocky.Route(callback);
        _handlers[signature][verb] <- routeHandler;

        return routeHandler;
    }

    function post(signature, callback) {
        return on("POST", signature, callback);
    }

    function get(signature, callback) {
        return on("GET", signature, callback);
    }

    function put(signature, callback) {
        return on("PUT", signature, callback);
    }

    function authorize(callback) {
        _handlers.authorize <- callback;
        return this;
    }

    function onUnauthorized(callback) {
        _handlers.onUnauthorized <- callback;
        return this;
    }

    function onTimeout(callback, timeout = 10) {
        _handlers.onTimeout <- callback;
        _timeout = timeout;
        return this;
    }

    function onNotFound(callback) {
        _handlers.onNotFound <- callback;
        return this;
    }

    function onException(callback) {
        _handlers.onException <- callback;
        return this;
    }

    // Adds access control headers
    function _addAccessControl(res) {
        res.header("Access-Control-Allow-Origin", "*")
        res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept");
        res.header("Access-Control-Allow-Methods", "POST, PUT, GET, OPTIONS");
    }

    /************************** [ PRIVATE FUNCTIONS ] *************************/
    function _onrequest(req, res) {

        // Add access control headers if required
        if (_accessControl) _addAccessControl(res);

        // Setup the context for the callbacks
        local context = Rocky.Context(req, res);

        // Check for unsecure reqeusts
        if (_allowUnsecure == false && "x-forwarded-proto" in req.headers && req.headers["x-forwarded-proto"] != "https") {
            context.send(405, "HTTP not allowed.");
            return;
        }

        // Parse the request body back into the body
        try {
            req.body = _parse_body(req);
        } catch (e) {
            server.log("Parse error '" + e + "' when parsing:\r\n" + req.body)
            context.send(400, e);
            return;
        }

        // Look for a handler for this path
        local route = _handler_match(req);
        if (route) {
            // if we have a handler
            context.path = route.path;
            context.matches = route.matches;

            // parse auth
            context.auth = _parse_authorization(context);

            // Create timeout
            local onTimeout = _handlers.onTimeout;
            local timeout = _timeout;

            if (route.handler.hasTimeout()) {
                onTimeout = route.handler.onTimeout;
                timeout = route.handler.timeout;
            }

            context.setTimeout(_timeout, onTimeout);
            route.handler.execute(context, _handlers);
        } else {
            // if we don't have a handler
            _handlers.onNotFound(context);
        }
    }

    function _parse_body(req) {
        if ("content-type" in req.headers && req.headers["content-type"] == "application/json") {
            if (req.body == "" || req.body == null) return null;
            return http.jsondecode(req.body);
        }
        if ("content-type" in req.headers && req.headers["content-type"] == "application/x-www-form-urlencoded") {
            return http.urldecode(req.body);
        }
        if ("content-type" in req.headers && req.headers["content-type"].slice(0,20) == "multipart/form-data;") {
            local parts = [];
            local boundary = req.headers["content-type"].slice(30);
            local bindex = -1;
            do {
                bindex = req.body.find("--" + boundary + "\r\n", bindex+1);
                if (bindex != null) {
                    // Locate all the parts
                    local hstart = bindex + boundary.len() + 4;
                    local nstart = req.body.find("name=\"", hstart) + 6;
                    local nfinish = req.body.find("\"", nstart);
                    local fnstart = req.body.find("filename=\"", hstart) + 10;
                    local fnfinish = req.body.find("\"", fnstart);
                    local bstart = req.body.find("\r\n\r\n", hstart) + 4;
                    local fstart = req.body.find("\r\n--" + boundary, bstart);

                    // Pull out the parts as strings
                    local headers = req.body.slice(hstart, bstart);
                    local name = null;
                    local filename = null;
                    local type = null;
                    foreach (header in split(headers, ";\n")) {
                        local kv = split(header, ":=");
                        if (kv.len() == 2) {
                            switch (strip(kv[0]).tolower()) {
                                case "name":
                                    name = strip(kv[1]).slice(1, -1);
                                    break;
                                case "filename":
                                    filename = strip(kv[1]).slice(1, -1);
                                    break;
                                case "content-type":
                                    type = strip(kv[1]);
                                    break;
                            }
                        }
                    }
                    local data = req.body.slice(bstart, fstart);
                    local part = { "name": name, "filename": filename, "data": data, "content-type": type };

                    parts.push(part);
                }
            } while (bindex != null);

            return parts;
        }

        // Nothing matched, send back the original body
        return req.body;
    }

    function _parse_authorization(context) {
        if ("authorization" in context.req.headers) {
            local auth = split(context.req.headers.authorization, " ");

            if (auth.len() == 2 && auth[0] == "Basic") {
                // Note the username and password can't have colons in them
                local creds = http.base64decode(auth[1]).tostring();
                creds = split(creds, ":");
                if (creds.len() == 2) {
                    return { authType = "Basic", user = creds[0], pass = creds[1] };
                }
            } else if (auth.len() == 2 && auth[0] == "Bearer") {
                // The bearer is just the password
                if (auth[1].len() > 0) {
                    return { authType = "Bearer", user = auth[1], pass = auth[1] };
                }
            }
        }

        return { authType = "None", user = "", pass = "" };
    }

    function _extract_parts(routeHandler, path, regexp = null) {
        local parts = { path = [], matches = [], handler = routeHandler };

        // Split the path into parts
        foreach (part in split(path, "/")) {
            parts.path.push(part);
        }

        // Capture regular expression matches
        if (regexp != null) {
            local caps = regexp.capture(path);
            local matches = [];
            foreach (cap in caps) {
                parts.matches.push(path.slice(cap.begin, cap.end));
            }
        }

        return parts;
    }

    function _handler_match(req) {
        local signature = req.path.tolower();
        local verb = req.method.toupper();

        // ignore trailing /s if _strictRouting == false
        if(!_strictRouting) {
            while (signature.len() > 1 && signature[signature.len()-1] == '/') {
                signature = signature.slice(0, signature.len()-1);
            }
        }

        if ((signature in _handlers) && (verb in _handlers[signature])) {
            // We have an exact signature match
            return _extract_parts(_handlers[signature][verb], signature);
        } else if ((signature in _handlers) && ("*" in _handlers[signature])) {
            // We have a partial signature match
            return _extract_parts(_handlers[signature]["*"], signature);
        } else {
            // Let's iterate through all handlers and search for a regular expression match
            foreach (_signature,_handler in _handlers) {
                if (typeof _handler == "table") {
                    foreach (_verb,_callback in _handler) {
                        if (_verb == verb || _verb == "*") {
                            try {
                                local ex = regexp(_signature);
                                if (ex.match(signature)) {
                                    // We have a regexp handler match
                                    return _extract_parts(_callback, signature, ex);
                                }
                            } catch (e) {
                                // Don't care about invalid regexp.
                            }
                        }
                    }
                }
            }
        }
        return null;
    }

    /*************************** [ DEFAULT HANDLERS ] *************************/
    function _defaultAuthorizeHandler(context) {
        return true;
    }

    function _defaultUnauthorizedHandler(context) {
        context.send(401, "Unauthorized");
    }

    function _defaultNotFoundHandler(context) {
        context.send(404, format("No handler for %s %s", context.req.method, context.req.path));
    }

    function _defaultTimeoutHandler(context) {
        context.send(500, format("Agent Request Timedout after %i seconds.", _timeout));
    }

    function _defaultExceptionHandler(context, ex) {
        context.send(500, "Agent Error: " + ex);
    }
}
class Rocky.Route {
    handlers = null;
    timeout = null;

    _callback = null;

    constructor(callback) {
        handlers = {};
        timeout = 10;

        _callback = callback;
    }

    /************************** [ PUBLIC FUNCTIONS ] **************************/
    function execute(context, defaultHandlers) {
        try {
            // setup handlers
            foreach (handlerName, handler in defaultHandlers) {
                if (!(handlerName in handlers)) handlers[handlerName] <- handler;
            }

            if(handlers.authorize(context)) {
                _callback(context);
            }
            else {
                handlers.onUnauthorized(context);
            }
        } catch(ex) {
            handlers.onException(context, ex);
        }
    }

    function authorize(callback) {
        handlers.authorize <- callback;
        return this;
    }

    function onException(callback) {
        handlers.onException <- callback;
        return this;
    }

    function onUnauthorized(callback) {
        handlers.onUnauthorized <- callback;
        return this;
    }

    function onTimeout(callback, t = 10) {
        handlers.onTimeout <- callback;
        timeout = t;
        return this;
    }

    function hasTimeout() {
        return ("onTimeout" in handlers);
    }
}
class Rocky.Context {
    req = null;
    res = null;
    sent = false;
    id = null;
    time = null;
    auth = null;
    path = null;
    matches = null;
    timer = null;
    static _contexts = {};

    constructor(_req, _res) {
        req = _req;
        res = _res;
        sent = false;
        time = date();

        // Identify and store the context
        do {
            id = math.rand();
        } while (id in _contexts);
        _contexts[id] <- this;
    }

    /************************** [ PUBLIC FUNCTIONS ] **************************/
    function get(id) {
        if (id in _contexts) {
            return _contexts[id];
        } else {
            return null;
        }
    }

    function isbrowser() {
        return (("accept" in req.headers) && (req.headers.accept.find("text/html") != null));
    }

    function getHeader(key, def = null) {
        key = key.tolower();
        if (key in req.headers) return req.headers[key];
        else return def;
    }

    function setHeader(key, value) {
        return res.header(key, value);
    }

    function send(code, message = null) {
        // Cancel the timeout
        if (timer) {
            imp.cancelwakeup(timer);
            timer = null;
        }

        // Remove the context from the store
        if (id in _contexts) {
            delete Rocky.Context._contexts[id];
        }

        // Has this context been closed already?
        if (sent) {
            return false;
        }

        if (message == null && typeof code == "integer") {
            // Empty result code
            res.send(code, "");
        } else if (message == null && typeof code == "string") {
            // No result code, assume 200
            res.send(200, code);
        } else if (message == null && (typeof code == "table" || typeof code == "array")) {
            // No result code, assume 200 ... and encode a json object
            res.header("Content-Type", "application/json; charset=utf-8");
            res.send(200, http.jsonencode(code));
        } else if (typeof code == "integer" && (typeof message == "table" || typeof message == "array")) {
            // Encode a json object
            res.header("Content-Type", "application/json; charset=utf-8");
            res.send(code, http.jsonencode(message));
        } else {
            // Normal result
            res.send(code, message);
        }
        sent = true;
    }

    function setTimeout(timeout, callback) {
        // Set the timeout timer
        if (timer) imp.cancelwakeup(timer);
        timer = imp.wakeup(timeout, function() {
            if (callback == null) {
                send(502, "Timeout");
            } else {
                callback(this);
            }
        }.bindenv(this))
    }
}

/******************** Bullwinkle Class *****************/
class Bullwinkle {
    _handlers = null;
    _sessions = null;
    _partner  = null;
    _history  = null;
    _timeout  = 10;
    _retries  = 1;


    // .........................................................................
    constructor() {
        const BULLWINKLE = "bullwinkle";

        _handlers = { timeout = null, receive = null };
        _partner  = is_agent() ? device : agent;
        _sessions = { };
        _history  = { };

        // Incoming message handler
        _partner.on(BULLWINKLE, _receive.bindenv(this));
    }


    // .........................................................................
    function send(command, params = null) {

        // Generate an unique id
        local id = _generate_id();

        // Create and store the session
        _sessions[id] <- Bullwinkle_Session(this, id, _timeout, _retries);

        return _sessions[id].send("send", command, params);
    }


    // .........................................................................
    function ping() {

        // Generate an unique id
        local id = _generate_id();

        // Create and store the session
        _sessions[id] <- Bullwinkle_Session(this, id, _timeout, _retries);

        // Send it
        return _sessions[id].send("ping");
    }


    // .........................................................................
    function is_agent() {
        return (imp.environment() == ENVIRONMENT_AGENT);
    }

    // .........................................................................
    static function _getCmdKey(cmd) {
        return BULLWINKLE + "_" + cmd;
    }

    // .........................................................................
    function on(command, callback) {
        local cmdKey = Bullwinkle._getCmdKey(command);

        if (cmdKey in _handlers) {
            _handlers[cmdKey] = callback;
        } else {
            _handlers[cmdKey] <- callback
        }
    }
    // .........................................................................
    function onreceive(callback) {
        _handlers.receive <- callback;
    }


    // .........................................................................
    function ontimeout(callback, timeout = null) {
        _handlers.timeout <- callback;
        if (timeout != null) _timeout = timeout;
    }


    // .........................................................................
    function set_timeout(timeout) {
        _timeout = timeout;
    }


    // .........................................................................
    function set_retries(retries) {
        _retries = retries;
    }


    // .........................................................................
    function _generate_id() {
        // Generate an unique id
        local id = null;
        do {
            id = math.rand();
        } while (id in _sessions);
        return id;
    }

    // .........................................................................
    function _is_unique(context) {

        // Clean out old id's from the history
        local now = time();
        foreach (id,t in _history) {
            if (now - t > 100) {
                delete _history[id];
            }
        }

        // Check the current context for uniqueness
        local id = context.id;
        if (id in _history) {
            return false;
        } else {
            _history[id] <- time();
            return true;
        }
    }

    // .........................................................................
    function _clone_context(ocontext) {
        local context = {};
        foreach (k,v in ocontext) {
            switch (k) {
                case "type":
                case "id":
                case "time":
                case "command":
                case "params":
                    context[k] <- v;
            }
        }
        return context;
    }


    // .........................................................................
    function _end_session(id) {
        if (id in _sessions) {
            delete _sessions[id];
        }
    }


    // .........................................................................
    function _receive(context) {
        local id = context.id;
        switch (context.type) {
            case "send":
            case "ping":
                // build the command string
                local cmdKey = Bullwinkle._getCmdKey(context.command);

                // Immediately ack the message
                local response = { type = "ack", id = id, time = Bullwinkle_Session._timestamp() };
                if (!_handlers.receive && !_handlers[cmdKey]) {
                    response.type = "nack";
                }
                _partner.send(BULLWINKLE, response);

                // Then handed on to the callback
                if (context.type == "send" && (_handlers.receive || _handlers[cmdKey]) && _is_unique(context)) {
                    try {
                        // Prepare a reply function for shipping a reply back to the sender
                        context.reply <- function (reply) {
                            local response = { type = "reply", id = id, time = Bullwinkle_Session._timestamp() };
                            response.reply <- reply;
                            _partner.send(BULLWINKLE, response);
                        }.bindenv(this);

                        // Fire the callback
                        if (_handlers[cmdKey]) {
                            _handlers[cmdKey](context);
                        } else {
                            _handlers.receive(context);
                        }
                    } catch (e) {
                        // An unhandled exception should be sent back to the sender
                        local response = { type = "exception", id = id, time = Bullwinkle_Session._timestamp() };
                        response.exception <- e;
                        _partner.send(BULLWINKLE, response);
                    }
                }
                break;

            case "nack":
            case "ack":
                // Pass this packet to the session handler
                if (id in _sessions) {
                    _sessions[id]._ack(context);
                }
                break;

            case "reply":
                // This is a reply for an sent message
                if (id in _sessions) {
                    _sessions[id]._reply(context);
                }
                break;

            case "exception":
                // Pass this packet to the session handler
                if (id in _sessions) {
                    _sessions[id]._exception(context);
                }
                break;

            default:
                throw "Unknown context type: " + context.type;

        }
    }

}
class Bullwinkle_Session {
    _handlers = null;
    _parent = null;
    _context = null;
    _timer = null;
    _timeout = null;
    _acked = false;
    _retries = null;

    // .........................................................................
    constructor(parent, id, timeout = 0, retries = 1) {
        _handlers = { ack = null, reply = null, timeout = null, exception = null };
        _parent = parent;
        _timeout = timeout;
        _retries = retries;
        _context = { time = _timestamp(), id = id };
    }

    // .........................................................................
    function onack(callback) {
        _handlers.ack = callback;
        return this;
    }

    // .........................................................................
    function onreply(callback) {
        _handlers.reply = callback;
        return this;
    }

    // .........................................................................
    function ontimeout(callback) {
        _handlers.timeout = callback;
        return this;
    }

    // .........................................................................
    function onexception(callback) {
        _handlers.exception = callback;
        return this;
    }

    // .........................................................................
    function send(type = "resend", command = null, params = null) {

        _retries--;

        if (type != "resend") {
            _context.type <- type;
            _context.command <- command;
            _context.params <- params;
        }

        if (_timeout > 0) _set_timer(_timeout);
        _parent._partner.send(BULLWINKLE, _context);

        return this;
    }

    // .........................................................................
    function _set_timer(timeout) {

        // Stop any current timers
        _stop_timer();

        // Start a fresh timer
        _timer = imp.wakeup(_timeout, _ontimeout.bindenv(this));
    }

    // .........................................................................
    function _ontimeout() {

        // Close down the timer and session
        _timer = null;

        if (!_acked && _retries > 0) {
            // Retry is required
            send();
        } else {
            // Close off this dead session
            _parent._end_session(_context.id)

            // If we are still waiting for an ack, throw a callback
            if (!_acked) {
                _context.latency <- _timestamp_diff(_context.time, _timestamp());
                if (_handlers.timeout) {
                    // Send the context to the session timeout handler
                    _handlers.timeout(_context);
                } else if (_parent._handlers.timeout) {
                    // Send the context to the global timeout handler
                    _parent._handlers.timeout(_context);
                }
            }
        }
    }

    // .........................................................................
    function _stop_timer() {
        if (_timer) imp.cancelwakeup(_timer);
        _timer = null;
    }

    // .........................................................................
    function _timestamp() {
        if (Bullwinkle.is_agent()) {
            local d = date();
            return format("%d.%06d", d.time, d.usec);
        } else {
            local d = math.abs(hardware.micros());
            return format("%d.%06d", d/1000000, d%1000000);
        }
    }


    // .........................................................................
    function _timestamp_diff(ts0, ts1) {
        // server.log(ts0 + " > " + ts1)
        local t0 = split(ts0, ".");
        local t1 = split(ts1, ".");
        local diff = (t1[0].tointeger() - t0[0].tointeger()) + (t1[1].tointeger() - t0[1].tointeger()) / 1000000.0;
        return math.fabs(diff);
    }


    // .........................................................................
    function _ack(context) {
        // Restart the timeout timer
        _set_timer(_timeout);

        // Calculate the round trip latency and mark the session as acked
        _context.latency <- _timestamp_diff(_context.time, _timestamp());
        _acked = true;

        // Fire a callback
        if (_handlers.ack) {
            _handlers.ack(_context);
        }

    }


    // .........................................................................
    function _reply(context) {
        // We can stop the timeout timer now
        _stop_timer();

        // Fire a callback
        if (_handlers.reply) {
            _context.reply <- context.reply;
            _handlers.reply(_context);
        }

        // Remove the history of this message
        _parent._end_session(_context.id)
    }


    // .........................................................................
    function _exception(context) {
        // We can stop the timeout timer now
        _stop_timer();

        // Fire a callback
        if (_handlers.exception) {
            _context.exception <- context.exception;
            _handlers.exception(_context);
        }

        // Remove the history of this message
        _parent._end_session(_context.id)
    }

}

//initialize Bullwinkle
bullwinkle <- Bullwinkle();

/******************** API Class *****************/
class AgentSideSensorAPI {
    _agentID = null;
    _bullwinkle = null;
    _sensorSettings = null;
    _settingsChanged = false;
    _broadcastCallback = null;

    constructor(readingInterval, reportingInterval, bullwinkle, broadcastCallback=null) {
        _agentID = split(http.agenturl(), "/").pop();
        _bullwinkle = bullwinkle;
        _broadcastCallback = broadcastCallback;
        _sensorSettings = { "agentID" : _agentID,
                            "reportingInterval" : reportingInterval,
                            "readingInterval" : readingInterval,
                            "sensors" : [] };
        init();
    }

    function init() {
        _bullwinkle.on("getSettings", _sendSettings.bindenv(this));
        _bullwinkle.on("sendData", function(context) { _broadcastData(context, _broadcastCallback) }.bindenv(this));
        _bullwinkle.on("ack", _successfulCommunicationResponse.bindenv(this));
    }

    function addSensor (type, availStreams=[], availEvents={}) {
        if(typeof availStreams != "array" && typeof availStreams == "table") {
            availEvents = availStreams;
            availStreams = [];
        }
        if(typeof availEvents != "table" && typeof availEvents == "array") {
            availStreams = availEvents;
            availEvents = {};
        }
        if(typeof type == "string" && typeof availStreams == "array" && typeof availEvents == "table") {
            local id = _sensorSettings.sensors.len();
            _sensorSettings.sensors.push({ "sensorID" : id,
                                          "type" : type,
                                          "active" : false,
                                          "availableStreams" : availStreams,
                                          "availableEvents" : availEvents,
                                          "activeStreams" : [],
                                          "activeEvents" : {} });
        }
    }

    function setBroadcastCallback(callback) {
        _broadcastCallback = callback;
    }

    function getSensors() {
        return http.jsonencode(_sensorSettings);
    }

    // subscribe to 1, some, all sensors (this will turn on all streams for a given sensor)
    // takes an array of sensorIDs as a parameter (if no parameter then will subscribe to all sensors)
    function activateStreams(sensorIDs=null) {
        //if no sensorId given create an array of all sensorIDs
        if(!sensorIDs) { sensorIDs = _createSensorIDArray(); }
        foreach(sID in sensorIDs) {
            _sensorSettings.sensors[sID].activeStreams = _sensorSettings.sensors[sID].availableStreams;
            //change status to active if it isn't
            if( _sensorSettings.sensors[sID].activeStreams.len() > 0 && !(_sensorSettings.sensors[sID].active) ) {
                _sensorSettings.sensors[sID].active = true;
            }
            _settingsChanged = true;
        }
    }

    function activateAStream(sensorID, stream) {
        if(stream in _sensorSettings.sensors[sensorID].availableStreams) {
            _sensorSettings.sensors[sensorID].activeStreams.push(stream);
            _sensorSettings.sensors[sID].active = true;
            _settingsChanged = true;
        }
    }

    // subscribe to specific event
    // example parameters - (1, "sensorTail_themostat", [20, 30])
    // if no eventParams are passed in then default params for event will be used
    function activateEvent(sensorID, event, eventParams=null) {
        if(event in _sensorSettings.sensors[sensorID].availableEvents) {
            if(eventParams == null) { eventParams = _sensorSettings.sensors[sensorID].availableEvents[event] };
            _sensorSettings.sensors[sensorID].activeEvents[event] <- eventParams;
            _sensorSettings.sensors[sensorID].active = true;
            _settingsChanged = true;
        }
    }

    //subscribes to all streams & events with default settings
    function activateAll() {
        local sensorIDs = _createSensorIDArray();
        foreach(sID in sensorIDs) {
            _sensorSettings.sensors[sID].activeStreams = _sensorSettings.sensors[sID].availableStreams;
            _sensorSettings.sensors[sID].activeEvents = _sensorSettings.sensors[sID].availableEvents;
            //change status to active if it isn't
            if( !(_sensorSettings.sensors[sID].active) && (_sensorSettings.sensors[sID].activeStreams.len() > 0 || _sensorSettings.sensors[sID].activeEvents.len() > 0) ) {
                _sensorSettings.sensors[sID].active = true;
            }
            _settingsChanged = true;
        }
    }

    //unsubscribes form all streams & events
    function deactivateAll() {
        local sensorIDs = _createSensorIDArray();
        foreach(sID in sensorIDs) {
            _sensorSettings.sensors[sID].activeStreams = {};
            _sensorSettings.sensors[sID].activeEvents = {};
            if(_sensorSettings.sensors[sID].active) { _sensorSettings.sensors[sID].active = false };
            _settingsChanged = true;
        }
    }

    // unsubscribe to 1, some, all sensors (this will turn off all streams & events for the given sensors)
    // takes an array of sensorIDs as a parameter (if no parameter then will subscribe to all)
    function deactivateStreams(sensorIDs=null) {
        if(!sensorIDs) { sensorIDs = _createSensorIDArray() };
        foreach(sID in sensorIDs) {
            _sensorSettings.sensors[sID].activeStreams = {};
            if(_sensorSettings.sensors[sID].active && _sensorSettings.sensors[sID].activeStreams.len() == 0 && _sensorSettings.sensors[sID].activeEvents.len() == 0) {
                _sensorSettings.sensors[sID].active = false;
            }
            _settingsChanged = true;
        }
    }

    function deactivateAStream(sensorID, stream) {
        if(stream in _sensorSettings.sensors[sensorID].activeStreams) {
            _sensorSettings.sensors[sensorID].activeStreams.remove( _sensorSettings.sensors[sensorID].activeStreams.find(stream) );
            if(_sensorSettings.sensors[sID].active && _sensorSettings.sensors[sID].activeStreams.len() == 0 && _sensorSettings.sensors[sID].activeEvents.len() == 0) {
                _sensorSettings.sensors[sID].active = false;
            }
            _settingsChanged = true;
        }
    }

    function deactivateEvent(sensorID, event) {
        if(event in _sensorSettings.sensors[sensorID].activeEvents) {
            _sensorSettings.sensors[sensorID].activeEvents.rawdelete(event);
            if(_sensorSettings.sensors[sID].active && _sensorSettings.sensors[sID].activeStreams.len() == 0 && _sensorSettings.sensors[sID].activeEvents.len() == 0) {
                _sensorSettings.sensors[sID].active = false;
            }
            _settingsChanged = true;
        }
    }

    // change reporting interval on stream
    // this should be multiple of readingInterval
    function updateReportingInterval(newReportInt) {
        if(_sensorSettings.reportingInterval != newReportInt) {
            _sensorSettings.reportingInterval = newReportInt;
            _settingsChanged = true;
        }
    }

    function updateReadingInterval(newReadInt) {
        if(_sensorSettings.readingInterval != newReadInt) {
            _sensorSettings.readingInterval = newReadInt;
            _settingsChanged = true;
        }
    }

    function updateEventParams(sensorID, event, params) {
        if(_sensorSettings["sensors"].len() > sensorID && event in _sensorSettings["sensors"][sensorID]["availableEvents"]) {
            _sensorSettings["sensors"][sensorID]["availableEvents"][event] = params;
            _settingsChanged = true;
        }
    }

    function _sendSettings(context) {
        context.reply(_getActiveSensorSettings());
    }

    function _broadcastData(context, callback=null) {
        // if settings have changed send new settings
        _settingsChanged ? context.reply(_getActiveSensorSettings()) : context.reply(null);

        if(context.params) { //we got data
            if(callback) { callback(http.jsonencode(context.params)) };
        }
    }

    function _successfulCommunicationResponse(context) {
        _settingsChanged = false;
        context.reply("OK");
    }

    //builds table of active subscriptions to send to device
    function _getActiveSensorSettings() {
        local activeSensorSettings = { "reportingInterval" : _sensorSettings.reportingInterval,
                                      "readingInterval" : _sensorSettings.readingInterval,
                                      "subscriptions" : {} };
        foreach(sensor in _sensorSettings.sensors) {
            if(sensor.active) {
                if(sensor.activeStreams.len() > 0) {
                    if (!("activeStreams" in activeSensorSettings["subscriptions"])) {
                        activeSensorSettings["subscriptions"]["activeStreams"] <- [];
                    }
                    activeSensorSettings["subscriptions"]["activeStreams"] <- sensor.activeStreams;
                }
                if(sensor.activeEvents.len() > 0) {
                    if (!("activeEvents" in activeSensorSettings["subscriptions"])) {
                        activeSensorSettings["subscriptions"]["activeEvents"] <- {};
                    }
                    activeSensorSettings["subscriptions"]["activeEvents"] <- sensor.activeEvents;
                }
            }
        }
        return activeSensorSettings;
    }

    //helper for subscription events for all sensors
    function _createSensorIDArray() {
        local ids = [];
            for (local i = 0; i < _sensorSettings.sensors.len(); i++) {
                ids.push(i);
            }
        return ids;
    }
}


/******************** Initialize API ********************/

//time in sec that the imp sleeps between data collection for streams
readingInterval <- 15;

//time in sec that the imp waits between connection to agent
//this should be a multiple of the readingInterval
reportingInterval <- 60;

//initialize our communication class
api <- AgentSideSensorAPI(readingInterval, reportingInterval, bullwinkle);

//generic print function to use as broadcastCallback
function printData(data) {
    server.log(data);
}

//set callback for how to broadcast data
api.setBroadcastCallback(printData);

//add a sensor to the api
//params - type of sensor(what you want to display to user of api),
//array of streams names/commands - this needs to be the same as the name/command in sensorSubscriptionFunctionsByCommand on the divice,
//table with key of events/commands - this needs to be the same as the name/command in sensorSubscriptionFunctionsByCommand on the divice
//and value a table of params - the key is the identifier to make parameters searchable on the divice side
api.addSensor("temp", ["nora_tempReadings"], {"nora_tempThermostat" : {"low": 29, "high": 30}});


//run time tests
server.log(api.getSensors());
// api.activateAll();
// server.log(api.getSensors());
// imp.wakeup(130, function() {
//     api.deactivateAll();
//     server.log(api.getSensors());
// }.bindenv(api));

// imp.wakeup(190, api.activateStreams.bindenv(api));
// imp.wakeup(245, api.deactivateStreams.bindenv(api));

api.activateStreams([0])
imp.wakeup(50, function() { api.updateReadingInterval(10); }.bindenv(api))
imp.wakeup(50, function() { api.updateReportingInterval(30); }.bindenv(api))

api.activateEvent(0, "nora_tempThermostat");
// imp.wakeup(110, function() { api.deactivateEvent(0, "nora_tempThermostat")}.bindenv(api));


//data structure examples

//agent to device table
/*activeSensorSettings <- { "reportingInterval" : reportingInterval,
                          "readingInterval" : readingInterval,
                          "subscriptions" : { "activeStreams" : [ "SI7021_sensorTail_tempReadings" ],
                                              "activeEvents" : {"SI7021_sensorTail_themostat" : {"low":20, "high":30} }
                        }

*/

//device side nv table
/*nv:   { envSensorTailData: {  "nextWakeUp": 1422306809,
                                "nextConnection": 1422306864,
                                "sensorReadings": { "sensorTail_tempReadings" : [ readings... ],
                                                    "sensorTail_themostat" : [ readings... ] },
                              },
          envSensorTailSettings: {  readingInterval: 5,
                                    reportingInterval: 60,
                                    subscriptions: {
                                        "activeStreams" : [ "sensorTail_tempReadings",
                                                            "sensorTail_humidReadings"],
                                        "activeEvents" : { "sensorTail_themostat" : {low: 20, high: 30} }
                                    }
                                 },
          eventPins: {"pinE":null},
        }
*/

/* _eventConfig <- { "noraTemp_thermostat" : {"pin" : "pinE", "eventTriggerPolarity" : 0, "callback" : function(){ initializeTemp(); return noraTemp.readTempC();} },
                     "nora_baro" : {"pin" : "pinA", "eventTriggerPolarity" : 1, "callback" : function(){server.log("barometer event")} },
                     "nora_accel" : {"pin" : "pinB", "eventTriggerPolarity" : 1, "callback" : function(){server.log("accel event")} },
                     "nora_mag" : {"pin" : "pinC", "eventTriggerPolarity" : 0, "callback" : function(){server.log("mag event")} },
                     "nora_als" : {"pin" : "pinD", "eventTriggerPolarity" : 0, "callback" : function(){server.log("als event")} },
                    }
*/